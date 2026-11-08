import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/scheduler.dart';

import 'blend_material.dart';
import 'glass_filter.dart';
import 'shader_layout.g.dart';

typedef _Up = MiLmUpsampleTintLayout;
typedef _Gl = MiGlassV13F16Layout;

/// Pre-tinted refract texture: colour in [rgb], the engine's alpha channel in [a] (red).
/// Parameters of libhwui's press light. The formula is the system's; the values are tuned by eye
/// (MiuiHome's `PressLightManager` reads them from native code).
class PressLight {
  const PressLight({
    this.color = const ui.Color(0xffffffff),
    this.size = 180,
    this.fall = 3.2,
    this.strength = 0.42,
    this.peak = 0.1,
    this.ring1 = 0.12,
    this.ring2 = 0.07,
  });
  final ui.Color color;

  /// Diameter in logical px.
  final double size;
  final double fall, strength, peak, ring1, ring2;
}

/// Parameters of libhwui's bloom stroke; the defaults are `BloomStrokeToken.Glass_Stroke_Middle_Light`.
class BloomStroke {
  const BloomStroke({
    this.width = 0.8,
    this.color = const ui.Color(0x1affffff),
    this.innerBlur = 1.2,
    this.lightDir1 = const [0.2, 0.5, 0.0],
    this.lightDir2 = const [0.7, 0.8, 0.0],
    this.lightColor1 = const ui.Color(0x80ffffff),
    this.lightColor2 = const ui.Color(0x4dffffff),
    this.strokeFade = false,
  });

  /// width, gradient degree, colour rgba, normal width, light 1 xyz rgba, light 2 xyz rgba.
  factory BloomStroke.token(List<double> a) => BloomStroke(
    width: a[0],
    color: ui.Color.from(alpha: a[5], red: a[2], green: a[3], blue: a[4]),
    innerBlur: a[6],
    lightDir1: a.sublist(7, 10),
    lightColor1: ui.Color.from(alpha: a[13], red: a[10], green: a[11], blue: a[12]),
    lightDir2: a.sublist(14, 17),
    lightColor2: ui.Color.from(alpha: a[20], red: a[17], green: a[18], blue: a[19]),
  );

  final double width, innerBlur;

  /// The stroke follows libhwui's getStroke() gradient: top and bottom rim only.
  final bool strokeFade;
  final ui.Color color, lightColor1, lightColor2;
  final List<double> lightDir1, lightDir2;
}

typedef RefractTexture = ({ui.Image rgb, ui.Image? a});
typedef _TintSlots = ({
  int enabled,
  int luminanceCoeffs,
  int glassColor,
  int darkerRange,
  int bgColorSat,
  int bgColorBri,
  int luminanceAmount,
  int saturation,
  int brightness,
  int innerColorWhite,
  int innerColorMix,
  int burn,
  int darker,
});
const _TintSlots _upTint = (
  enabled: _Up.glass_tint_enabled__f,
  luminanceCoeffs: _Up.glass_tint_luminance_coeffs,
  glassColor: _Up.glass_tint_glass_color,
  darkerRange: _Up.glass_tint_darker_range,
  bgColorSat: _Up.glass_tint_bg_color_sat,
  bgColorBri: _Up.glass_tint_bg_color_bri,
  luminanceAmount: _Up.glass_tint_luminance_amount,
  saturation: _Up.glass_tint_saturation,
  brightness: _Up.glass_tint_brightness,
  innerColorWhite: _Up.glass_tint_inner_color_white,
  innerColorMix: _Up.glass_tint_inner_color_mix,
  burn: _Up.glass_tint_burn,
  darker: _Up.glass_tint_darker,
);
const _TintSlots _glTint = (
  enabled: _Gl.glass_tint_enabled__f,
  luminanceCoeffs: _Gl.glass_tint_luminance_coeffs,
  glassColor: _Gl.glass_tint_glass_color,
  darkerRange: _Gl.glass_tint_darker_range,
  bgColorSat: _Gl.glass_tint_bg_color_sat,
  bgColorBri: _Gl.glass_tint_bg_color_bri,
  luminanceAmount: _Gl.glass_tint_luminance_amount,
  saturation: _Gl.glass_tint_saturation,
  brightness: _Gl.glass_tint_brightness,
  innerColorWhite: _Gl.glass_tint_inner_color_white,
  innerColorMix: _Gl.glass_tint_inner_color_mix,
  burn: _Gl.glass_tint_burn,
  darker: _Gl.glass_tint_darker,
);
typedef _Sdf = ({ui.Image a, ui.Image b, double range});

/// Where this package's shaders are bundled in the host app.
const shaderRoot = 'packages/hyper_glass/';

/// Dart translation of `miglass::Renderer` (port/src/hyper_glass.cpp): the engine's
/// AcquireGlassBlurTextures / ExecuteLMGaussianBlur / GetOrCreateSdfTexture / MiGlassContents::Render
/// expressed as offscreen FragmentShader passes. Every image is in physical pixels.
class HyperGlassRenderer {
  HyperGlassRenderer._(this._sdf, this._glass, this._blur, this._down, this._up, this._blend, this._press, this._bloom);

  final ui.FragmentProgram _sdf, _glass, _blur, _down, _up, _blend, _press, _bloom;

  static Future<List<ui.FragmentProgram>>? _programs;
  static Future<HyperGlassRenderer>? _sharedFuture;
  static HyperGlassRenderer? _ready;

  /// Process-wide renderer (programs warmed up, SDF cache kept) shared by every scene, so a scene built
  /// mid-frame can paint in that frame and opening one neither recompiles nor rebuilds SDFs; null until
  /// [shared] has completed once.
  static HyperGlassRenderer? get ready => _ready;

  /// Loads (once) and returns the process-wide renderer; never dispose it.
  static Future<HyperGlassRenderer> shared() => _sharedFuture ??= load().then((r) => _ready = r);

  /// Timing lines go through [debugPrint] (Flutify mirrors it into its log file).
  static void _log(String message) => debugPrint('[hyper_glass] $message');

  /// Loads the programs once per process and warms them up, so the first glass / menu frame does not
  /// stall on GPU pipeline compilation (Skia compiles a runtime effect on its first draw).
  static Future<HyperGlassRenderer> load() async {
    final p = await (_programs ??= _loadPrograms());
    return HyperGlassRenderer._(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
  }

  static Future<List<ui.FragmentProgram>> _loadPrograms() async {
    // Loaded one by one (not Future.wait) so the log shows each program's SkSL parse time.
    final p = <ui.FragmentProgram>[];
    for (final asset in [
      MiGlassSdfLayout.asset,
      MiGlassV13F16Layout.asset,
      MiLmBlurLayout.asset,
      MiLmDownsampleLayout.asset,
      MiLmUpsampleTintLayout.asset,
      'shaders/mi_blend_blur.frag',
      'shaders/mi_press_light.frag',
      'shaders/mi_bloom_stroke.frag',
    ]) {
      final clock = Stopwatch()..start();
      p.add(await ui.FragmentProgram.fromAsset('$shaderRoot$asset'));
      _log('载入 $asset：${clock.elapsedMilliseconds} ms');
    }
    final clock = Stopwatch()..start();
    await HyperGlassRenderer._(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7])._warmUp();
    _log('离屏预热：${clock.elapsedMilliseconds} ms');
    return p;
  }

  Future<void> _warmUp() async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 128, 128), ui.Paint()..color = const ui.Color(0xff3070c0));
    final pic = rec.endRecording();
    final src = pic.toImageSync(128, 128);
    pic.dispose();
    const g = GlassFilter();
    final blurred = gaussianBlur(src, 20);
    if (ui.ImageFilter.isShaderFilterSupported) {
      // Impeller runs the engine's full pass chain.
      final refract = refractTexture(src, g);
      final outputs = [
        lmGaussianBlur(src, 60), // downsample path
        drawGlass(g, refract, ui.Offset.zero, 96, 96, 24),
        drawBlend(BlendMaterial.popupMenuLight, blurred, const ui.Size(128, 128), ui.Offset.zero, 64, 64, 16),
      ];
      // reading back forces every pass in the chain to be rasterized now
      for (final o in outputs) {
        await o.toByteData();
        o.dispose();
      }
      for (final i in [src, refract.rgb, refract.a, blurred]) {
        i?.dispose();
      }
    } else {
      // Skia uses the SDF pass and the blur offscreen. Its glass and blend shaders are drawn to the screen,
      // a different GPU pipeline, so warming them offscreen would just compile them twice; [warmOnscreen]
      // does it inside the first frame instead. A fusable filter never runs the LM down / blur / upsample
      // programs, so they are left to compile lazily if a non-fused glass ever shows up.
      final fused = canFuse(g);
      final refract = fused ? null : refractTexture(src, g);
      final wide = fused ? null : lmGaussianBlur(src, 60); // downsample path
      for (final o in [blurred, ?refract?.rgb, ?wide, _sdfTexture(96, 96, 24, g.edgePx, g.edgePow).a]) {
        await o.toByteData();
      }
      for (final i in [blurred, refract?.rgb, refract?.a, wide]) {
        i?.dispose();
      }
      _warmImage = src;
    }
    dispose();
  }

  static ui.Image? _warmImage;
  static final _warmShaders = <ui.FragmentShader>[];

  /// Skia: draws the glass and blend shaders once, invisibly, into the frame being recorded, so their
  /// on-screen pipelines compile before the app's first frame is shown. Once per process.
  void warmOnscreen(ui.Canvas canvas) {
    final src = _warmImage;
    if (src == null) return;
    _warmImage = null;
    const g = GlassFilter();
    _warmShaders.addAll([
      fusedGlassShader(g, src, ui.Offset.zero, 2, 2, 1, opacity: 0)!,
      blendShader(BlendMaterial.popupMenuLight, src, const ui.Size(128, 128), ui.Offset.zero, 2, 2, 1, opacity: 0),
      bloomShader(const BloomStroke(), 2, 2, 1, 1, 0),
    ]);
    for (final s in _warmShaders) {
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 1, 1),
        ui.Paint()
          ..shader = s
          ..blendMode = identical(s, _warmShaders.last) ? ui.BlendMode.plus : ui.BlendMode.srcOver, // bloom
      );
    }
  }

  static final _gen0Shaders = <ui.FragmentShader>[];
  static final _gen1Shaders = <ui.FragmentShader>[];
  static final _gen0Images = <ui.Image>[];
  static final _gen1Images = <ui.Image>[];
  static bool _deferScheduled = false;

  /// Defers disposal of a [shader] or [image] until after the raster thread has consumed the current frame.
  /// On Impeller (Android), `Picture.toImageSync` defers GPU realization to the raster thread; disposing a
  /// shader or intermediate image synchronously inside `paint()` invalidates its handle before rasterization.
  static void deferDispose({ui.Image? image, ui.FragmentShader? shader}) {
    if (image != null) _gen0Images.add(image);
    if (shader != null) _gen0Shaders.add(shader);
    if (_deferScheduled) return;
    _deferScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _stepDeferred());
  }

  static void _stepDeferred() {
    for (final s in _gen1Shaders) {
      s.dispose();
    }
    _gen1Shaders
      ..clear()
      ..addAll(_gen0Shaders);
    _gen0Shaders.clear();
    for (final i in _gen1Images) {
      i.dispose();
    }
    _gen1Images
      ..clear()
      ..addAll(_gen0Images);
    _gen0Images.clear();
    if (_gen1Shaders.isNotEmpty || _gen1Images.isNotEmpty) {
      _deferScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _stepDeferred());
    } else {
      _deferScheduled = false;
    }
  }

  static void flushDeferred() {
    _deferScheduled = false;
    for (final s in [..._gen1Shaders, ..._gen0Shaders]) {
      s.dispose();
    }
    _gen1Shaders.clear();
    _gen0Shaders.clear();
    for (final i in [..._gen1Images, ..._gen0Images]) {
      i.dispose();
    }
    _gen1Images.clear();
    _gen0Images.clear();
  }

  // One fresh FragmentShader per pass: toImageSync rasterizes later, so uniforms must not be shared.
  static ui.Image _pass(ui.FragmentShader s, int w, int h) {
    s.setFloat(0, w.toDouble());
    s.setFloat(1, h.toDouble());
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()
        ..shader = s
        ..blendMode = ui.BlendMode.src,
    );
    final pic = rec.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    deferDispose(shader: s);
    return img;
  }

  static void _vec(ui.FragmentShader s, int slot, List<double> v) {
    for (var i = 0; i < v.length; i++) {
      s.setFloat(slot + i, v[i]);
    }
  }

  ui.Image _downsample(ui.Image src, int w, int h, int type) {
    final s = _down.fragmentShader();
    _vec(s, MiLmDownsampleLayout.downsample_info_image_size, [src.width.toDouble(), src.height.toDouble()]);
    s.setFloat(MiLmDownsampleLayout.downsample_info_downsample_type__f, type.toDouble());
    _vec(s, MiLmDownsampleLayout.downsample_info_down_size, [w.toDouble(), h.toDouble()]);
    s.setImageSampler(MiLmDownsampleLayout.sampler_texture_sampler, src);
    return _pass(s, w, h);
  }

  ui.Image _blurPass(ui.Image src, LMGaussianState st, int dir) {
    final s = _blur.fragmentShader();
    _vec(s, MiLmBlurLayout.blur_info_image_size, [src.width.toDouble(), src.height.toDouble()]);
    s.setFloat(MiLmBlurLayout.blur_info_sample_radius__f, st.count.toDouble());
    s.setFloat(MiLmBlurLayout.blur_info_is_self_blur__f, 0);
    for (var i = 0; i < 7; i++) {
      s.setFloat(MiLmBlurLayout.blur_info_blur_offset + i, dir == 0 ? st.offset[i] : 0.0);
      s.setFloat(MiLmBlurLayout.blur_info_blur_offset + 7 + i, dir == 1 ? st.offset[i] : 0.0);
      s.setFloat(MiLmBlurLayout.blur_info_blur_weight + i, st.weight[i]);
    }
    s.setImageSampler(MiLmBlurLayout.sampler_texture_sampler, src);
    return _pass(s, src.width, src.height);
  }

  /// BuildGlassTintConfig (0xd3d778) -> GlassTintInfo.
  static void _fillTint(ui.FragmentShader s, GlassFilter? g) => _fillTintAt(s, g, _upTint);

  static void _fillTintAt(ui.FragmentShader s, GlassFilter? g, _TintSlots t) {
    if (g == null) {
      s.setFloat(t.enabled, 0);
      return;
    }
    final b = g.luminanceBezier;
    _vec(s, t.luminanceCoeffs, [
      (b[1] * 3.0 - b[0]) + b[2] * -3.0 + b[3],
      b[1] * -6.0 + b[0] * 3.0 + b[2] * 3.0,
      b[1] * 3.0 + b[0] * -3.0,
      b[0],
    ]);
    _vec(s, t.glassColor, g.glassColor);
    _vec(s, t.darkerRange, g.darkerRange);
    s.setFloat(t.enabled, 1);
    s.setFloat(t.bgColorSat, g.bgColorSaturation);
    s.setFloat(t.bgColorBri, g.bgColorBrightness);
    s.setFloat(t.luminanceAmount, g.luminanceAmount);
    s.setFloat(t.saturation, g.saturation);
    s.setFloat(t.brightness, g.brightness);
    s.setFloat(t.innerColorWhite, g.innerColorWhite);
    s.setFloat(t.innerColorMix, g.innerColorMix);
    s.setFloat(t.burn, math.max(1.0, g.burn));
    s.setFloat(t.darker, g.darker);
  }

  /// ExecuteLMGaussianBlur: downsample -> blur X/Y -> MiLmUpsampleSimple back to the source size.
  ui.Image lmGaussianBlur(ui.Image src, double radius) => _lmGaussianBlur(src, radius).rgb;

  /// With [tint] the result's alpha carries data, so it is returned as a separate opaque image [a].
  RefractTexture _lmGaussianBlur(ui.Image src, double radius, {GlassFilter? tint, ui.Image? bigBlur}) {
    final st = LMGaussianState.forRadius(radius);
    final rw = (src.width ~/ 64) * 64, rh = (src.height ~/ 64) * 64;
    final temps = <ui.Image>[];
    var cur = src;
    switch (st.factor) {
      case 1:
        break;
      case 2:
        cur = _downsample(src, src.width ~/ 2, src.height ~/ 2, 0);
      case 4:
        cur = _downsample(src, math.max(1, rw ~/ 4), math.max(1, rh ~/ 4), 1);
      case 16:
        final d8 = _downsample(src, math.max(1, rw ~/ 8), math.max(1, rh ~/ 8), 2);
        temps.add(d8);
        cur = _downsample(d8, math.max(1, d8.width ~/ 2), math.max(1, d8.height ~/ 2), 0);
      default:
        cur = _downsample(src, math.max(1, rw ~/ st.factor), math.max(1, rh ~/ st.factor), 2);
    }
    if (!identical(cur, src)) temps.add(cur);
    final bx = _blurPass(cur, st, 0);
    final by = _blurPass(bx, st, 1);
    temps.addAll([bx]);
    if (tint == null && st.factor == 1) {
      // Memory: at factor 1 the plain upsample only adds +-0.0045 dither noise, so its copy is skipped.
      for (final t in temps) {
        deferDispose(image: t);
      }
      return (rgb: by, a: null);
    }

    ui.Image upsample(int pass) {
      final s = _up.fragmentShader();
      s.setFloat(_Up.fl_out_pass, pass.toDouble());
      s.setFloat(_Up.hdr_info_enable_hdr__f, 0);
      _fillTint(s, tint);
      s.setFloat(_Up.upsample_info_noise_coeff, 0.0045); // 0x3b9374bc
      _vec(s, _Up.upsample_info_output_size, [src.width.toDouble(), src.height.toDouble()]);
      s.setFloat(_Up.upsample_info_downsample_scale, st.factor.toDouble());
      s.setImageSampler(_Up.sampler_big_blur_sampler, bigBlur ?? by);
      s.setImageSampler(_Up.sampler_texture_sampler, by);
      return _pass(s, src.width, src.height);
    }

    final out = (rgb: upsample(0), a: tint != null ? upsample(1) : null);
    deferDispose(image: by);
    for (final t in temps) {
      deferDispose(image: t);
    }
    return out;
  }

  /// Canvas::AcquireGlassBlurTextures (new path): returns the pre-tinted refract texture.
  ///
  /// Memory: when a radius gives the minimum kernel (factor 1, variance clamped to 0.1, neighbour
  /// weight e^-5 ~ 0.7%) the blur is a near-identity and the source is used as is.
  RefractTexture refractTexture(ui.Image backdrop, GlassFilter g) {
    ui.Image blurOrSource(double radius) => _isNearIdentity(radius) ? backdrop : lmGaussianBlur(backdrop, radius);
    final base = blurOrSource(g.refractBlur);
    final reflect = g.blurSourceMode == g.refractBlur.toInt() ? base : blurOrSource(g.baseBlur);
    final tinted = _lmGaussianBlur(reflect, g.baseBlur, tint: g, bigBlur: base);
    if (!identical(reflect, base) && !identical(reflect, backdrop)) deferDispose(image: reflect);
    if (!identical(base, backdrop)) deferDispose(image: base);
    return tinted;
  }

  static bool _isNearIdentity(double radius) {
    final st = LMGaussianState.forRadius(radius);
    return st.factor == 1 && st.variance <= 0.1;
  }

  final _sdfCache = <String, _Sdf>{};

  /// MiRenderHelper::GetOrCreateSdfTexture (0xe6429c) + "MiGlassSDF" pass (0xd62164).
  _Sdf _sdfTexture(double w, double h, double radius, double edgePx, double edgePow) {
    final half = math.min(w, h) * 0.5;
    if (radius <= 0) radius = half;
    var r = half.truncateToDouble();
    if (radius <= r) r = radius;
    var e = half;
    if (half <= r) e = r;
    if (edgePx <= half) e = edgePx;
    final big = math.max(r.toInt(), e.toInt());
    final full = big * 2 + 20, n = full ~/ 2;
    final isCircle = (half - r <= 1.0) ? 1.0 : 0.0;
    final key = '$n/${(r * 4).toInt()}/${(e * 4 + edgePow * 10).toInt()}';
    final hit = _sdfCache[key];
    if (hit != null) return hit;
    if (_sdfCache.length >= 32) {
      // morphing shapes create a new key every frame; images still in flight stay alive in their pictures
      for (final i in _sdfCache.values) {
        i.a.dispose();
        i.b.dispose();
      }
      _sdfCache.clear();
    }
    // RGBA16F in the engine; here two opaque 8-bit images (see tools/to_flutter.py, SDF_ENC).
    ui.Image half8(int pass) {
      final s = _sdf.fragmentShader();
      _vec(s, MiGlassSdfLayout.pushConstants_rectDimensions, [full.toDouble(), full.toDouble(), r]);
      _vec(s, MiGlassSdfLayout.pushConstants_edgeParams, [e, edgePow, 0]);
      s.setFloat(MiGlassSdfLayout.pushConstants_uIsCircle__f, isCircle);
      s.setFloat(MiGlassSdfLayout.fl_sdf_range, n.toDouble());
      s.setFloat(MiGlassSdfLayout.fl_sdf_pass, pass.toDouble());
      return _pass(s, n, n);
    }

    return _sdfCache[key] = (a: half8(0), b: half8(1), range: n.toDouble());
  }

  /// MiGlassContents::Render (MiGlassV13F16). [origin] is the card's top-left inside the
  /// refract texture; the result is a [w]x[h] premultiplied image of the glass.
  ui.Image drawGlass(
    GlassFilter g,
    RefractTexture refract,
    ui.Offset origin,
    int w,
    int h,
    double shapeRadius, {
    double opacity = 1.0,
    GlassFx fx = const GlassFx(),
    double lengthScale = 1,
    ui.Image? mask,
  }) => _pass(
    _glassShader(g, origin, w, h, shapeRadius, opacity, fx, lengthScale, mask, refract: refract),
    w,
    h,
  );

  /// [drawGlass] as a shader, to draw directly over a [w]x[h] rect in physical-pixel local units.
  ui.FragmentShader glassShader(
    GlassFilter g,
    RefractTexture refract,
    ui.Offset origin,
    int w,
    int h,
    double shapeRadius, {
    double opacity = 1.0,
    GlassFx fx = const GlassFx(),
    double lengthScale = 1,
    ui.Image? mask,
  }) => _glassShader(g, origin, w, h, shapeRadius, opacity, fx, lengthScale, mask, refract: refract);

  final _kernels = <GlassFilter, ({double k0, List<double> k, int radius})?>{};

  /// Whether [g] can be drawn by [fusedGlassShader].
  bool canFuse(GlassFilter g) => _kernels.putIfAbsent(g, () => fusedRefractKernel(g)) != null;

  /// The glass as a shader that reads the plain [backdrop] (no refract texture chain): reflect blur,
  /// tint blur and the tinting upsample run inside the glass shader (see tools/to_flutter.py,
  /// FUSED_REFRACT). Draw it over a [w]x[h] rect whose local units are physical pixels. Null when [g]
  /// cannot be fused; use [refractTexture] + [glassShader] then.
  ui.FragmentShader? fusedGlassShader(
    GlassFilter g,
    ui.Image backdrop,
    ui.Offset origin,
    int w,
    int h,
    double shapeRadius, {
    double opacity = 1.0,
    GlassFx fx = const GlassFx(),
    double lengthScale = 1,
    ui.Image? mask,
    double backdropScale = 1,
  }) {
    if (_kernels.length > 64) _kernels.clear(); // the lab creates a filter per slider tick
    final kernel = _kernels.putIfAbsent(g, () => fusedRefractKernel(g));
    if (kernel == null) return null;
    return _glassShader(
      g,
      origin,
      w,
      h,
      shapeRadius,
      opacity,
      fx,
      lengthScale,
      mask,
      backdrop: backdrop,
      kernel: kernel,
      backdropScale: backdropScale,
    );
  }

  ui.FragmentShader _glassShader(
    GlassFilter g,
    ui.Offset origin,
    int w,
    int h,
    double shapeRadius,
    double opacity,
    GlassFx fx,
    double lengthScale,
    ui.Image? mask, {
    RefractTexture? refract,
    ui.Image? backdrop,
    ({double k0, List<double> k, int radius})? kernel,
    double backdropScale = 1,
  }) {
    final fw = w.toDouble(), fh = h.toDouble();
    final half = math.min(fw, fh) * 0.5;
    var radius = g.cornerRadius > 0 ? g.cornerRadius : shapeRadius;
    radius = math.min(math.min(radius, half.floorToDouble()), 502.0);
    final edge = math.min(math.min(g.edgePx * lengthScale, half), 502.0);
    final sdf = _sdfTexture(fw, fh, radius, edge, g.edgePow);

    final s = _glass.fragmentShader();
    _vec(s, _Gl.fl_rect, [0, 0, fw, fh]);
    _vec(s, _Gl.uResolution, [-origin.dx, -origin.dy]);
    final src = refract?.rgb ?? backdrop!;
    // Everything else in the shader is in physical px; a backdrop captured at [backdropScale] still spans
    // the same physical extent, so only the normalisation changes.
    _vec(s, _Gl.uInvResolution, [backdropScale / src.width, backdropScale / src.height]);
    _vec(s, _Gl.uGeoPxSize, [fw, fh, radius]);
    s.setFloat(_Gl.uShapeEdgePx, edge);
    s.setFloat(_Gl.uShapeEdgePow, g.edgePow);
    s.setFloat(_Gl.uShapeThicknessPx, g.thicknessPx * lengthScale);
    s.setFloat(_Gl.uShapeReflectOffsetPx, g.reflectOffsetPx * lengthScale);
    _vec(s, _Gl.uDirectionalLightDirection, g.lightDir);
    s.setFloat(_Gl.uDirectionalLightIntensity, g.lightIntensity);
    s.setFloat(_Gl.uDirectionalLightOppositeIntensity, g.lightOpposite);
    s.setFloat(_Gl.uDirectionalLightAngleRange, g.lightAngleRange);
    s.setFloat(_Gl.uDirectionalLightLightWidth, 8.0); // 0x41000000 in MiGlassContents::Render
    s.setFloat(_Gl.uRefractIOR, g.refractIOR);
    s.setFloat(_Gl.uReflectionStrength, g.reflectionStrength);
    s.setFloat(_Gl.uReflectionLighten, g.reflectionLighten);
    s.setFloat(_Gl.uDirectionalLightEdgePow, g.lightEdgePow);
    _vec(s, _Gl.uGlassColor, g.glassColor);
    s.setFloat(_Gl.uInnerBottom, g.innerBottom);
    s.setFloat(_Gl.uRefractBlurScale, 0);
    s.setFloat(_Gl.uColorPow, g.colorPow);
    s.setFloat(_Gl.uAlpha, opacity * g.alpha);
    _vec(s, _Gl.uScale, [1, 1]);
    s.setFloat(_Gl.uUseMaskTex__f, 0);
    s.setFloat(_Gl.uHit__f, fx.hit);
    s.setFloat(_Gl.uUnshade, g.unshade);
    _vec(s, _Gl.uRotationTrig, [math.cos(fx.rotation), math.sin(fx.rotation)]);
    final icon = fx.iconRect;
    if (icon != null && mask != null) {
      final k = lengthScale * 3; // logical -> physical
      s.setFloat(_Gl.uIconMove__f, fx.iconMode.toDouble());
      _vec(s, _Gl.uIconGeoPxPos, [icon.left * k, icon.top * k]);
      s.setFloat(_Gl.iLightRadius, fx.iconRadius * k);
      _vec(s, _Gl.uIconGeoPxSize, [icon.width * k, icon.height * k, fx.iconRadius * k]);
      s.setFloat(_Gl.uIconLightStrength, fx.iconStrength);
      _vec(s, _Gl.uDynamicLightDirection, fx.dynamicLight ?? const [0, 0, 0]);
    } else {
      s.setFloat(_Gl.uIconMove__f, 0);
      s.setFloat(_Gl.uIconLightStrength, 0);
    }
    s.setFloat(_Gl.uHasRotation__f, fx.rotation != 0 ? 1 : 0);
    s.setFloat(_Gl.uUsePowGate__f, (g.colorPow - 1.0).abs() > 0.001 ? 1 : 0);
    s.setFloat(_Gl.colorSpaceConvertMode__f, 0);
    s.setFloat(_Gl.fl_sdf_range, sdf.range);
    s.setImageSampler(_Gl.sampler_uSdfTex, sdf.a);
    s.setImageSampler(_Gl.sampler_uMaskTex, mask ?? sdf.a);
    s.setImageSampler(_Gl.sampler_fl_sdfB, sdf.b);
    if (kernel == null) {
      s.setFloat(_Gl.fl_fused, 0);
      s.setImageSampler(_Gl.sampler_uRefractTex, refract!.rgb);
      s.setImageSampler(_Gl.sampler_fl_refractA, refract.a ?? refract.rgb);
      s.setImageSampler(_Gl.sampler_fl_backdrop, refract.rgb);
    } else {
      s.setFloat(_Gl.fl_fused, 1);
      s.setFloat(_Gl.fl_kr, kernel.radius.toDouble());
      s.setFloat(_Gl.fl_k0, kernel.k0);
      _vec(s, _Gl.fl_k, kernel.k);
      s.setFloat(_Gl.hdr_info_enable_hdr__f, 0);
      _fillTintAt(s, g, _glTint);
      s.setFloat(_Gl.upsample_info_noise_coeff, 0.0045); // 0x3b9374bc, as in the upsample pass
      s.setImageSampler(_Gl.sampler_uRefractTex, backdrop!);
      s.setImageSampler(_Gl.sampler_fl_refractA, backdrop);
      s.setImageSampler(_Gl.sampler_fl_backdrop, backdrop);
    }
    return s;
  }

  /// libhwui's glass press light as a shader over a [w]x[h] rect in physical-pixel local units.
  ui.FragmentShader pressShader(PressLight p, ui.Offset center, double w, double h, double radius, double dpr, double opacity) {
    final s = _press.fragmentShader();
    var i = 0;
    void f(double v) => s.setFloat(i++, v);
    f(w);
    f(h);
    f(radius);
    f(p.color.r);
    f(p.color.g);
    f(p.color.b);
    f(p.color.a);
    f(center.dx);
    f(center.dy);
    final d = p.size * dpr;
    f(d);
    f(d);
    f(p.fall);
    f(p.strength);
    f(p.peak);
    f(p.ring1);
    f(p.ring2);
    f(opacity);
    return s;
  }

  /// libhwui's MiBloomStrokeFilter (stroke + rim lights) over a [w]x[h] rect in physical-pixel local units.
  ui.FragmentShader bloomShader(BloomStroke b, double w, double h, double radius, double dpr, double opacity) {
    final s = _bloom.fragmentShader();
    var i = 0;
    void f(double v) => s.setFloat(i++, v);
    void c(ui.Color v) {
      f(v.r);
      f(v.g);
      f(v.b);
      f(v.a);
    }

    f(w / 2);
    f(h / 2);
    f(radius);
    f(b.width * dpr);
    c(b.color);
    f(b.innerBlur * dpr);
    b.lightDir1.forEach(f);
    b.lightDir2.forEach(f);
    c(b.lightColor1);
    c(b.lightColor2);
    f(opacity);
    f(b.strokeFade ? 1 : 0);
    return s;
  }

  /// The bloom stroke alone over a rounded rect of [size] logical px, for surfaces blurred without a scene.
  /// [radius] is in logical px.
  void paintBloom(ui.Canvas canvas, ui.Size size, BloomStroke b, double radius, double dpr, {double opacity = 1}) {
    final w = (size.width * dpr).round(), h = (size.height * dpr).round();
    if (w < 2 || h < 2) return;
    final fw = w.toDouble(), fh = h.toDouble();
    final shader = bloomShader(b, fw, fh, math.min(radius * dpr, math.min(fw, fh) / 2), dpr, opacity);
    final rect = ui.Rect.fromLTWH(0, 0, fw, fh);
    canvas
      ..save()
      ..scale(size.width / w, size.height / h);
    if (ui.ImageFilter.isShaderFilterSupported) {
      // Impeller's FlutterFragCoord is in device space, so it is rendered at the origin first
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(
        rect,
        ui.Paint()
          ..shader = shader
          ..blendMode = ui.BlendMode.src,
      );
      final pic = rec.endRecording();
      final img = pic.toImageSync(w, h);
      pic.dispose();
      canvas.drawImage(img, ui.Offset.zero, ui.Paint()..blendMode = ui.BlendMode.plus);
      img.dispose();
    } else {
      canvas.drawRect(
        rect,
        ui.Paint()
          ..shader = shader
          ..blendMode = ui.BlendMode.plus,
      );
    }
    canvas.restore();
  }

  /// Gaussian blur of [src] with [sigma] physical px, computed at 1/4 resolution (sampled bilinearly
  /// afterwards); the result covers the same area as [src].
  ui.Image gaussianBlur(ui.Image src, double sigma, {int downscale = 4}) {
    final k = downscale;
    final w = math.max(1, src.width ~/ k), h = math.max(1, src.height ~/ k);
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    final dst = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    c.saveLayer(
      dst,
      ui.Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma / k, sigmaY: sigma / k, tileMode: ui.TileMode.clamp),
    );
    c.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      dst,
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    c.restore();
    final pic = rec.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  /// HyperOS blendBlur surface: [blurred] backdrop (any resolution covering [backdropSize]) with the
  /// material's blend layers, clipped to a rounded rect of [radius] physical px.
  ui.Image drawBlend(
    BlendMaterial m,
    ui.Image blurred,
    ui.Size backdropSize,
    ui.Offset origin,
    int w,
    int h,
    double radius, {
    double opacity = 1.0,
    bool gradientBlur = false,
    ui.Color? overlayMask,
    ui.Image? midBlurred,
    ui.Image? sharpBackdrop,
  }) => _pass(
    blendShader(
      m,
      blurred,
      backdropSize,
      origin,
      w,
      h,
      radius,
      opacity: opacity,
      gradientBlur: gradientBlur,
      overlayMask: overlayMask,
      midBlurred: midBlurred,
      sharpBackdrop: sharpBackdrop,
    ),
    w,
    h,
  );

  /// [drawBlend] as a shader, to draw directly over a [w]x[h] rect in physical-pixel local units.
  ui.FragmentShader blendShader(
    BlendMaterial m,
    ui.Image blurred,
    ui.Size backdropSize,
    ui.Offset origin,
    int w,
    int h,
    double radius, {
    double opacity = 1.0,
    bool gradientBlur = false,
    ui.Color? overlayMask,
    ui.Image? midBlurred,
    ui.Image? sharpBackdrop,
  }) {
    final s = _blend.fragmentShader();
    var idx = 0;
    void f(double v) => s.setFloat(idx++, v);
    f(w.toDouble());
    f(h.toDouble());
    f(origin.dx);
    f(origin.dy);
    f(1.0 / backdropSize.width);
    f(1.0 / backdropSize.height);
    f(radius);
    f(math.min(m.layers.length, 3).toDouble());
    for (var i = 0; i < 3; i++) {
      final l = i < m.layers.length ? m.layers[i] : null;
      final c = l?.color ?? const ui.Color(0x00000000);
      f(c.r);
      f(c.g);
      f(c.b);
      f(c.a);
    }
    for (var i = 0; i < 3; i++) {
      final l = i < m.layers.length ? m.layers[i] : null;
      f(l == null ? 0.0 : l.mode.index.toDouble());
    }
    f(opacity);
    f(gradientBlur ? 1.0 : 0.0);
    final om = overlayMask ?? const ui.Color(0x00000000);
    f(om.r);
    f(om.g);
    f(om.b);
    f(om.a);
    s.setImageSampler(0, blurred);
    s.setImageSampler(1, midBlurred ?? blurred);
    s.setImageSampler(2, sharpBackdrop ?? blurred);
    return s;
  }

  void dispose() {
    flushDeferred();
    for (final i in _sdfCache.values) {
      i.a.dispose();
      i.b.dispose();
    }
    _sdfCache.clear();
  }
}
