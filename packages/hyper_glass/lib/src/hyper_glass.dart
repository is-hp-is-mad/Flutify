import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'blend_material.dart';
import 'glass_filter.dart';
import 'hyper_glass_renderer.dart';
import 'view_shadow.dart';

/// Caps Skia's GPU resource cache (Skia backend only, e.g. Windows / Linux today; a no-op on Impeller).
///
/// Every glass refresh allocates fresh offscreen textures; freed ones stay in Skia's cache for reuse,
/// which by default lets the process hold several hundred MB. 32 MB is enough for this pipeline.
Future<void> limitSkiaResourceCache({int megabytes = 32}) =>
    SystemChannels.skia.invokeMethod<void>('Skia.setResourceCacheMaxBytes', megabytes << 20);

/// A filter's textures and the part of the backdrop they cover, in backdrop pixels.
typedef _Refract = ({RefractTexture tex, Rect crop});

/// Hosts the backdrop and the glass cards above it.
///
/// [background] is drawn inside a RepaintBoundary that is snapshotted at physical resolution after
/// every frame; that snapshot plays the role of the engine's backdrop texture. [child] holds
/// [HyperGlass] widgets (anywhere in its subtree).
class HyperGlassScene extends StatefulWidget {
  const HyperGlassScene({
    super.key,
    required this.background,
    required this.child,
    this.animate = true,
    this.captureScale = 1,
  });

  final Widget background;
  final Widget child;

  /// Re-snapshot every frame (animated backgrounds). When false, only on rebuild/resize.
  final bool animate;

  /// Backdrop capture resolution relative to physical pixels for glass surfaces (Flutify).
  ///
  /// For a background without fine detail (e.g. an already heavily blurred one) a fraction such as 0.25
  /// captures 1/16 of the pixels per frame for the same look. Only filters drawn on the Skia fused glass
  /// path can honour it; anything else captures at full resolution.
  final double captureScale;

  /// Whether [context] is inside a [HyperGlassScene] (where [HyperGlass] / [HyperBlendBlur] can be used).
  static bool isIn(BuildContext context) => context.getInheritedWidgetOfExactType<_SceneScope>() != null;

  @override
  State<HyperGlassScene> createState() => _HyperGlassSceneState();
}

class _HyperGlassSceneState extends State<HyperGlassScene> with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();
  HyperGlassRenderer? _renderer;
  ui.Image? _backdrop; // covers [_region] of the background at [_dpr]
  Rect _region = Rect.zero; // logical px, background coordinates
  double _scale = 1; // backdrop pixels per physical pixel
  static const _blendCaptureScale = 0.5;
  double _dpr = 1;
  final _surfaces = <_RenderGlass>{};
  final _refract = <GlassFilter, _Refract>{};
  final _blurred = <double, ui.Image>{};
  final _frame = ValueNotifier<int>(0);
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    _holdFirstFrame();
    _renderer = HyperGlassRenderer.ready;
    if (_renderer == null) {
      HyperGlassRenderer.shared().then(
        (r) {
          if (!mounted) return;
          setState(() => _renderer = r);
          _scheduleSnapshot();
        },
        onError: (Object e) {
          debugPrint('[hyper_glass] shader 加载失败：$e');
          _releaseFirstFrame();
        },
      );
    } else {
      _scheduleSnapshot();
    }
    _ticker = createTicker((_) => _scheduleSnapshot());
    if (widget.animate) _ticker!.start();
  }

  bool _shown = true;
  double _viewDpr = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewDpr = MediaQuery.devicePixelRatioOf(context);
    // A hidden page (IndexedStack turns its tickers off) keeps its capture but not the textures derived from it: each
    // glass filter holds screen-sized images. They are rebuilt from the capture on the next paint, so nothing flashes.
    final shown = TickerMode.valuesOf(context).enabled;
    if (shown == _shown) return;
    _shown = shown;
    if (shown) {
      _scheduleSnapshot();
    } else {
      _clearRefract();
    }
  }

  @override
  void didUpdateWidget(HyperGlassScene old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_ticker!.isActive) _ticker!.start();
    if (!widget.animate && _ticker!.isActive) _ticker!.stop();
    _scheduleSnapshot();
  }

  // The app's first frame waits for this scene's first backdrop, so the first thing on screen is the
  // finished glass: the window (and Android's launch screen) stays up until then, instead of showing
  // a frozen frame while the raster thread compiles shaders and the cards pop in afterwards.
  bool _holding = false;
  Timer? _holdLimit;

  void _holdFirstFrame() {
    if (WidgetsBinding.instance.firstFrameRasterized) return;
    _holding = true;
    RendererBinding.instance.deferFirstFrame();
    _holdLimit = Timer(const Duration(seconds: 3), _releaseFirstFrame); // never leave the app without a frame
  }

  void _releaseFirstFrame() {
    _holdLimit?.cancel();
    if (!_holding) return;
    _holding = false;
    RendererBinding.instance.allowFirstFrame();
  }

  /// Logical px around each surface that refraction (reflectOffsetPx 110 physical) and blur may sample.
  static const _margin = 80.0;

  bool _pending = false;
  bool _inFlight = false;
  bool _dirty = false;

  void _scheduleSnapshot() {
    _dirty = true;
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_capturedInPaint || _dirty) _snapshot();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  // A scene whose surfaces are all frosted (menus, dialogs) only needs a heavily blurred backdrop, so
  // it is captured at a lower resolution directly.
  bool get _frostedOnly => _surfaces.every((g) => g.material is BlendMaterial && !g.gradientBlur);

  double get _captureScale {
    if (_frostedOnly) return _blendCaptureScale;
    final r = _renderer;
    if (r == null || ui.ImageFilter.isShaderFilterSupported) return 1;
    final fused = _surfaces.every((g) {
      final m = g.material;
      return m is! GlassFilter || r.canFuse(m);
    });
    return fused ? widget.captureScale : 1;
  }

  /// Only the area under glass surfaces (plus room for refraction / reflection offsets) is captured and processed.
  Rect? _captureRegion(RenderRepaintBoundary ro) {
    Rect? region;
    for (final g in _surfaces) {
      if (!g.attached || !g.hasSize) continue;
      final r = MatrixUtils.transformRect(g.getTransformTo(ro), Offset.zero & g.size);
      region = region == null ? r : region.expandToInclude(r);
    }
    region = region?.inflate(_margin).intersect(Offset.zero & ro.size);
    if (region == null || region.isEmpty) return null;
    // Snap outwards to whole logical px, but never past the boundary: its size is usually fractional
    // (e.g. 1265.33), and rounding up would add a transparent last column / row that glass touching
    // the right or bottom edge then refracts as a thin line.
    return Rect.fromLTRB(
      region.left.floorToDouble(),
      region.top.floorToDouble(),
      math.min(region.right.ceilToDouble(), ro.size.width.floorToDouble()),
      math.min(region.bottom.ceilToDouble(), ro.size.height.floorToDouble()),
    );
  }

  bool _capturedInPaint = false;

  /// A surface's first paint with no capture yet, as on a page that was never shown. The background was painted just
  /// before it in this same frame, so it is captured here and the surface is finished in its first frame.
  void _captureInPaint() {
    final ro = _boundary.currentContext?.findRenderObject();
    if (_renderer == null || ro is! RenderRepaintBoundary || !ro.hasSize || ro.size.isEmpty) return;
    // ignore: invalid_use_of_protected_member
    final layer = ro.layer as OffsetLayer?;
    final region = _captureRegion(ro);
    final scale = _captureScale;
    // frosted surfaces (menus, dialogs) fade in, so a frame's wait goes unseen and costs no stall in this frame
    if (layer == null || region == null || _frostedOnly) {
      _scheduleSnapshot();
      return;
    }
    _backdrop = layer.toImageSync(region, pixelRatio: _viewDpr * scale);
    _region = region;
    _dpr = _viewDpr;
    _scale = scale;
    _capturedInPaint = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _capturedInPaint = false;
      _releaseFirstFrame();
    });
  }

  void _snapshot() {
    // Back-pressure: the async capture completes only after the raster thread has finished the
    // frames queued before it (including the previous refresh's pass chain). toImageSync cannot reuse
    // render targets, so without this a GPU that falls behind queues new texture chains every frame
    // and memory grows by gigabytes. When the GPU is slow the glass simply refreshes less often.
    if (_inFlight || !mounted || _renderer == null) return;
    final ro = _boundary.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize || ro.size.isEmpty) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final scale = _captureScale;
    final snapped = _captureRegion(ro);
    if (snapped == null) {
      _backdrop?.dispose();
      _backdrop = null;
      _clearRefract();
      _releaseFirstFrame();
      return;
    }
    // ignore: invalid_use_of_protected_member
    final layer = ro.layer as OffsetLayer?;
    if (layer == null) {
      _releaseFirstFrame(); // an offstage page captures in its first paint
      return;
    }
    _dirty = false;
    _inFlight = true;
    layer
        .toImage(snapped, pixelRatio: dpr * scale)
        .then(
          (img) {
            _inFlight = false;
            if (!mounted) {
              img.dispose();
              return;
            }
            _backdrop?.dispose();
            _backdrop = img;
            _region = snapped;
            _dpr = dpr;
            _scale = scale;
            _clearRefract();
            _frame.value++; // surfaces repaint with the new backdrop
            _releaseFirstFrame();
            if (widget.animate || _dirty) _scheduleSnapshot();
          },
          onError: (Object _) {
            _inFlight = false;
            _releaseFirstFrame();
          },
        );
  }

  void _clearRefract() {
    _refract.values.forEach(_dropRefract);
    _refract.clear();
    for (final i in _blurred.values) {
      i.dispose();
    }
    _blurred.clear();
  }

  /// The backdrop blurred with an LM [radius] in logical px, computed once per snapshot. libhwui's
  /// generateLMGaussianBlur and the engine share one formula, sigma = radius * 0.25 * 0.45 (see
  /// LMGaussianState), so what miuix calls a blur of 20dp is a sigma of 2.25dp.
  ui.Image? blurredFor(double radius) {
    final b = _backdrop, r = _renderer;
    if (b == null || r == null) return null;
    final sigma = radius * 0.25 * 0.45;
    return _blurred.putIfAbsent(radius, () => r.gaussianBlur(b, sigma * _dpr * _scale, downscale: _scale < 1 ? 1 : 2));
  }

  /// The pre-tinted refract texture for [g], computed once per snapshot and shared by all cards.
  ///
  /// Only the area of the surfaces using [g] is processed, plus the margin they may sample: a screen-sized texture
  /// per filter is what made a page of many materials hold half a gigabyte. [surface] is the caller's rect in
  /// backdrop pixels.
  _Refract? refractFor(GlassFilter g, Rect surface) {
    final b = _backdrop, r = _renderer;
    final boundary = _boundary.currentContext?.findRenderObject();
    if (b == null || r == null || boundary is! RenderBox) return null;
    final known = _refract[g];
    if (known != null) {
      if (known.crop.expandToInclude(surface) == known.crop) return known;
      _dropRefract(known); // a surface moved out of it without a new capture
    }
    var area = surface;
    for (final s in _surfaces) {
      if (!identical(s.material, g) || !s.attached || !s.hasSize) continue;
      area = area.expandToInclude(((s.localToGlobal(Offset.zero, ancestor: boundary) - _region.topLeft) * _dpr) & (s.size * _dpr));
    }
    final image = Offset.zero & Size(b.width.toDouble(), b.height.toDouble());
    final near = area.inflate(_margin * _dpr).intersect(image);
    final crop = Rect.fromLTRB(
      near.left.floorToDouble(),
      near.top.floorToDouble(),
      near.right.ceilToDouble(),
      near.bottom.ceilToDouble(),
    ).intersect(image);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(b, crop, Offset.zero & crop.size, Paint()..blendMode = BlendMode.src);
    final pic = rec.endRecording();
    final cut = pic.toImageSync(crop.width.toInt(), crop.height.toInt());
    pic.dispose();
    final tex = r.refractTexture(cut, g.blurScaled(_dpr / 3));
    HyperGlassRenderer.deferDispose(image: cut); // still alive in the pictures that read it
    return _refract[g] = (tex: tex, crop: crop);
  }

  static void _dropRefract(_Refract r) {
    HyperGlassRenderer.deferDispose(image: r.tex.rgb);
    HyperGlassRenderer.deferDispose(image: r.tex.a);
  }

  @override
  void dispose() {
    _releaseFirstFrame();
    _ticker?.dispose();
    _clearRefract();
    _backdrop?.dispose();
    // the renderer is process-wide (HyperGlassRenderer.shared), not owned by this scene
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SceneScope(
      state: this,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(key: _boundary, child: widget.background),
          widget.child,
        ],
      ),
    );
  }
}

class _SceneScope extends InheritedWidget {
  const _SceneScope({required this.state, required super.child});
  final _HyperGlassSceneState state;

  static _HyperGlassSceneState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SceneScope>();
    if (scope != null) return scope.state;
    throw FlutterError(
      'HyperGlass and HyperBlendBlur need a HyperGlassScene above them, in its child.\n'
      'Glass samples the background of its scene, so it cannot be used outside one.',
    );
  }

  @override
  bool updateShouldNotify(_SceneScope old) => old.state != state;
}

/// A glass card (MIUIWeather's `ImageFilter.glass` surface) with [child] on top of it.
class HyperGlass extends StatelessWidget {
  const HyperGlass({
    super.key,
    this.filter = const GlassFilter(),
    this.borderRadius = 24,
    this.opacity = 1,
    this.fx = const GlassFx(),
    this.bloom,
    this.press,
    this.pressAt = Offset.zero,
    this.pressOpacity = 0,
    this.mask,
    this.child,
  });

  /// Call once before runApp: loads the shadow shader and bounds Skia's GPU cache.
  static Future<void> init({int skiaCacheMegabytes = 32}) async {
    await limitSkiaResourceCache(megabytes: skiaCacheMegabytes);
    await ViewShadow.load();
  }

  final GlassFilter filter;
  final GlassFx fx;

  /// Bloom stroke drawn over the glass.
  final BloomStroke? bloom;

  /// Press light at [pressAt] (logical px inside the surface), faded by [pressOpacity].
  final PressLight? press;
  final Offset pressAt;
  final double pressOpacity;

  /// uMaskTex for [GlassFx.iconRect]; its red channel shapes the icon light.
  final ui.Image? mask;

  /// Logical pixels; converted to the engine's physical-pixel shape radius.
  final double borderRadius;
  final double opacity;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scene = _SceneScope.of(context);
    // passthrough: the child gets this widget's own constraints (a fixed-size button stays centred,
    // a filling bar keeps filling, a shrink-wrapped menu stays shrink-wrapped).
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: _GlassSurface(
            scene: scene,
            material: filter,
            radius: borderRadius,
            opacity: opacity,
            fx: fx,
            bloom: bloom,
            press: press,
            pressAt: pressAt,
            pressOpacity: pressOpacity,
            mask: mask,
          ),
        ),
        if (child != null) child!,
      ],
    );
  }
}

/// A HyperOS blendBlur surface (popup menus, dialogs) with [child] on top of it.
///
/// Inside a [HyperGlassScene] it blurs that scene's background; [material] supplies the blur and
/// blend layers (see [BlendMaterial]).
class HyperBlendBlur extends StatelessWidget {
  const HyperBlendBlur({
    super.key,
    required this.material,
    this.borderRadius = 16,
    this.opacity = 1,
    this.bloom,
    this.gradientBlur = false,
    this.overlayMask,
    this.child,
  });

  final BlendMaterial material;
  final BloomStroke? bloom;
  final double borderRadius;
  final double opacity;

  /// When true, applies ActionBarContainer's vertical progressive blur (40dp at top -> 0dp sharp at bottom).
  final bool gradientBlur;

  /// Optional OverlayMaskConfig base colour composited with the ROM's 17-stop alpha curve.
  final Color? overlayMask;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scene = _SceneScope.of(context);
    return Stack(
      fit: StackFit.passthrough, // see HyperGlass.build
      children: [
        Positioned.fill(
          child: _GlassSurface(
            scene: scene,
            material: material,
            radius: borderRadius,
            opacity: opacity,
            bloom: bloom,
            gradientBlur: gradientBlur,
            overlayMask: overlayMask,
          ),
        ),
        if (child != null) child!,
      ],
    );
  }
}

class _GlassSurface extends LeafRenderObjectWidget {
  const _GlassSurface({
    required this.scene,
    required this.material,
    required this.radius,
    required this.opacity,
    this.fx = const GlassFx(),
    this.bloom,
    this.press,
    this.pressAt = Offset.zero,
    this.pressOpacity = 0,
    this.mask,
    this.gradientBlur = false,
    this.overlayMask,
  });
  final _HyperGlassSceneState scene;
  final Object material; // GlassFilter | BlendMaterial
  final double radius, opacity;
  final GlassFx fx;
  final BloomStroke? bloom;
  final PressLight? press;
  final Offset pressAt;
  final double pressOpacity;
  final ui.Image? mask;
  final bool gradientBlur;
  final Color? overlayMask;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGlass(scene, material, radius, opacity)
    ..fx = fx
    ..bloom = bloom
    ..press = press
    ..pressAt = pressAt
    ..pressOpacity = pressOpacity
    ..mask = mask
    ..gradientBlur = gradientBlur
    ..overlayMask = overlayMask;

  @override
  void updateRenderObject(BuildContext context, _RenderGlass ro) {
    ro
      ..scene = scene
      ..material = material
      ..radius = radius
      ..opacity = opacity
      ..fx = fx
      ..bloom = bloom
      ..press = press
      ..pressAt = pressAt
      ..pressOpacity = pressOpacity
      ..mask = mask
      ..gradientBlur = gradientBlur
      ..overlayMask = overlayMask
      ..markNeedsPaint();
  }
}

class _RenderGlass extends RenderBox {
  _RenderGlass(this._scene, this.material, this.radius, this.opacity);

  _HyperGlassSceneState _scene;
  Object material;
  double radius, opacity;
  GlassFx fx = const GlassFx();
  BloomStroke? bloom;
  PressLight? press;
  Offset pressAt = Offset.zero;
  double pressOpacity = 0;
  ui.Image? mask;
  bool gradientBlur = false;
  Color? overlayMask;

  set scene(_HyperGlassSceneState s) {
    if (identical(s, _scene)) return;
    if (attached) {
      _scene._frame.removeListener(markNeedsPaint);
      _scene._surfaces.remove(this);
    }
    _scene = s;
    if (attached) {
      _scene._frame.addListener(markNeedsPaint);
      _scene._surfaces.add(this);
    }
  }

  @override
  bool get sizedByParent => true;
  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scene._frame.addListener(markNeedsPaint);
    _scene._surfaces.add(this);
  }

  @override
  void detach() {
    HyperGlassRenderer.deferDispose(shader: _lastShader, image: _lastImage);
    _lastShader = null;
    _lastImage = null;
    for (final s in _overlayShaders) {
      HyperGlassRenderer.deferDispose(shader: s);
    }
    _overlayShaders.clear();
    for (final img in _overlayImages) {
      HyperGlassRenderer.deferDispose(image: img);
    }
    _overlayImages.clear();
    _scene._frame.removeListener(markNeedsPaint);
    _scene._surfaces.remove(this);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_scene._backdrop == null) _scene._captureInPaint();
    final r = _scene._renderer, backdrop = _scene._backdrop;
    final boundary = _scene._boundary.currentContext?.findRenderObject();
    if (r == null || backdrop == null || boundary is! RenderBox || size.isEmpty) return;
    final dpr = _scene._dpr;
    final origin = (localToGlobal(Offset.zero, ancestor: boundary) - _scene._region.topLeft) * dpr;
    final w = (size.width * dpr).round(), h = (size.height * dpr).round();
    if (w < 2 || h < 2) return;
    final surface = origin & Size(w.toDouble(), h.toDouble());
    final m = material;
    final canvas = context.canvas;
    r.warmOnscreen(canvas);
    // Skia (no Impeller): the glass / blend shader is drawn straight onto the canvas from the plain
    // backdrop. toImageSync intermediates are what made Skia + ANGLE hold gigabytes; Impeller frees them
    // promptly, so it keeps the engine's exact multi-pass chain.
    if (!ui.ImageFilter.isShaderFilterSupported) {
      final ui.FragmentShader shader;
      if (m is GlassFilter) {
        shader =
            r.fusedGlassShader(
              m,
              backdrop,
              origin,
              w,
              h,
              radius * dpr,
              opacity: opacity,
              fx: fx,
              lengthScale: dpr / 3,
              mask: mask,
              backdropScale: _scene._scale,
            ) ??
            () {
              final e = _scene.refractFor(m, surface)!;
              return r.glassShader(
                m,
                e.tex,
                origin - e.crop.topLeft,
                w,
                h,
                radius * dpr,
                opacity: opacity,
                fx: fx,
                lengthScale: dpr / 3,
                mask: mask,
              );
            }();
      } else {
        m as BlendMaterial;
        final extent = _scene._region.size * dpr;
        shader = r.blendShader(
          m,
          _scene.blurredFor(m.sigma)!,
          extent,
          origin,
          w,
          h,
          radius * dpr,
          opacity: opacity,
          gradientBlur: gradientBlur,
          overlayMask: overlayMask,
          midBlurred: gradientBlur ? _scene.blurredFor(m.sigma * 0.25) : null,
          sharpBackdrop: gradientBlur ? backdrop : null,
        );
      }
      canvas
        ..save()
        ..translate(offset.dx, offset.dy)
        ..scale(size.width / w, size.height / h); // local units = physical pixels, as the shader expects
      canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader);
      canvas.restore();
      HyperGlassRenderer.deferDispose(shader: _lastShader); // kept until the next paint so the recorded frame can still use it
      _lastShader = shader;
      _paintOverlays(canvas, r, offset, dpr, w, h);
      return;
    }
    final ui.Image img;
    if (m is GlassFilter) {
      final e = _scene.refractFor(m, surface)!;
      img = r.drawGlass(m, e.tex, origin - e.crop.topLeft, w, h, radius * dpr, opacity: opacity, fx: fx, lengthScale: dpr / 3, mask: mask);
    } else {
      m as BlendMaterial;
      // backdrop extent in output (physical) pixels, whatever resolution it was captured at
      final extent = _scene._region.size * dpr;
      img = r.drawBlend(
        m,
        _scene.blurredFor(m.sigma)!,
        extent,
        origin,
        w,
        h,
        radius * dpr,
        opacity: opacity,
        gradientBlur: gradientBlur,
        overlayMask: overlayMask,
        midBlurred: gradientBlur ? _scene.blurredFor(m.sigma * 0.25) : null,
        sharpBackdrop: gradientBlur ? backdrop : null,
      );
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      offset & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    HyperGlassRenderer.deferDispose(image: _lastImage);
    _lastImage = img;
    _paintOverlays(canvas, r, offset, dpr, w, h);
  }

  /// Bloom stroke and press light, both drawn over the finished surface in physical-pixel local units.
  void _paintOverlays(Canvas canvas, HyperGlassRenderer r, Offset offset, double dpr, int w, int h) {
    for (final s in _overlayShaders) {
      HyperGlassRenderer.deferDispose(shader: s);
    }
    _overlayShaders.clear();
    for (final img in _overlayImages) {
      HyperGlassRenderer.deferDispose(image: img);
    }
    _overlayImages.clear();
    final fw = w.toDouble(), fh = h.toDouble();
    final rad = math.min(radius * dpr, math.min(fw, fh) / 2);
    final layers = [
      if (bloom != null) (r.bloomShader(bloom!, fw, fh, rad, dpr, opacity), BlendMode.plus),
      if (press != null && pressOpacity > 0.001)
        (r.pressShader(press!, pressAt * dpr, fw, fh, rad, dpr, pressOpacity * opacity), BlendMode.srcOver),
    ];
    if (layers.isEmpty) return;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..scale(size.width / w, size.height / h);
    for (final (shader, mode) in layers) {
      final rect = Rect.fromLTWH(0, 0, fw, fh);
      // FlutterFragCoord is in device space; render overlay at the origin first to keep coordinates aligned
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(
        rect,
        Paint()
          ..shader = shader
          ..blendMode = BlendMode.src,
      );
      final pic = rec.endRecording();
      final img = pic.toImageSync(w, h);
      pic.dispose();
      canvas.drawImage(img, Offset.zero, Paint()..blendMode = mode);
      _overlayImages.add(img);
      _overlayShaders.add(shader);
    }
    canvas.restore();
  }

  final _overlayShaders = <ui.FragmentShader>[];
  final _overlayImages = <ui.Image>[];
  ui.FragmentShader? _lastShader;
  ui.Image? _lastImage;
}
