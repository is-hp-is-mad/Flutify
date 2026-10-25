import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../models/appearance.dart';
import 'accent_colors.dart';
import 'md3e_shapes.dart';

/// 「已点赞的歌曲」封面渐变：全应用（侧栏、音乐库、详情页、备份页）统一使用这一份。
const LinearGradient kLikedSongsGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF450AF5), Color(0xFF8E8EE5), Color(0xFFC4EFD9)],
);

/// 「已点赞的歌曲」详情页取色兜底（与渐变主色同色系）。
const Color kLikedSongsTint = Color(0xFF4A2FB8);

/// 主题之外的外观令牌（ThemeExtension）：强调色填充、液态玻璃参数、圆角缩放。
///
/// 组件通过 `context.tokens` 读取；随主题一起变化，所以用户在设置页调整后所有页面即时生效。
@immutable
class FlutifyTokens extends ThemeExtension<FlutifyTokens> {
  /// 强调色填充（大播放键、选中药丸、悬停播放键）。
  final Color accent;

  /// 强调色填充上的前景（图标 / 文字）。
  final Color onAccent;

  /// 液态玻璃的背景模糊半径（sigma）。
  final double glassSigma;

  /// 液态玻璃的白色填充不透明度。
  final double glassTint;

  /// 用户选择的玻璃不透明度（0~1），供毛玻璃导航等自行换算底色。
  final double glassOpacity;

  /// 圆角缩放倍数（见 [CornerStyle]）。
  final double cornerScale;

  /// 方正风格：胶囊形状也改为小圆角矩形。
  final bool squareCorners;

  /// 省电模式（见 [AppearanceSettings.powerSaving]）。
  final bool powerSaving;

  /// 材质选了「柔光玻璃（Beta）」：玻璃表面、菜单、弹窗改用 HyperOS 材质。
  final bool hyperMaterial;

  const FlutifyTokens({
    required this.accent,
    required this.onAccent,
    required this.glassSigma,
    required this.glassTint,
    required this.glassOpacity,
    required this.cornerScale,
    required this.squareCorners,
    this.powerSaving = false,
    this.hyperMaterial = false,
  });

  /// 由外观设置与本次主题实际使用的强调色生成。
  factory FlutifyTokens.from(AppearanceSettings s, Color accent) {
    return FlutifyTokens(
      accent: accent,
      onAccent: AccentColors.onAccent(accent),
      glassSigma: sigmaFor(s.glassBlur),
      glassTint: tintFor(s.glassOpacity),
      glassOpacity: s.glassOpacity,
      cornerScale: s.cornerStyle.scale,
      squareCorners: s.cornerStyle == CornerStyle.square,
      powerSaving: s.powerSaving,
      hyperMaterial: s.glassMaterial == GlassMaterial.hyper,
    );
  }

  /// 模糊强度（0~1）→ 模糊半径 sigma；设置页拖动滑杆时的本地预览也用它。
  static double sigmaFor(double glassBlur) => lerpDouble(6, 48, glassBlur)!;

  /// 不透明度（0~1）→ 玻璃白色填充的 alpha。
  static double tintFor(double glassOpacity) => 0.015 + 0.12 * glassOpacity;

  static final FlutifyTokens fallback = FlutifyTokens.from(AppearanceSettings.defaults, AccentPreset.spotify.color);

  static FlutifyTokens of(BuildContext context) => Theme.of(context).extension<FlutifyTokens>() ?? fallback;

  /// 按风格缩放后的圆角半径。
  double corner(double base) => base * cornerScale;

  BorderRadius radius(double base) => BorderRadius.circular(corner(base));

  /// 胶囊圆角（方正风格下为 10px 圆角）。
  BorderRadius get pill => squareCorners ? BorderRadius.circular(10) : MD3EShapes.pill;

  OutlinedBorder get pillShape =>
      squareCorners ? RoundedRectangleBorder(borderRadius: pill) : const StadiumBorder();

  @override
  FlutifyTokens copyWith({
    Color? accent,
    Color? onAccent,
    double? glassSigma,
    double? glassTint,
    double? glassOpacity,
    double? cornerScale,
    bool? squareCorners,
    bool? powerSaving,
    bool? hyperMaterial,
  }) {
    return FlutifyTokens(
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      glassSigma: glassSigma ?? this.glassSigma,
      glassTint: glassTint ?? this.glassTint,
      glassOpacity: glassOpacity ?? this.glassOpacity,
      cornerScale: cornerScale ?? this.cornerScale,
      squareCorners: squareCorners ?? this.squareCorners,
      powerSaving: powerSaving ?? this.powerSaving,
      hyperMaterial: hyperMaterial ?? this.hyperMaterial,
    );
  }

  @override
  FlutifyTokens lerp(FlutifyTokens? other, double t) {
    if (other == null) return this;
    return FlutifyTokens(
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: t < 0.5 ? onAccent : other.onAccent,
      glassSigma: lerpDouble(glassSigma, other.glassSigma, t)!,
      glassTint: lerpDouble(glassTint, other.glassTint, t)!,
      glassOpacity: lerpDouble(glassOpacity, other.glassOpacity, t)!,
      cornerScale: lerpDouble(cornerScale, other.cornerScale, t)!,
      squareCorners: t < 0.5 ? squareCorners : other.squareCorners,
      powerSaving: t < 0.5 ? powerSaving : other.powerSaving,
      hyperMaterial: t < 0.5 ? hyperMaterial : other.hyperMaterial,
    );
  }
}

extension FlutifyTokensContext on BuildContext {
  FlutifyTokens get tokens => FlutifyTokens.of(this);

  /// 用户开启「减弱动效」或系统要求减少动态效果时为 true。
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;

  /// 减弱动效时返回 [Duration.zero]，否则原样返回。
  Duration motion(Duration duration) => reduceMotion ? Duration.zero : duration;
}
