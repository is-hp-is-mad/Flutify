import 'package:flutter/material.dart';

/// 强调色的派生规则：任何用户自选或封面取出的颜色，都要在深浅两种背景上保持可读。
class AccentColors {
  AccentColors._();

  /// WCAG 对比度。
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 强调色填充（按钮 / 药丸）上的前景色：亮色配黑，暗色配白。
  static Color onAccent(Color accent) => accent.computeLuminance() > 0.3 ? Colors.black : Colors.white;

  /// 作为文字 / 图标时的强调色：逐步调整明度，直到与 [background] 的对比度 ≥ [minContrast]。
  /// 浅色背景上变深（如 Spotify 绿 → 深绿），深色背景上变亮。
  static Color readableOn(Color accent, Color background, {double minContrast = 3.0}) {
    if (contrast(accent, background) >= minContrast) return accent;
    final darken = background.computeLuminance() > 0.5;
    var hsl = HSLColor.fromColor(accent);
    for (var i = 0; i < 20; i++) {
      final l = (hsl.lightness + (darken ? -0.03 : 0.03)).clamp(0.0, 1.0);
      hsl = hsl.withLightness(l);
      final c = hsl.toColor();
      if (contrast(c, background) >= minContrast) return c;
    }
    return hsl.toColor();
  }

  /// 把封面主色（通常偏暗、偏灰）提亮为适合做强调色的鲜明颜色；接近灰色的封面保持中性。
  static Color vivid(Color artwork) {
    final hsl = HSLColor.fromColor(artwork);
    if (hsl.saturation < 0.12) return hsl.withSaturation(0.08).withLightness(0.78).toColor();
    return hsl.withSaturation(hsl.saturation.clamp(0.55, 0.85)).withLightness(0.6).toColor();
  }
}
