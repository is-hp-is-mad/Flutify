import 'package:flutter/material.dart';

import '../../models/appearance.dart';
import 'flutify_tokens.dart';
import 'md3e_colors.dart';
import 'md3e_shapes.dart';
import 'md3e_typography.dart';
import 'system_bars.dart';

/// Complete Material 3 Expressive (MD3E) Theme Provider
class MD3ETheme {
  MD3ETheme._();

  /// 默认外观的深 / 浅色主题（测试与未接入外观设置的场景使用）。
  static final ThemeData dark = build(Brightness.dark, AppearanceSettings.defaults, MD3EColors.spotifyGreen);
  static final ThemeData light = build(Brightness.light, AppearanceSettings.defaults, MD3EColors.spotifyGreen);

  /// 最近用过的主题；拖动设置页滑杆时会连续生成，限制数量避免无限增长。
  static final Map<(Brightness, AppearanceSettings, Color), ThemeData> _cache = {};

  /// 按外观设置生成主题。[accent] 是本次实际使用的强调色（动态取色时为封面色，否则为用户所选）。
  static ThemeData build(Brightness brightness, AppearanceSettings settings, Color accent) {
    final key = (brightness, settings, accent);
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 24) _cache.remove(_cache.keys.first);

    final scheme = MD3EColors.createColorScheme(
      primary: accent,
      brightness: brightness,
      pureBlack: settings.pureBlack && brightness == Brightness.dark,
    );
    return _cache[key] = _build(scheme, FlutifyTokens.from(settings, accent), settings.reduceMotion);
  }

  static ThemeData _build(ColorScheme colorScheme, FlutifyTokens tokens, bool reduceMotion) {
    // englishLike 的样式 inherit=false，ThemeData 合并时不会补颜色；
    // FlexibleSpaceBar 等组件会对 titleLarge.color 做非空断言，必须显式着色。
    final textTheme = MD3ETypography.createTextTheme().apply(
      bodyColor: colorScheme.onSurface,
      displayColor: colorScheme.onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: colorScheme.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      // 全局默认字族：未显式指定字族的 TextStyle（按钮、导航标签等）同样使用 MiSans
      fontFamily: MD3ETypography.fontFamily,
      textTheme: textTheme,
      extensions: [tokens],
      // 减弱动效：页面切换不做滑动 / 缩放，直接出现
      pageTransitionsTheme: reduceMotion
          ? const PageTransitionsTheme(builders: {
              TargetPlatform.android: _NoTransitionsBuilder(),
              TargetPlatform.iOS: _NoTransitionsBuilder(),
              TargetPlatform.windows: _NoTransitionsBuilder(),
              TargetPlatform.macOS: _NoTransitionsBuilder(),
              TargetPlatform.linux: _NoTransitionsBuilder(),
            })
          : null,

      // App Bar Theme
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        // AppBar creates its own overlay region, overriding the app-wide one.
        systemOverlayStyle: systemBarsStyle(colorScheme.brightness),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.bold,
        ),
      ),

      // Expressive Navigation Bar
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surfaceContainer.withAlpha(220),
        indicatorColor: colorScheme.primaryContainer,
        elevation: 0,
        height: 70,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.primary, size: 24);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: colorScheme.primary,
            );
          }
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurfaceVariant,
          );
        }),
      ),

      // Navigation Rail for desktop / tablet
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: colorScheme.surfaceContainerLowest,
        indicatorColor: colorScheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: colorScheme.primary),
        unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: colorScheme.primary,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
          fontSize: 12,
        ),
      ),

      // Card Theme (MD3E Expressive rounded cards)
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: tokens.radius(MD3EShapes.radiusLarge),
        ),
        margin: EdgeInsets.zero,
      ),

      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: tokens.radius(MD3EShapes.radiusExtraLarge)),
      ),

      // Expressive Floating Action Button
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: tokens.radius(20),
        ),
      ),

      // Filled Button (Pill shaped)
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: tokens.pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
        ).copyWith(mouseCursor: WidgetStateMouseCursor.clickable),
      ),

      // Outlined Button (Pill shaped)
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(color: colorScheme.outlineVariant),
          shape: tokens.pillShape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ).copyWith(mouseCursor: WidgetStateMouseCursor.clickable),
      ),

      // 桌面端 Material 默认光标是 adaptiveClickable（非 Web 解析为箭头），
      // 这里统一为可点击控件显示手型；禁用态由 WidgetStateMouseCursor.clickable 自动解析为箭头。
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable),
      ),
      popupMenuTheme: PopupMenuThemeData(
        mouseCursor: WidgetStateMouseCursor.clickable,
      ),

      // Chip Theme
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        selectedColor: colorScheme.primary,
        labelStyle: textTheme.labelMedium?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        shape: tokens.pillShape,
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),

      // Expressive Slider Theme
      // Expressive Slider Theme（播放进度条为刻意的紧凑样式：圆点手柄 + 细轨道；
      // 不启用 year2023: false，否则末端停止点会和各处自定义的圆点手柄混在一起）
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.onSurfaceVariant.withAlpha(50),
        thumbColor: colorScheme.brightness == Brightness.dark ? Colors.white : colorScheme.onSurface,
        overlayColor: colorScheme.primary.withAlpha(40),
        trackHeight: 4.0,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
      ),

      // MD3E 进度指示器：分段留缝 + 停止点
      // ignore: deprecated_member_use
      progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),

      // MD3E 开关：选中时手柄带对勾
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Icon(Icons.check_rounded)
              : null,
        ),
      ),

      // Expressive SnackBar：悬浮、大圆角、反色表面；操作按钮为浅色调胶囊
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onInverseSurface,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        actionTextColor: colorScheme.inversePrimary,
        actionBackgroundColor: colorScheme.inversePrimary.withAlpha(36),
        // 单行提示（38 图标块 + 上下 10 内边距）约 58 高：28 圆角即为完整胶囊，两行时为大圆角卡片
        shape: RoundedRectangleBorder(borderRadius: tokens.radius(28)),
        elevation: 6,
        insetPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        modalBackgroundColor: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(tokens.corner(32))),
        ),
        elevation: 16,
        showDragHandle: true,
        dragHandleColor: colorScheme.onSurfaceVariant.withAlpha(100),
      ),

      // Input Decoration Theme (Search & Form Fields)
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: tokens.pill,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: tokens.pill,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: tokens.pill,
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 减弱动效时的页面切换：不做任何过渡动画。
class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
