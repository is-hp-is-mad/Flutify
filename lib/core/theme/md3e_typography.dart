import 'package:flutter/material.dart';

/// Material 3 Expressive (MD3E) 字体规范 —— MiSans（中英文统一字族）。
///
/// 规则：
/// * 字族：打包的 MiSans（见 pubspec.yaml），中文与拉丁字母同一套字形，不再运行时拉取字体。
/// * 字重：打包 400 / 500 / 600 / 700 四档；w800 / w900 按 CSS 匹配规则回落到 Bold。
/// * 行高：中文字形占满整个字身框，行高比纯英文排版放宽（正文 1.5、标题约 1.3），
///   并使用 [TextLeadingDistribution.even] 让行距上下均分，避免汉字顶部 / 底部被裁切。
/// * 字距：汉字本身等宽且紧凑，负字距会让汉字挤在一起；只在展示级大字号保留轻微收紧，
///   其余层级字距为 0（英文部分由 MiSans 自带的字偶距保证观感）。
class MD3ETypography {
  MD3ETypography._();

  /// App 全局字族名，与 pubspec.yaml 中 `family: MiSans` 对应。
  static const String fontFamily = 'MiSans';

  /// 柔光玻璃的字族：同样是 MiSans，字重封顶到 Demibold（见 pubspec.yaml）。
  static const String hyperFontFamily = 'MiSansHyper';

  static TextTheme createTextTheme([TextTheme? base, String family = fontFamily]) {
    final t = base ?? Typography.material2021().englishLike;

    /// 统一套用字族、行高与行距分布；[weight] / [spacing] 为各层级的差异项。
    TextStyle? style(TextStyle? s, FontWeight weight, double height, [double spacing = 0]) {
      return s?.copyWith(
        fontFamily: family,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
        leadingDistribution: TextLeadingDistribution.even,
      );
    }

    return t.copyWith(
      // 展示级：大号数字 / 英文标题，Demibold 封顶保留轻微收紧与呼吸感
      displayLarge: style(t.displayLarge, FontWeight.w600, 1.15, -0.8),
      displayMedium: style(t.displayMedium, FontWeight.w600, 1.18, -0.4),
      displaySmall: style(t.displaySmall, FontWeight.w600, 1.2, -0.2),
      // 标题级：页面大标题、问候语
      headlineLarge: style(t.headlineLarge, FontWeight.w600, 1.25),
      headlineMedium: style(t.headlineMedium, FontWeight.w600, 1.28),
      headlineSmall: style(t.headlineSmall, FontWeight.w600, 1.3),
      // 标题：卡片 / 分区 / 列表主文本
      titleLarge: style(t.titleLarge, FontWeight.w600, 1.32),
      titleMedium: style(t.titleMedium, FontWeight.w600, 1.4),
      titleSmall: style(t.titleSmall, FontWeight.w600, 1.4),
      // 正文：中文阅读舒适行高
      bodyLarge: style(t.bodyLarge, FontWeight.w400, 1.5),
      bodyMedium: style(t.bodyMedium, FontWeight.w400, 1.5),
      bodySmall: style(t.bodySmall, FontWeight.w400, 1.45),
      // 标签：按钮、胶囊、导航标签
      labelLarge: style(t.labelLarge, FontWeight.w600, 1.35, 0.1),
      labelMedium: style(t.labelMedium, FontWeight.w500, 1.35, 0.1),
      labelSmall: style(t.labelSmall, FontWeight.w500, 1.35, 0.2),
    );
  }
}
