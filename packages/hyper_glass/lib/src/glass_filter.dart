import 'dart:math' as math;

/// Arguments of the engine's `ImageFilter::initGlassV7` (p2..p34).
///
/// Defaults are the values MIUIWeather's card passes (libapp.so `_Rhb` -> `ImageFilter.glass`
/// -> FFI stub 0x9bfe60). Lengths are physical pixels, as in the engine.
class GlassFilter {
  const GlassFilter({
    this.baseBlur = 4.0,
    this.refractBlur = 1.0,
    this.cornerRadius = 0.0,
    this.blurSourceMode = -1,
    this.edgePx = 20.0,
    this.edgePow = 1.6,
    this.thicknessPx = 98.22090569138527,
    this.reflectOffsetPx = 110.0,
    this.lightDir = const [-0.5, 0.5, -0.1],
    this.lightIntensity = 1.2,
    this.lightOpposite = 0.8,
    this.lightAngleRange = 0.3,
    this.darker = 0.2,
    this.darkerRange = const [0.6, 0.9],
    this.refractIOR = 1.4,
    this.reflectionLighten = 1.0,
    this.reflectionStrength = 1.4,
    this.lightEdgePow = 1.0,
    this.innerColorMix = 0.5,
    this.bgColorSaturation = 1.5,
    this.glassColor = const [1.0, 1.0, 1.0, 0.05],
    this.bgColorBrightness = 0.08,
    this.innerColorWhite = 0.3,
    this.luminanceBezier = const [0.5, 1.0, 0.8, 1.2],
    this.innerBottom = 0.01,
    this.luminanceAmount = 0.24,
    this.saturation = 1.6,
    this.brightness = 0.14,
    this.colorPow = 1.5,
    this.alpha = 1.0,
    this.burn = 11.0,
    this.unshade = 0.0,
  });

  final double baseBlur; // p2  reflect / tint LM blur radius
  final double refractBlur; // p3  base LM blur radius
  final double cornerRadius; // p4  (<= 0: the shape's radius)
  final int blurSourceMode; // p5  (Dart passes -1)
  final double edgePx; // p7
  final double edgePow; // p8
  final double thicknessPx; // p9
  final double reflectOffsetPx; // p10
  final List<double> lightDir; // p11
  final double lightIntensity; // p12
  final double lightOpposite; // p13
  final double lightAngleRange; // p14
  final double darker; // p15
  final List<double> darkerRange; // p16
  final double refractIOR; // p17
  final double reflectionLighten; // p18
  final double reflectionStrength; // p19
  final double lightEdgePow; // p20
  final double innerColorMix; // p21
  final double bgColorSaturation; // p22
  final List<double> glassColor; // p23
  final double bgColorBrightness; // p24
  final double innerColorWhite; // p25
  final List<double> luminanceBezier; // p26
  final double innerBottom; // p27
  final double luminanceAmount; // p28
  final double saturation; // p29
  final double brightness; // p30
  final double colorPow; // p31
  final double alpha; // p32
  final double burn; // p33
  final double unshade; // p34
}

/// `MiLMGaussianState` as computed by `MiHyperMaterialEngine::ExecuteLMGaussianBlur` (0xd6e014).
class LMGaussianState {
  LMGaussianState._(this.sigma, this.variance, this.factor, this.level, this.count, this.weight, this.offset);

  final double sigma, variance;
  final int factor, level, count;
  final List<double> weight; // [center, pair1..pair6] -> blur_weight
  final List<double> offset; // matching sample offsets -> blur_offset

  factory LMGaussianState.forRadius(double radius) {
    final r = radius <= 400.0 ? radius : 400.0;
    final sigma = r * 0.25 * 0.45;
    final v0 = sigma * sigma;

    final a = v0 * 0.015625 + -0.140625;
    final f25 = 400.0 < v0 ? a : v0;
    var level = f25 < 90.25 ? 0 : 2;
    var f55 = f25 < 90.25 ? v0 : f25 * 0.0625 + -0.47265625;
    if (400.0 < v0) {
      level = 3;
      f55 = a;
    }
    final threshold = v0 <= 100.0 ? 12.6 : 30.25;
    if (threshold <= f55) {
      level += 1;
      f55 = f55 * 0.25 + -0.756625;
    }
    final variance = 0.1 <= f55 ? f55 : 0.1;
    final factor = 1 << level;

    // exponents -k^2/2, pi = 3.141592655 (engine constants)
    final norm = 1.0 / math.sqrt(variance * 3.141592655 + variance * 3.141592655);
    final w = List<double>.generate(14, (k) => math.exp(-(k * k) * 0.5 / variance) * norm);
    var sum = w[0];
    for (var k = 1; k < 14; k++) {
      sum += 2 * w[k];
    }
    for (var k = 0; k < 14; k++) {
      w[k] /= sum;
    }

    final weight = List<double>.filled(7, 0), offset = List<double>.filled(7, 0);
    var pairSum = 0.0;
    var count = 0;
    for (var i = 0; i < 6; i++) {
      final lo = 2 + 2 * i, hi = lo + 1;
      final ws = w[lo] + w[hi];
      final keep = 0.002 <= ws;
      final pw = keep ? ws : 0.0;
      pairSum += pw;
      offset[i + 1] = keep ? w[hi] / ws + lo : 0.0;
      weight[i + 1] = (pw > 0 && pw < 1) ? pw : 0.0;
      if (pw > 0 && pw < 1) count++;
    }
    offset[0] = w[1] / (w[0] * 0.5 + w[1]);
    final center = 0.5 - pairSum;
    if (center > 0 && center < 1) {
      weight[0] = center;
      count++;
    }
    return LMGaussianState._(sigma, variance, factor, level, count, weight, offset);
  }
}

extension LMGaussianKernel on LMGaussianState {
  /// The 1-D discrete kernel (taps -6..6) one `MiLmBlur` pass applies at factor 1: the blur shader
  /// samples the first [count] (offset, weight) taps at +offset and -offset with bilinear filtering.
  List<double> discreteKernel() {
    final k = List<double>.filled(13, 0);
    for (var i = 0; i < count; i++) {
      for (final o in [offset[i], -offset[i]]) {
        final lo = o.floor(), f = o - lo;
        if (lo >= -6 && lo <= 6) k[lo + 6] += weight[i] * (1 - f);
        if (lo + 1 >= -6 && lo + 1 <= 6) k[lo + 7] += weight[i] * f;
      }
    }
    return k;
  }
}

/// Taps 0..4 of the separable kernel equal to AcquireGlassBlurTextures' reflect blur followed by the
/// tint blur (both [GlassFilter.baseBlur]), plus its half-width. For half-width 1, `k[0]` holds the
/// bilinear tap offset instead (see the shader's fast path). Null when the glass cannot be fused
/// (a blur needs downsampling, the base blur is not a near-identity, or the kernel is wider than 4).
({double k0, List<double> k, int radius})? fusedRefractKernel(GlassFilter g) {
  final base = LMGaussianState.forRadius(g.refractBlur);
  final blur = LMGaussianState.forRadius(g.baseBlur);
  if (base.factor != 1 || base.variance > 0.1 || blur.factor != 1) return null;
  final identity = List<double>.generate(13, (i) => i == 6 ? 1.0 : 0.0);
  final reflect = g.blurSourceMode == g.refractBlur.toInt() ? identity : blur.discreteKernel();
  final tint = blur.discreteKernel();
  final c = List<double>.filled(25, 0); // taps -12..12
  for (var a = 0; a < 13; a++) {
    for (var b = 0; b < 13; b++) {
      c[a + b] += reflect[a] * tint[b];
    }
  }
  // Taps under 1% of the total are dropped and the rest renormalised (for the app's filter only the
  // outer pair, 0.5% each, goes), which usually leaves a 3-tap kernel the shader evaluates as 4
  // bilinear samples instead of a 5x5 loop.
  var radius = 0;
  for (var d = 1; d <= 12; d++) {
    if (c[12 + d] >= 0.01) radius = d;
  }
  if (radius > 4) return null;
  var sum = c[12];
  for (var d = 1; d <= radius; d++) {
    sum += 2 * c[12 + d];
  }
  final k0 = c[12] / sum;
  final k = [for (var d = 1; d <= 4; d++) d <= radius ? c[12 + d] / sum : 0.0];
  if (radius <= 1) {
    // [k1 k0 k1] = two half-weight bilinear taps at +-d (see FUSED_REFRACT); radius 1 marks this mode
    final half = k0 / 2 + k[0];
    return (k0: k0, k: [k[0] / half, 0.0, 0.0, 0.0], radius: 1);
  }
  return (k0: k0, k: k, radius: radius);
}
