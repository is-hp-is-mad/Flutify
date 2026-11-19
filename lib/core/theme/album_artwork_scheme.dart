import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 专辑页封面配色，按 Apple Music Android 7.0.0 的调整来。
///
/// 官方在 `p260m7/f.java` 把 artwork `bgColor` 转成 OKLCH
/// （`com.apple.android.music.utils.F` 的 `m` / `k`），再压色度、限制明度。
/// Spotify 没有服务端颜色字段，这里的输入是本地聚类得到的主色，调色系数与官方一致。
@immutable
class AlbumArtworkScheme {
  /// 相对亮度低于此值视为深色封面，前景用白色。
  static const darkLuminance = 0.43;

  final bool isDark;
  final Color lightBackground;
  final Color darkBackground;
  final Color foreground;

  const AlbumArtworkScheme({
    required this.isDark,
    required this.lightBackground,
    required this.darkBackground,
    required this.foreground,
  });

  factory AlbumArtworkScheme.from(Color source) {
    final isDark = _luminance(source) < darkLuminance;
    final light = _lightBackground(source, isDark);
    final dark = _darkBackground(source);
    return AlbumArtworkScheme(
      isDark: isDark,
      lightBackground: light,
      darkBackground: dark,
      foreground: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
    );
  }

  /// 深色主题用压暗后的封面色，浅色主题用另一档，两档都从同一张封面来。
  Color forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? darkBackground : lightBackground;

  /// 页面文字颜色：按实际铺上的底色选白或黑，取对比度更高的一个。
  ///
  /// [foreground] 只看封面原色；同一张浅色封面在深色主题下会被压暗，
  /// 那时必须换成白字，所以页面上用这个。
  Color foregroundFor(Brightness brightness) =>
      onColor(forBrightness(brightness));

  /// [background] 上白字与黑字的 WCAG 对比度，取更高的那个。
  static Color onColor(Color background) {
    final l = background.computeLuminance();
    final whiteContrast = 1.05 / (l + 0.05);
    final blackContrast = (l + 0.05) / 0.05;
    return whiteContrast >= blackContrast
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
  }

  /// 非首块区域：每个通道减去 0.04 后截断，对应官方 `F.l(0.04, color, black)`。
  Color sectionBackground(Color page) => mixTowardBlack(page);

  static Color mixTowardBlack(Color page) {
    int channel(double value) {
      final next = math.max(0.0, value - 0.04);
      return (next * 255).truncate().clamp(0, 255);
    }

    return Color.fromARGB(
      255,
      channel(page.r),
      channel(page.g),
      channel(page.b),
    );
  }
}

/// OKLCH 明度。测试用来核对 0.18 下限和 0.30 封顶。
@visibleForTesting
double albumOklchLightness(Color color) => _toOklch(color).l;

/// OKLCH 色度。测试用来核对深色主题 0.125 封顶。
@visibleForTesting
double albumOklchChroma(Color color) => _toOklch(color).c;

final class _Oklch {
  final double l;
  final double c;
  final double h;

  const _Oklch(this.l, this.c, this.h);

  _Oklch copyWith({double? l, double? c}) =>
      _Oklch(l ?? this.l, c ?? this.c, h);
}

double _linear(double channel) => channel <= 0.04045
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

/// 官方 `D.b`：线性 RGB 的加权和，系数与 WCAG 略有差别。
double _luminance(Color color) =>
    _linear(color.b) * 0.060609758 +
    _linear(color.g) * 0.71689504 +
    _linear(color.r) * 0.2224952;

double _cbrt(double value) => value >= 0
    ? math.pow(value, 0.33333334).toDouble()
    : -math.pow(-value, 0.33333334).toDouble();

_Oklch _toOklch(Color color) {
  final r = _linear(color.r);
  final g = _linear(color.g);
  final b = _linear(color.b);
  final lmsL = 0.41222146 * r + 0.53633255 * g + 0.051445995 * b;
  final lmsM = 0.2119035 * r + 0.6806995 * g + 0.10739696 * b;
  final lmsS = 0.08830246 * r + 0.28171885 * g + 0.6299787 * b;
  final l_ = _cbrt(lmsL);
  final m_ = _cbrt(lmsM);
  final s_ = _cbrt(lmsS);
  final lightness = 0.21045426 * l_ + 0.7936178 * m_ - 0.004072047 * s_;
  final a = 1.9779985 * l_ - 2.4285922 * m_ + 0.4505937 * s_;
  final b2 = 0.025904037 * l_ + 0.78277177 * m_ - 0.80867577 * s_;
  var hue = math.atan2(b2, a) * 180.0 / 3.1415927;
  if (hue < 0) hue += 360;
  return _Oklch(lightness, math.sqrt(a * a + b2 * b2), hue);
}

Color _fromOklch(_Oklch oklch) {
  final hue = oklch.h * 3.1415927 / 180.0;
  final cos = oklch.c * math.cos(hue);
  final sin = oklch.c * math.sin(hue);
  final l_ = oklch.l + 0.39633778 * cos + 0.21580376 * sin;
  final m_ = oklch.l - 0.105561346 * cos - 0.06385417 * sin;
  final s_ = oklch.l - 0.08948418 * cos - 1.2914855 * sin;
  final l3 = l_ * l_ * l_;
  final m3 = m_ * m_ * m_;
  final s3 = s_ * s_ * s_;

  double encode(double linear) {
    final encoded = linear <= 0.0031308
        ? linear * 12.92
        : math.pow(linear, 0.41666666).toDouble() * 1.055 - 0.055;
    return encoded.clamp(0.0, 1.0);
  }

  int channel(double linear) => (encode(linear) * 255).round().clamp(0, 255);
  return Color.fromARGB(
    255,
    channel(4.0767417 * l3 - 3.3077116 * m3 + 0.23096994 * s3),
    channel(-1.268438 * l3 + 2.6097574 * m3 - 0.34131938 * s3),
    channel(-0.0041960864 * l3 - 0.7034186 * m3 + 1.7076147 * s3),
  );
}

Color _subtractTowardBlack(Color color, double amount) {
  int channel(double value) {
    final next = math.max(0.0, value - amount);
    return (next * 255).truncate().clamp(0, 255);
  }

  return Color.fromARGB(
    255,
    channel(color.r),
    channel(color.g),
    channel(color.b),
  );
}

Color _lightBackground(Color source, bool isDark) {
  var oklch = _toOklch(source);
  if (oklch.c > 0.13) {
    oklch = oklch.copyWith(
      l: oklch.l / (0.11 * oklch.l + 1),
      c: oklch.c / (0.9 * oklch.c + 1),
    );
  }
  if (oklch.l < 0.18) oklch = oklch.copyWith(l: 0.18);
  var color = _fromOklch(oklch);
  final luminance = _luminance(color);
  if (luminance > 0.15 && isDark) {
    color = _subtractTowardBlack(color, luminance * 0.25);
  }
  return color;
}

Color _darkBackground(Color source) {
  var oklch = _toOklch(source);
  // Apple Music 7.0 先抬极暗色，再限制亮色和高色度，避免背景塌成纯黑。
  if (oklch.l < 0.18) oklch = oklch.copyWith(l: 0.18);
  return _fromOklch(
    oklch.copyWith(l: math.min(oklch.l, 0.3), c: math.min(oklch.c, 0.125)),
  );
}
