import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart'
    show HyperBottomBar, HyperBottomBarItem;

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/hyper_surface.dart';
import '../../widgets/mini_player.dart';
import '../desktop/desktop_window.dart';
import 'android_floating_bar.dart';

/// 移动端底部区域：悬浮胶囊迷你播放器 + 悬浮药丸式液态玻璃底部导航（iOS 风格）。
///
/// 配合 `Scaffold(extendBody: true)` 使用：内容滚动到导航药丸下方时透过模糊可见；
/// 渐变遮罩放在导航区域，避免迷你播放器下缘出现一条矩形白边。
/// 整体高度通过 MediaQuery 底部 padding 传给页面（见 ContentBottomSpacer）。
/// Android 的柔光玻璃换成随滚动收放的 [AndroidFloatingBar]，其他平台与材质不变。
class MobileBottomBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 页面滚动驱动的收起状态，只有 [AndroidFloatingBar] 用。
  final FloatingBarFold? fold;

  const MobileBottomBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.fold,
  });

  @override
  Widget build(BuildContext context) {
    if (AndroidFloatingBar.enabled(context)) {
      return AndroidFloatingBar(
        selectedIndex: selectedIndex,
        onSelected: onSelected,
        fold: fold,
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MiniPlayer(),
        const SizedBox(height: 10),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                colorScheme.surface.withAlpha(0),
                colorScheme.surface.withAlpha(120),
              ],
            ),
          ),
          child: _GlassNavigationPill(
            selectedIndex: selectedIndex,
            onSelected: onSelected,
          ),
        ),
      ],
    );
  }
}

/// 悬浮药丸导航：模糊 + 表面色填充 + 一圈发丝描边 + 柔和投影，浮在内容之上。
class _GlassNavigationPill extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _GlassNavigationPill({
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    final l10n = context.l10n;
    final tokens = context.tokens;
    // 底色不透明度随设置页「玻璃不透明度」变化（默认 0.3 → 深色 175 / 浅色 205）；
    // 浅色下需要更高的不透明度，否则白底上的深色内容会让图标难以辨认
    final alpha =
        (isDark
                ? 120 + tokens.glassOpacity * 185
                : 150 + tokens.glassOpacity * 183)
            .clamp(0, 250)
            .round();
    final sigma = tokens.glassSigma * 0.8;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;

    if (tokens.hyperMaterial) {
      return Padding(
        padding: EdgeInsets.only(bottom: bottomSafe + 12),
        child: HyperBottomBar(
          index: selectedIndex,
          onChanged: onSelected,
          gradientBackground: false,
          surface: (child) => HyperBlendSurface(
            material: HyperBlendSurface.bar(context),
            borderRadius: BorderRadius.circular(32),
            bloom: HyperBlendSurface.barBloom(context),
            shadow: true,
            child: child,
          ),
          items: [
            HyperBottomBarItem(
              l10n.navHome,
              Icons.home_outlined,
              Icons.home_filled,
            ),
            HyperBottomBarItem(
              l10n.navSearch,
              Icons.search_rounded,
              Icons.search_rounded,
            ),
            HyperBottomBarItem(
              l10n.navLibrary,
              Icons.library_music_outlined,
              Icons.library_music_rounded,
            ),
          ],
        ),
      );
    }

    final nav = NavigationBar(
      height: 64,
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_filled),
          label: l10n.navHome,
        ),
        NavigationDestination(
          icon: const Icon(Icons.search_rounded),
          selectedIcon: const Icon(Icons.search_rounded),
          label: l10n.navSearch,
        ),
        NavigationDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music_rounded),
          label: l10n.navLibrary,
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottomSafe + 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 70 : 30),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          // 窄窗口桌面模式下同样受全屏切换崩溃影响，过渡期间暂停模糊（同 LiquidGlass）
          child: ValueListenableBuilder<bool>(
            valueListenable: DesktopWindow.fullscreenTransition,
            builder: (context, transitioning, _) {
              final fill = DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.surface.withAlpha(alpha),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withAlpha(110),
                    width: 0.5,
                  ),
                ),
                // 安全区已经留在药丸外，避免 NavigationBar 再在内部垫高底部。
                child: MediaQuery.removePadding(
                  context: context,
                  removeBottom: true,
                  child: nav,
                ),
              );
              // 省电模式与 LiquidGlass 一致：不复制、不模糊下方画面。底栏压在每个页面的滚动内容上，
              // 模糊开着时滚动的每一帧都要采样 + 模糊一次，是 Android 上的常驻开销
              if (transitioning || tokens.powerSaving) return fill;
              return BackdropFilter(
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: fill,
              );
            },
          ),
        ),
      ),
    );
  }
}
