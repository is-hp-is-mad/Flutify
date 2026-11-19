import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 艺人主页与艺人信息页配色，复刻 Apple Music Android 7.0（`la.C5366a` / `m7.c` / `m7.d` / `utils.F`）。
///
/// 与专辑页的双明暗 OKLCH 方案不同，Apple Music 7.0 艺人页固定以沉浸深色为基底
/// （`ArtistFragment.isDarkTheme() == true`），对原图取出的底色按相对亮度做非线性压暗：
/// - `lum <= 0.1`：保留原色；
/// - `lum > 0.1`：`F.l(lum * 0.6, color, black)`，即每个归一化 RGB 通道减去 `lum * 0.6` 并截断到 0，
///   既压住高光保证白字可读，又保留原图的色相与灰阶质感（如黑白棚拍照落到暖中灰，暗紫舞台照保持深梅紫）；
/// - 次级文字、分隔线与填充色通过 `F.a(adjustedBg, rawColor, isDark: true)` 做线性加色混合，
///   让灰字与细线自然带上一点艺人底色倾向。
@immutable
class ArtistArtworkScheme {
  /// `m7.c.a.b` 的深浅分界亮度。
  static const double darkLuminanceThreshold = 0.43;

  /// `la.C5366a` 开始压暗底色的亮度阈值。
  static const double adjustLuminanceThreshold = 0.10;

  /// `q8.T1.f71325a`：头图底部 20 段颜色渐变的缓动曲线。
  static const Curve heroGradientCurve = Cubic(0.49, 0.0, 0.65, 1.0);

  /// 尚未取出图片颜色时的默认原色（对应深灰底）。
  static const Color defaultSourceColor = Color(0xFF23232B);

  /// 原图主色 / 接口 `bgColor`（未压暗）。
  final Color sourceColor;

  /// 压暗后的整页背景色（`adjustedBgColor`）。
  final Color backgroundColor;

  /// 页面内容是否为深色底（白字）。经 `fromArtistArtwork` 压暗后恒为 `true`。
  final bool isDark;

  /// 未压暗的原图底色是否偏亮（用于在浅色棚拍头图顶部切换深色玻璃图标）。
  final bool sourceIsLight;

  final Color labelColor;
  final Color secondaryLabelColor;
  final Color tertiaryLabelColor;
  final Color tertiaryFillColor;
  final Color quaternaryFillColor;
  final Color dividerColor;
  final Color spotlightCardColor;
  final Color spotlightBorderColor;

  const ArtistArtworkScheme({
    required this.sourceColor,
    required this.backgroundColor,
    required this.isDark,
    required this.sourceIsLight,
    required this.labelColor,
    required this.secondaryLabelColor,
    required this.tertiaryLabelColor,
    required this.tertiaryFillColor,
    required this.quaternaryFillColor,
    required this.dividerColor,
    required this.spotlightCardColor,
    required this.spotlightBorderColor,
  });

  /// 默认配色（无图或加载完成前）。
  static final ArtistArtworkScheme fallback = ArtistArtworkScheme.from(
    defaultSourceColor,
  );

  /// 开启「增加对比度」时的纯深色高对比回退方案。
  static const ArtistArtworkScheme highContrast = ArtistArtworkScheme(
    sourceColor: Color(0xFF121216),
    backgroundColor: Color(0xFF121216),
    isDark: true,
    sourceIsLight: false,
    labelColor: Color(0xFFFFFFFF),
    secondaryLabelColor: Color(0xCCEBEBF5),
    tertiaryLabelColor: Color(0x7AEBEBF5),
    tertiaryFillColor: Color(0x47767680),
    quaternaryFillColor: Color(0x33747480),
    dividerColor: Color(0x38FFFFFF),
    spotlightCardColor: Color(0xFF1E1E24),
    spotlightBorderColor: Color(0x29FFFFFF),
  );

  /// 复刻 `la.C5366a.C0771a.a`（`fromArtistArtwork`）。
  factory ArtistArtworkScheme.from(Color source) {
    final opaque = Color.fromARGB(
      255,
      _channel8(source.r),
      _channel8(source.g),
      _channel8(source.b),
    );
    final lum = appleLuminance(opaque);
    final adjustedBg = lum <= adjustLuminanceThreshold
        ? opaque
        : mixChannel(lum * 0.6, opaque, const Color(0xFF000000));
    final isDark = appleLuminance(adjustedBg) < darkLuminanceThreshold;

    // Ra.A / ac.i：Apple Music 7.0 的 ArtworkContentColors 原始表
    final rawLabel = isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    final rawSecondaryLabel = isDark
        ? const Color(0x99EBEBF5)
        : const Color(0x993C3C43);
    final rawTertiaryLabel = isDark
        ? const Color(0x4DEBEBF5)
        : const Color(0x4D3C3C43);
    final rawTertiaryFill = isDark
        ? const Color(0x3D767680)
        : const Color(0x1F767680);
    final rawQuaternaryFill = isDark
        ? const Color(0x2E747480)
        : const Color(0x14747480);
    final rawDivider = isDark
        ? const Color(0x2EFFFFFF)
        : const Color(0x29000000);

    return ArtistArtworkScheme(
      sourceColor: opaque,
      backgroundColor: adjustedBg,
      isDark: isDark,
      sourceIsLight: lum >= darkLuminanceThreshold,
      labelColor: blendContentColor(adjustedBg, rawLabel, isDark: isDark),
      secondaryLabelColor: blendContentColor(
        adjustedBg,
        rawSecondaryLabel,
        isDark: isDark,
      ),
      tertiaryLabelColor: blendContentColor(
        adjustedBg,
        rawTertiaryLabel,
        isDark: isDark,
      ),
      tertiaryFillColor: blendContentColor(
        adjustedBg,
        rawTertiaryFill,
        isDark: isDark,
      ),
      quaternaryFillColor: blendContentColor(
        adjustedBg,
        rawQuaternaryFill,
        isDark: isDark,
      ),
      dividerColor: blendContentColor(adjustedBg, rawDivider, isDark: isDark),
      spotlightCardColor: spotlightFill(adjustedBg),
      spotlightBorderColor: const Color(0x1FFFFFFF),
    );
  }

  /// 解析 Apple Music 接口里的十六进制颜色（如 `"6b6968"`、`"#1f0f2b"`、`"ff1f0f2b"`）。
  static Color? parseHexColor(String? raw) {
    if (raw == null) return null;
    var hex = raw.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      return value == null ? null : Color(0xFF000000 | value);
    }
    if (hex.length == 8) {
      final value = int.tryParse(hex, radix: 16);
      return value == null ? null : Color(value);
    }
    return null;
  }

  /// 复刻 `utils.F.b`：sRGB 逆伽马后按 `0.2224952 R + 0.71689504 G + 0.060609758 B` 加权。
  static double appleLuminance(Color color) {
    final r = _linear(_channel8(color.r));
    final g = _linear(_channel8(color.g));
    final b = _linear(_channel8(color.b));
    return b * 0.060609758 + g * 0.71689504 + r * 0.2224952;
  }

  /// 复刻 `utils.F.l(t, base, target)`：
  /// 每通道 `round(max(0, base + target * t - t) * 255)`。当 `target` 为纯黑时等价于每通道减去 `t`。
  static Color mixChannel(double t, Color base, Color target) {
    int ch(double b, double dst) {
      final fb = _channel8(b) / 255.0;
      final fd = _channel8(dst) / 255.0;
      final next = math.max(0.0, (fb + fd * t) - t) * 255.0;
      return next.round().clamp(0, 255);
    }

    return Color.fromARGB(
      _channel8(base.a),
      ch(base.r, target.r),
      ch(base.g, target.g),
      ch(base.b, target.b),
    );
  }

  /// 复刻 `utils.F.a(bg, fg, isDark)`：深色底做线性加色混合，浅色底退回 [mixChannel]。
  static Color blendContentColor(
    Color bg,
    Color fg, {
    required bool isDark,
  }) {
    final alpha = _channel8(fg.a) / 255.0;
    if (!isDark) return mixChannel(alpha, bg, fg);

    int add(double bgCh, double fgCh) {
      final fb = _channel8(bgCh) / 255.0;
      final ff = _channel8(fgCh) / 255.0;
      return (math.min(1.0, fb + ff * alpha) * 255.0).truncate().clamp(0, 255);
    }

    return Color.fromARGB(
      _channel8(bg.a),
      add(bg.r, fg.r),
      add(bg.g, fg.g),
      add(bg.b, fg.b),
    );
  }

  /// 复刻 `Ub.C2563h`（最新发行 Spotlight 卡片底色）：叠一层微白提亮后将 HSV 饱和度压到 0.4×。
  static Color spotlightFill(Color background) {
    final lifted = Color.alphaBlend(const Color(0x14FFFFFF), background);
    final hsv = HSVColor.fromColor(lifted);
    return hsv.withSaturation((hsv.saturation * 0.4).clamp(0.0, 1.0)).toColor();
  }

  /// 复刻 `q8.T1.d` + `la.C5429v0.j`：从全透明过渡到 [backgroundColor] 的 20 段非线性渐变色。
  List<Color> get heroGradientColors => List<Color>.generate(20, (i) {
    final eased = heroGradientCurve.transform(i / 19.0);
    return backgroundColor.withValues(alpha: eased.clamp(0.0, 1.0));
  }, growable: false);

  /// 与 [heroGradientColors] 对应的 20 个均匀锚点。
  static final List<double> heroGradientStops = List<double>.generate(
    20,
    (i) => i / 19.0,
    growable: false,
  );

  /// 艺人页局部主题：整页固定深色表面 + 取色背景，曲目行、分区标题与卡片自动继承。
  ThemeData toThemeData(ThemeData base) {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: base.colorScheme.primary,
      brightness: Brightness.dark,
    );
    final scheme = baseScheme.copyWith(
      primary: base.colorScheme.primary,
      onPrimary: base.colorScheme.onPrimary,
      surface: backgroundColor,
      onSurface: labelColor,
      onSurfaceVariant: secondaryLabelColor,
      outline: dividerColor,
      outlineVariant: dividerColor,
      surfaceContainerLow: quaternaryFillColor,
      surfaceContainer: quaternaryFillColor,
      surfaceContainerHigh: tertiaryFillColor,
      surfaceContainerHighest: tertiaryFillColor,
    );
    return base.copyWith(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundColor,
      canvasColor: backgroundColor,
      colorScheme: scheme,
      dividerColor: dividerColor,
      dividerTheme: base.dividerTheme.copyWith(color: dividerColor),
      iconTheme: base.iconTheme.copyWith(color: labelColor),
      textTheme: base.textTheme.apply(
        bodyColor: labelColor,
        displayColor: labelColor,
      ),
    );
  }
}

int _channel8(double channel) => (channel * 255.0).round().clamp(0, 255);

double _linear(int channel8) {
  final f = channel8 / 255.0;
  return f <= 0.04045
      ? f / 12.92
      : math.pow((f + 0.055) / 1.055, 2.4).toDouble();
}
