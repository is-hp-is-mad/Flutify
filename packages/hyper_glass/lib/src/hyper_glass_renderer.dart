import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;

import 'blend_material.dart';
import 'glass_filter.dart';
import 'shader_layout.g.dart';

typedef _Up = MiLmUpsampleTintLayout;
typedef _Gl = MiGlassV13F16Layout;

/// Pre-tinted refract texture: colour in [rgb], the engine's alpha channel in [a] (red).
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

/// Dart translation of `miglass::Renderer` (port/src/hyper_glass.cpp): the engine's
/// AcquireGlassBlurTextures / ExecuteLMGaussianBlur / GetOrCreateSdfTexture / MiGlassContents::Render
/// expressed as offscreen FragmentShader passes. Every image is in physical pixels.
/// Shaders ship inside this package, so their asset keys carry the package prefix.
const _assetPrefix = 'packages/hyper_glass/';

class HyperGlassRenderer {
  HyperGlassRenderer._(this._sdf, this._glass, this._blur, this._down, this._up, this._blend);

  final ui.FragmentProgram _sdf, _glass, _blur, _down, _up, _blend;

  static Future<List<ui.FragmentProgram>>? _programs;
  static Future<HyperGlassRenderer>? _sharedFuture;
  static HyperGlassRenderer? _ready;

  /// Process-wide renderer (programs warmed up, SDF cache kept) shared by every scene, so opening a
  /// scene neither recompiles nor rebuilds SDFs; null until [shared] has completed once.
  static HyperGlassRenderer? get ready => _ready;

  /// Loads (once) and returns the process-wide renderer; never dispose it.
  static Future<HyperGlassRenderer> shared() => _sharedFuture ??= load().then((r) => _ready = r);

  /// Loads the programs once per process and warms them up, so the first glass / menu frame does not
  /// stall on GPU pipeline compilation (Skia compiles a runtime effect on its first draw).
  static Future<HyperGlassRenderer> load() async {
    final p = await (_programs ??= _loadPrograms());
    return HyperGlassRenderer._(p[0], p[1], p[2], p[3], p[4], p[5]);
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
    ]) {
      final clock = Stopwatch()..start();
      p.add(await ui.FragmentProgram.fromAsset('$_assetPrefix$asset'));
      _log('载入 $asset：${clock.elapsedMilliseconds} ms');
    }
    await HyperGlassRenderer._(p[0], p[1], p[2], p[3], p[4], p[5])._warmUp();
    return p;
  }

  /// Timing lines go through [debugPrint] (Flutify mirrors it into its log file).
  static void _log(String message) => debugPrint('[hyper_glass] $message');

  Future<void> _warmUp() async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 128, 128), ui.Paint()..color = const ui.Color(0xff3070c0));
    final pic = rec.endRecording();
    final src = pic.toImageSync(128, 128);
    pic.dispose();
    const g = GlassFilter();
    // Each stage is read back before the next one starts, so its time is the first GPU compile of
    // the programs it uses (plus a tiny 128 px render).
    Future<T> stage<T>(String name, T Function() run, ui.Image Function(T) image) async {
      final clock = Stopwatch()..start();
      final result = run();
      await image(result).toByteData();
      _log('预热 $name：${clock.elapsedMilliseconds} ms');
      return result;
    }

    // Skia (Windows / Linux) with a fusable filter draws the glass straight from the backdrop and blurs
    // menus with Skia's own blur, so the LM down / blur / upsample programs are never used there:
    // warming them only adds GPU compile time. They still compile lazily if a non-fused glass shows up.
    final fused = !ui.ImageFilter.isShaderFilterSupported && fusedRefractKernel(g) != null;
    final lm = fused ? null : await stage('LM 模糊（下采样 / 模糊 / 上采样）', () => lmGaussianBlur(src, 60), (i) => i);
    final refract = fused ? null : await stage('折射纹理（上采样着色）', () => refractTexture(src, g), (r) => r.rgb);
    final glass = await stage(
      fused ? '融合玻璃（SDF + MiGlassV13）' : '玻璃（SDF + MiGlassV13）',
      () => fused ? _drawShader(fusedGlassShader(g, src, ui.Offset.zero, 96, 96, 24)!, 96, 96) : drawGlass(g, refract!, ui.Offset.zero, 96, 96, 24),
      (i) => i,
    );
    final blurred = await stage('高斯模糊', () => gaussianBlur(src, 20), (i) => i);
    final blend = await stage(
      '混色模糊',
      () => drawBlend(BlendMaterial.popupMenuLight, blurred, const ui.Size(128, 128), ui.Offset.zero, 64, 64, 16),
      (i) => i,
    );
    for (final i in [src, lm, refract?.rgb, refract?.a, glass, blurred, blend]) {
      i?.dispose();
    }
    dispose();
  }

  /// Draws [s] over a [w]x[h] rect with the default (srcOver) blend, as the fused glass is drawn on
  /// screen, so warm-up compiles the same pipeline.
  static ui.Image _drawShader(ui.FragmentShader s, int w, int h) {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..shader = s);
    final pic = rec.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    s.dispose();
    return img;
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
    s.dispose();
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
        t.dispose();
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
    by.dispose();
    for (final t in temps) {
      t.dispose();
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
    if (!identical(reflect, base) && !identical(reflect, backdrop)) reflect.dispose();
    if (!identical(base, backdrop)) base.dispose();
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
  }) => _pass(_glassShader(g, origin, w, h, shapeRadius, opacity, refract: refract), w, h);

  final _kernels = <GlassFilter, ({double k0, List<double> k, int radius})?>{};

  /// The glass as a shader that reads the plain [backdrop] (no refract texture chain): reflect blur,
  /// tint blur and the tinting upsample run inside the glass shader (see tools/to_flutter.py,
  /// FUSED_REFRACT). Draw it over a [w]x[h] rect whose local units are physical pixels. Null when [g]
  /// cannot be fused; use [refractTexture] + [drawGlass] then.
  ui.FragmentShader? fusedGlassShader(
    GlassFilter g,
    ui.Image backdrop,
    ui.Offset origin,
    int w,
    int h,
    double shapeRadius, {
    double opacity = 1.0,
    double backdropScale = 1.0,
  }) {
    final kernel = _kernels.putIfAbsent(g, () => fusedRefractKernel(g));
    if (kernel == null) return null;
    return _glassShader(
      g,
      origin,
      w,
      h,
      shapeRadius,
      opacity,
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
    double opacity, {
    RefractTexture? refract,
    ui.Image? backdrop,
    ({double k0, List<double> k, int radius})? kernel,
    double backdropScale = 1.0,
  }) {
    final fw = w.toDouble(), fh = h.toDouble();
    final half = math.min(fw, fh) * 0.5;
    var radius = g.cornerRadius > 0 ? g.cornerRadius : shapeRadius;
    radius = math.min(math.min(radius, half.floorToDouble()), 502.0);
    final edge = math.min(math.min(g.edgePx, half), 502.0);
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
    s.setFloat(_Gl.uShapeThicknessPx, g.thicknessPx);
    s.setFloat(_Gl.uShapeReflectOffsetPx, g.reflectOffsetPx);
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
    s.setFloat(_Gl.uHit__f, 0);
    s.setFloat(_Gl.uUnshade, g.unshade);
    _vec(s, _Gl.uRotationTrig, [1, 0]);
    s.setFloat(_Gl.uIconMove__f, 0);
    s.setFloat(_Gl.uHasRotation__f, 0);
    s.setFloat(_Gl.uUsePowGate__f, (g.colorPow - 1.0).abs() > 0.001 ? 1 : 0);
    s.setFloat(_Gl.colorSpaceConvertMode__f, 0);
    s.setFloat(_Gl.fl_sdf_range, sdf.range);
    s.setImageSampler(_Gl.sampler_uSdfTex, sdf.a);
    s.setImageSampler(_Gl.sampler_uMaskTex, sdf.a);
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
  }) => _pass(blendShader(m, blurred, backdropSize, origin, w, h, radius, opacity: opacity), w, h);

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
  }) {
    final s = _blend.fragmentShader();
    var i = 0;
    void f(double v) => s.setFloat(i++, v);
    f(w.toDouble());
    f(h.toDouble());
    f(origin.dx);
    f(origin.dy);
    f(1 / backdropSize.width);
    f(1 / backdropSize.height);
    f(radius);
    f(math.min(3, m.layers.length).toDouble());
    for (var k = 0; k < 3; k++) {
      final c = k < m.layers.length ? m.layers[k].color : const ui.Color(0x00000000);
      f(c.r);
      f(c.g);
      f(c.b);
      f(c.a);
    }
    for (var k = 0; k < 3; k++) {
      f(k < m.layers.length ? m.layers[k].mode.index.toDouble() : 0);
    }
    f(opacity);
    s.setImageSampler(0, blurred);
    return s;
  }

  void dispose() {
    for (final i in _sdfCache.values) {
      i.a.dispose();
      i.b.dispose();
    }
    _sdfCache.clear();
  }
}
