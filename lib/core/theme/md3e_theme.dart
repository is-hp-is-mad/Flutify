import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Hy;


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

    final hyper = settings.glassMaterial == GlassMaterial.hyper;
    final base = MD3EColors.createColorScheme(
      primary: accent,
      brightness: brightness,
      pureBlack: settings.pureBlack && brightness == Brightness.dark,
    );
    final scheme = hyper ? _hyperScheme(base) : base;
    final theme = _build(
      scheme,
      FlutifyTokens.from(settings, accent),
      settings.reduceMotion,
      hyper ? MD3ETypography.hyperFontFamily : MD3ETypography.fontFamily,
    );
    return _cache[key] = hyper ? _hyperTheme(theme, settings.reduceMotion) : theme;
  }

  /// 柔光玻璃的配色：miuix 的中性色（窗口 / 卡片 / 文字），只保留强调色，没有 MD3 的色调表面。
  static ColorScheme _hyperScheme(ColorScheme s) {
    final dark = s.brightness == Brightness.dark;
    final card = Hy.card(dark);
    Color over(Color base, Color tint, int alpha) =>
        Color.alphaBlend(tint.withAlpha(alpha), base);
    final neutral = over(card, dark ? Colors.white : Colors.black, 15);
    // 强调色和窗口底色太接近时（如深色下选了黑色）换成文字色，否则按钮、选中态都看不见
    final lost =
        (s.primary.computeLuminance() - Hy.window(dark).computeLuminance()).abs() < 0.08;
    final primary = lost ? (dark ? Colors.white : Colors.black) : s.primary;
    final onPrimary = lost ? (dark ? Colors.black : Colors.white) : s.onPrimary;
    return s.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      surface: Hy.window(dark),
      onSurface: Hy.text(dark),
      onSurfaceVariant: Hy.sub(dark),
      surfaceDim: Hy.window(dark),
      surfaceBright: card,
      surfaceContainerLowest: Hy.window(dark),
      surfaceContainerLow: card,
      surfaceContainer: card,
      surfaceContainerHigh: card,
      surfaceContainerHighest: neutral,
      surfaceTint: Colors.transparent,
      primaryContainer: over(card, primary, 36),
      onPrimaryContainer: primary,
      secondary: primary,
      onSecondary: onPrimary,
      secondaryContainer: neutral,
      onSecondaryContainer: Hy.text(dark),
      tertiaryContainer: neutral,
      onTertiaryContainer: Hy.text(dark),
      outline: Hy.hint(dark),
      outlineVariant: over(card, dark ? Colors.white : Colors.black, 20),
    );
  }

  /// 柔光玻璃的控件样式：没有水波纹，按压是浅灰高亮；滑块、输入框、列表、页面转场按 miuix。
  static ThemeData _hyperTheme(ThemeData t, bool reduceMotion) {
    final s = t.colorScheme;
    final dark = s.brightness == Brightness.dark;
    final tokens = t.extension<FlutifyTokens>()!;
    final fill = dark ? const Color(0x1fffffff) : const Color(0x0f000000);
    final field = OutlineInputBorder(
      borderRadius: tokens.radius(16),
      borderSide: BorderSide.none,
    );
    return t.copyWith(
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Hy.pressed(dark),
      hoverColor: Hy.pressed(dark).withValues(alpha: 0.04),
      focusColor: Colors.transparent,
      dividerColor: Hy.divider(dark),
      // 所有默认的返回 / 关闭键都换成左上角的圆形玻璃按钮
      actionIconTheme: ActionIconThemeData(
        backButtonIconBuilder: (_) =>
            const Icon(Icons.arrow_back_rounded, size: 19),
        closeButtonIconBuilder: (_) =>
            const Icon(Icons.close_rounded, size: 22),
      ),
      // miuix 的层级靠字号而不是粗体，标题都比 MD3 小一档
      textTheme: t.textTheme.copyWith(
        displayLarge: t.textTheme.displayLarge?.copyWith(fontSize: 40, letterSpacing: 0),
        displayMedium: t.textTheme.displayMedium?.copyWith(fontSize: 34, letterSpacing: 0),
        displaySmall: t.textTheme.displaySmall?.copyWith(fontSize: Hy.title1, letterSpacing: 0),
        headlineLarge: t.textTheme.headlineLarge?.copyWith(fontSize: 26),
        headlineMedium: t.textTheme.headlineMedium?.copyWith(fontSize: Hy.title2),
        headlineSmall: t.textTheme.headlineSmall?.copyWith(fontSize: Hy.title3),
        titleLarge: t.textTheme.titleLarge?.copyWith(fontSize: Hy.title4),
        titleMedium: t.textTheme.titleMedium?.copyWith(fontSize: Hy.body1),
        titleSmall: t.textTheme.titleSmall?.copyWith(fontSize: Hy.body2),
        labelLarge: t.textTheme.labelLarge?.copyWith(letterSpacing: 0),
        labelMedium: t.textTheme.labelMedium?.copyWith(letterSpacing: 0),
        labelSmall: t.textTheme.labelSmall?.copyWith(letterSpacing: 0),
      ),
      pageTransitionsTheme: reduceMotion
          ? t.pageTransitionsTheme
          : const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: _HyperPageTransitions(),
                TargetPlatform.iOS: _HyperPageTransitions(),
                TargetPlatform.windows: _HyperPageTransitions(),
                TargetPlatform.macOS: _HyperPageTransitions(),
                TargetPlatform.linux: _HyperPageTransitions(),
              },
            ),
      appBarTheme: t.appBarTheme.copyWith(
        centerTitle: true,
        titleTextStyle: t.appBarTheme.titleTextStyle?.copyWith(
          fontSize: Hy.title4,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: t.cardTheme.copyWith(
        color: s.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: tokens.radius(16)),
      ),
      chipTheme: t.chipTheme.copyWith(
        backgroundColor: fill,
        selectedColor: s.primaryContainer,
        labelStyle: t.chipTheme.labelStyle?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: Hy.divider(dark),
        thickness: 0.5,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        iconColor: s.onSurfaceVariant,
        titleTextStyle: t.textTheme.bodyLarge?.copyWith(
          color: s.onSurface,
          fontSize: Hy.body1,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: t.textTheme.bodySmall?.copyWith(
          color: s.onSurfaceVariant,
          fontSize: Hy.subtitle,
        ),
      ),
      sliderTheme: t.sliderTheme.copyWith(
        activeTrackColor: s.primary,
        inactiveTrackColor: fill,
        thumbColor: Colors.white,
        overlayColor: Colors.transparent,
        trackHeight: 6,
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 9,
          elevation: 2,
        ),
      ),
      // ignore: deprecated_member_use
      progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: true),
      inputDecorationTheme: t.inputDecorationTheme.copyWith(
        fillColor: fill,
        border: field,
        enabledBorder: field,
        focusedBorder: field,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? const Color(0xff3a3a3a) : const Color(0xe6242424),
          borderRadius: BorderRadius.circular(8),
        ),
        // Tooltip 画在 Overlay 上，继承不到页面字体：这里必须从 textTheme 带上字族
        textStyle: t.textTheme.bodySmall?.copyWith(
          color: Colors.white,
          fontSize: Hy.subtitle,
        ),
      ),
      floatingActionButtonTheme: t.floatingActionButtonTheme.copyWith(
        elevation: 2,
        shape: const CircleBorder(),
      ),
    );
  }

  static ThemeData _build(
    ColorScheme colorScheme,
    FlutifyTokens tokens,
    bool reduceMotion,
    String fontFamily,
  ) {
    // englishLike 的样式 inherit=false，ThemeData 合并时不会补颜色；
    // FlexibleSpaceBar 等组件会对 titleLarge.color 做非空断言，必须显式着色。
    final textTheme = MD3ETypography.createTextTheme(null, fontFamily).apply(
      bodyColor: colorScheme.onSurface,
      displayColor: colorScheme.onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: colorScheme.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      // 全局默认字族：未显式指定字族的 TextStyle（按钮、导航标签等）同样使用 MiSans
      fontFamily: fontFamily,
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
          fontWeight: FontWeight.w600,
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
              fontWeight: FontWeight.w600,
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
          fontWeight: FontWeight.w600,
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
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
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

/// 柔光玻璃的页面切换：新页面从右侧滑入，旧页面左移 25% 并压暗 20%。
class _HyperPageTransitions extends PageTransitionsBuilder {
  const _HyperPageTransitions();

  static const Curve _curve = Cubic(0.2, 0.9, 0.2, 1);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(
      parent: animation,
      curve: _curve,
      reverseCurve: _curve.flipped,
    );
    final leave = CurvedAnimation(
      parent: secondaryAnimation,
      curve: _curve,
      reverseCurve: _curve.flipped,
    );
    return ClipRect(
      child: SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(enter),
        child: SlideTransition(
          position: Tween(begin: Offset.zero, end: const Offset(-0.25, 0)).animate(leave),
          child: AnimatedBuilder(
            animation: leave,
            child: child,
            builder: (_, child) => leave.value <= 0
                ? child!
                : ColorFiltered(
                    colorFilter: ColorFilter.mode(
                      Colors.black.withValues(alpha: 0.2 * leave.value),
                      BlendMode.srcATop,
                    ),
                    child: child,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 柔光玻璃的滚动：到头回弹（miuix 的 SpringBackLayout），没有 Android 的拉伸效果。
class HyperScrollBehavior extends MaterialScrollBehavior {
  const HyperScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
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
