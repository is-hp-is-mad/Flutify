import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'blend_material.dart';
import 'glass_filter.dart';
import 'hyper_glass_renderer.dart';

/// Caps Skia's GPU resource cache (Skia backend only, e.g. Windows / Linux today; a no-op on Impeller).
///
/// Every glass refresh allocates fresh offscreen textures; freed ones stay in Skia's cache for reuse,
/// which by default lets the process hold several hundred MB. 32 MB is enough for this pipeline.
Future<void> limitSkiaResourceCache({int megabytes = 32}) =>
    SystemChannels.skia.invokeMethod<void>('Skia.setResourceCacheMaxBytes', megabytes << 20);

/// Hosts the backdrop and the glass cards above it.
///
/// [background] is drawn inside a RepaintBoundary that is snapshotted at physical resolution after
/// every frame; that snapshot plays the role of the engine's backdrop texture. [child] holds
/// [HyperGlass] widgets (anywhere in its subtree).
class HyperGlassScene extends StatefulWidget {
  const HyperGlassScene({super.key, required this.background, required this.child, this.animate = true});

  final Widget background;
  final Widget child;

  /// Re-snapshot every frame (animated backgrounds). When false, only on rebuild/resize.
  final bool animate;

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
  static const _blendCaptureScale = 0.25;
  double _dpr = 1;
  final _surfaces = <_RenderGlass>{};
  final _refract = <GlassFilter, RefractTexture>{};
  final _blurred = <double, ui.Image>{};
  final _frame = ValueNotifier<int>(0);
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    _renderer = HyperGlassRenderer.ready;
    if (_renderer == null) {
      HyperGlassRenderer.shared().then((r) {
        if (!mounted) return;
        setState(() => _renderer = r);
        _scheduleSnapshot();
      }, onError: (Object e) => debugPrint('[hyper_glass] shader 加载失败：$e'));
    }
    _ticker = createTicker((_) => _scheduleSnapshot());
    if (widget.animate) _ticker!.start();
  }

  @override
  void didUpdateWidget(HyperGlassScene old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_ticker!.isActive) _ticker!.start();
    if (!widget.animate && _ticker!.isActive) _ticker!.stop();
    _scheduleSnapshot();
  }

  /// Logical px around each surface that refraction (reflectOffsetPx 110 physical) and blur may sample.
  static const _margin = 80.0;

  bool _pending = false;
  bool _inFlight = false;

  void _scheduleSnapshot() {
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      _snapshot();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
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
    // A scene whose surfaces are all frosted (menus, dialogs) only needs a heavily blurred backdrop, so
    // it is captured at 1/4 resolution directly: 1/16 of the texture memory, same frame rate.
    final scale = _surfaces.every((g) => g.material is BlendMaterial) ? _blendCaptureScale : 1.0;
    // Only the area under glass surfaces (plus room for refraction / reflection offsets) is captured
    // and processed.
    Rect? region;
    for (final g in _surfaces) {
      if (!g.attached || !g.hasSize) continue;
      final r = MatrixUtils.transformRect(g.getTransformTo(ro), Offset.zero & g.size);
      region = region == null ? r : region.expandToInclude(r);
    }
    region = region?.inflate(_margin).intersect(Offset.zero & ro.size);
    if (region == null || region.isEmpty) {
      _backdrop?.dispose();
      _backdrop = null;
      _clearRefract();
      return;
    }
    // Snap outwards to whole logical px, but never past the boundary: its size is usually fractional
    // (e.g. 1265.33), and rounding up would add a transparent last column / row that glass touching
    // the right or bottom edge then refracts as a thin line.
    final snapped = Rect.fromLTRB(
      region.left.floorToDouble(),
      region.top.floorToDouble(),
      math.min(region.right.ceilToDouble(), ro.size.width.floorToDouble()),
      math.min(region.bottom.ceilToDouble(), ro.size.height.floorToDouble()),
    );
    // ignore: invalid_use_of_protected_member
    final layer = ro.layer! as OffsetLayer;
    _inFlight = true;
    layer.toImage(snapped, pixelRatio: dpr * scale).then((img) {
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
      if (widget.animate) _scheduleSnapshot();
    }, onError: (Object _) => _inFlight = false);
  }

  void _clearRefract() {
    for (final i in _refract.values) {
      i.rgb.dispose();
      i.a?.dispose();
    }
    _refract.clear();
    for (final i in _blurred.values) {
      i.dispose();
    }
    _blurred.clear();
  }

  /// The backdrop blurred with [sigma] logical px, computed once per snapshot.
  ui.Image? blurredFor(double sigma) {
    final b = _backdrop, r = _renderer;
    if (b == null || r == null) return null;
    return _blurred.putIfAbsent(sigma, () => r.gaussianBlur(b, sigma * _dpr * _scale, downscale: _scale < 1 ? 1 : 4));
  }

  /// The pre-tinted refract texture for [g], computed once per snapshot and shared by all cards.
  RefractTexture? refractFor(GlassFilter g) {
    final b = _backdrop, r = _renderer;
    if (b == null || r == null) return null;
    return _refract.putIfAbsent(g, () => r.refractTexture(b, g));
  }

  @override
  void dispose() {
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
    this.child,
  });

  final GlassFilter filter;

  /// Logical pixels; converted to the engine's physical-pixel shape radius.
  final double borderRadius;
  final double opacity;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scene = context.dependOnInheritedWidgetOfExactType<_SceneScope>()!.state;
    // passthrough: the child gets this widget's own constraints (a fixed-size button stays centred,
    // a filling bar keeps filling) instead of Stack's loose ones that pin it to the top-left.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: _GlassSurface(scene: scene, material: filter, radius: borderRadius, opacity: opacity),
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
  const HyperBlendBlur({super.key, required this.material, this.borderRadius = 16, this.opacity = 1, this.child});

  final BlendMaterial material;
  final double borderRadius;
  final double opacity;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scene = context.dependOnInheritedWidgetOfExactType<_SceneScope>()!.state;
    // passthrough: the child gets this widget's own constraints (a fixed-size button stays centred,
    // a filling bar keeps filling) instead of Stack's loose ones that pin it to the top-left.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: _GlassSurface(scene: scene, material: material, radius: borderRadius, opacity: opacity),
        ),
        if (child != null) child!,
      ],
    );
  }
}

class _GlassSurface extends LeafRenderObjectWidget {
  const _GlassSurface({required this.scene, required this.material, required this.radius, required this.opacity});
  final _HyperGlassSceneState scene;
  final Object material; // GlassFilter | BlendMaterial
  final double radius, opacity;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGlass(scene, material, radius, opacity);

  @override
  void updateRenderObject(BuildContext context, _RenderGlass ro) {
    ro
      ..scene = scene
      ..material = material
      ..radius = radius
      ..opacity = opacity
      ..markNeedsPaint();
  }
}

class _RenderGlass extends RenderBox {
  _RenderGlass(this._scene, this.material, this.radius, this.opacity);

  _HyperGlassSceneState _scene;
  Object material;
  double radius, opacity;

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
    _lastShader?.dispose();
    _lastShader = null;
    _scene._frame.removeListener(markNeedsPaint);
    _scene._surfaces.remove(this);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final r = _scene._renderer, backdrop = _scene._backdrop;
    final boundary = _scene._boundary.currentContext?.findRenderObject();
    if (r == null || backdrop == null || boundary is! RenderBox || size.isEmpty) return;
    final dpr = _scene._dpr;
    final origin = (localToGlobal(Offset.zero, ancestor: boundary) - _scene._region.topLeft) * dpr;
    final w = (size.width * dpr).round(), h = (size.height * dpr).round();
    if (w < 2 || h < 2) return;
    final m = material;
    final canvas = context.canvas;
    // Skia (no Impeller): the glass / blend shader is drawn straight onto the canvas from the plain
    // backdrop. toImageSync intermediates are what made Skia + ANGLE hold gigabytes; Impeller frees them
    // promptly, so it keeps the engine's exact multi-pass chain.
    if (!ui.ImageFilter.isShaderFilterSupported) {
      final ui.FragmentShader? shader;
      if (m is GlassFilter) {
        shader = r.fusedGlassShader(m, backdrop, origin, w, h, radius * dpr, opacity: opacity);
      } else {
        m as BlendMaterial;
        final extent = _scene._region.size * dpr;
        shader = r.blendShader(m, _scene.blurredFor(m.sigma)!, extent, origin, w, h, radius * dpr, opacity: opacity);
      }
      if (shader != null) {
        canvas
          ..save()
          ..translate(offset.dx, offset.dy)
          ..scale(size.width / w, size.height / h); // local units = physical pixels, as the shader expects
        canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader);
        canvas.restore();
        _lastShader?.dispose(); // kept until the next paint so the recorded frame can still use it
        _lastShader = shader;
        return;
      }
    }
    final ui.Image img;
    if (m is GlassFilter) {
      img = r.drawGlass(m, _scene.refractFor(m)!, origin, w, h, radius * dpr, opacity: opacity);
    } else {
      m as BlendMaterial;
      // backdrop extent in output (physical) pixels, whatever resolution it was captured at
      final extent = _scene._region.size * dpr;
      img = r.drawBlend(m, _scene.blurredFor(m.sigma)!, extent, origin, w, h, radius * dpr, opacity: opacity);
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      offset & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    img.dispose();
  }

  ui.FragmentShader? _lastShader;
}
