import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EColorScheme, M3EThemeData, M3ETypeScale, M3ETypography;

import 'md3e_typography.dart';

/// 把 App 的 Flutter [ThemeData] 转成 material_3_expressive 用的 [M3EThemeData]。
///
/// 该包内部基于独立的 `material_ui` 包，它的 `Theme.of` 找不到 Flutter Material 的主题，
/// 没有显式提供 `M3ETheme` 时会退回默认的基准紫色与 Roboto 字体——按钮 / 开关 / 对话框
/// 都会脱离用户选择的强调色和 MiSans。这里逐项拷贝颜色与字体，由 App 根部注入。
M3EThemeData m3eThemeFrom(ThemeData theme) {
  final cached = _cache[theme];
  if (cached != null) return cached;
  final c = theme.colorScheme;
  final t = theme.textTheme;
  final isDark = c.brightness == Brightness.dark;
  final scheme = M3EColorScheme(
    brightness: c.brightness,
    primary: c.primary,
    onPrimary: c.onPrimary,
    primaryContainer: c.primaryContainer,
    onPrimaryContainer: c.onPrimaryContainer,
    secondary: c.secondary,
    onSecondary: c.onSecondary,
    secondaryContainer: c.secondaryContainer,
    onSecondaryContainer: c.onSecondaryContainer,
    tertiary: c.tertiary,
    onTertiary: c.onTertiary,
    tertiaryContainer: c.tertiaryContainer,
    onTertiaryContainer: c.onTertiaryContainer,
    error: c.error,
    onError: c.onError,
    errorContainer: c.errorContainer,
    onErrorContainer: c.onErrorContainer,
    surface: c.surface,
    onSurface: c.onSurface,
    onSurfaceVariant: c.onSurfaceVariant,
    surfaceContainerLowest: c.surfaceContainerLowest,
    surfaceContainerLow: c.surfaceContainerLow,
    surfaceContainer: c.surfaceContainer,
    surfaceContainerHigh: c.surfaceContainerHigh,
    surfaceContainerHighest: c.surfaceContainerHighest,
    surfaceDim: c.surfaceDim,
    surfaceBright: c.surfaceBright,
    inverseSurface: c.inverseSurface,
    onInverseSurface: c.onInverseSurface,
    inversePrimary: c.inversePrimary,
    outline: c.outline,
    outlineVariant: c.outlineVariant,
    shadow: c.shadow,
    scrim: c.scrim,
    surfaceTint: c.surfaceTint,
    // 扩展角色：与包内 fromColorScheme 的取法一致
    emphasis: c.primary,
    onEmphasis: c.onPrimary,
    info: c.tertiary,
    success: isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
    warning: isDark ? const Color(0xFFFFB74D) : const Color(0xFFEF6C00),
    danger: c.error,
    surfaceStrong: Color.alphaBlend(
      c.primary.withValues(alpha: 0.06),
      c.surface,
    ),
    onSurfaceStrong: c.onSurface,
    outlineStrong: c.outline,
  );
  final base = M3ETypeScale.baseline();
  final baseline = M3ETypeScale(
    displayLarge: t.displayLarge ?? base.displayLarge,
    displayMedium: t.displayMedium ?? base.displayMedium,
    displaySmall: t.displaySmall ?? base.displaySmall,
    headlineLarge: t.headlineLarge ?? base.headlineLarge,
    headlineMedium: t.headlineMedium ?? base.headlineMedium,
    headlineSmall: t.headlineSmall ?? base.headlineSmall,
    titleLarge: t.titleLarge ?? base.titleLarge,
    titleMedium: t.titleMedium ?? base.titleMedium,
    titleSmall: t.titleSmall ?? base.titleSmall,
    bodyLarge: t.bodyLarge ?? base.bodyLarge,
    bodyMedium: t.bodyMedium ?? base.bodyMedium,
    bodySmall: t.bodySmall ?? base.bodySmall,
    labelLarge: t.labelLarge ?? base.labelLarge,
    labelMedium: t.labelMedium ?? base.labelMedium,
    labelSmall: t.labelSmall ?? base.labelSmall,
  );
  final data = M3EThemeData(
    colorScheme: scheme,
    typography: M3ETypography(
      baseline: baseline,
      emphasized: M3ETypeScale.emphasized().apply(
        fontFamily: MD3ETypography.fontFamily,
      ),
    ),
    iconTheme: theme.iconTheme,
    visualDensity: theme.visualDensity.vertical,
    platform: theme.platform,
    splashColor: theme.splashColor,
    highlightColor: theme.highlightColor,
  );
  _cache[theme] = data;
  return data;
}

final Expando<M3EThemeData> _cache = Expando('m3eThemeFrom');
