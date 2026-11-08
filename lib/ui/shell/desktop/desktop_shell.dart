import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../widgets/connect/connect_actions.dart';
import '../../widgets/connect/remote_player_bar.dart';
import '../../widgets/desktop_player_bar.dart';
import '../panel_surface.dart';
import '../shell_breakpoints.dart';
import '../shell_layout_controller.dart';
import 'desktop_top_bar.dart';
import 'library_sidebar.dart';
import 'now_playing_panel.dart';
import 'panel_resize_handle.dart';

/// 桌面端三栏框架（Spotify 新版桌面端布局 + MD3E 质感）。
///
/// ```
/// ┌ 顶栏（自绘标题栏）─────────────────────────────────┐
/// │ 音乐库 ┆ 内容（嵌套 Navigator）         │ 正在播放 │
/// ├ 播放栏 ────────────────────────────────────────────┤
/// ```
/// 分档（见 [ShellBreakpoints]）：
/// - < 1100：音乐库强制收起为 72px，收起按钮不可用；
/// - < 1280：右栏默认关闭，打开时浮在内容区右侧（带阴影），不挤压内容；
/// - ≥ 1280：右栏停靠为第三栏。
class DesktopShell extends StatelessWidget {
  final Widget pages;
  final DesktopTopBar topBar;

  const DesktopShell({super.key, required this.pages, required this.topBar});

  /// 桌面端底部提示（SnackBar）的宽度：水平居中、不铺满整个窗口。
  static const double toastWidth = 440;

  /// 按基础主题缓存「带桌面提示宽度」的主题：拖动侧栏时本组件每帧重建，
  /// 每次都 new 一个 ThemeData 会让所有依赖主题的子组件跟着重建。
  static final Expando<ThemeData> _toastThemes = Expando('desktopToastTheme');

  static ThemeData _withToastWidth(ThemeData base) =>
      _toastThemes[base] ??= base.copyWith(
        snackBarTheme: base.snackBarTheme.copyWith(width: toastWidth),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final layout = context.watch<ShellLayoutController>();
    const gutter = ShellBreakpoints.gutter;

    // 播放栏是悬浮液态玻璃胶囊（iOS 风格）：extendBody 让三栏内容铺到窗口底部，
    // 胶囊透过模糊看到身后内容；胶囊占位高度经 MediaQuery 底部 padding 传给页面
    // （ContentBottomSpacer 据此在滚动末尾留白，与移动端同一套机制）。
    final barReserved = ConnectActions.showRemote(context)
        ? RemotePlayerBar.reservedHeight
        : DesktopPlayerBar.reservedHeight;
    final media = MediaQuery.of(context);

    // 提示的位置由当前布局决定，而不是在弹出那一刻按窗口宽度算死：
    // - 播放栏作为 bottomNavigationBar，Scaffold 自动把悬浮提示放在它上方；
    // - 宽度来自主题，窗口拖窄（< 宽度）时 Scaffold 自动改为铺满，切到手机布局后也不残留桌面边距。
    return Theme(
      data: _withToastWidth(theme),
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest,
        extendBody: true,
        bottomNavigationBar: const DesktopPlayerBar(),
        body: MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(bottom: barReserved),
          ),
          child: Column(
            children: [
              topBar,
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final forcedCompact =
                        width < ShellBreakpoints.sidebarExpandable;
                    final compact = forcedCompact || layout.sidebarCollapsed;
                    final sidebarWidth = compact
                        ? ShellBreakpoints.sidebarCollapsed
                        : layout.sidebarWidth;
                    final rightOpen = layout.rightPanelVisible;
                    final rightDocked = layout.docked;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: gutter),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            width: sidebarWidth,
                            // 宽度动画过程中按实际宽度选布局：不足展开最小宽度时一律按收起样式绘制，
                            // 避免展开布局被压缩溢出
                            child: LayoutBuilder(
                              builder: (context, box) => LibrarySidebar(
                                compact:
                                    compact ||
                                    box.maxWidth < ShellBreakpoints.sidebarMin,
                                onToggleCompact: forcedCompact
                                    ? null
                                    : layout.toggleSidebar,
                              ),
                            ),
                          ),
                          if (compact)
                            const SizedBox(width: gutter)
                          else
                            PanelResizeHandle(
                              onDrag: (dx) => layout.setSidebarWidth(
                                layout.sidebarWidth + dx,
                              ),
                              onDragEnd: () => layout.setSidebarWidth(
                                layout.sidebarWidth,
                                persist: true,
                              ),
                            ),
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: PanelSurface(child: pages),
                                ),
                                // 窄窗口：右栏浮于内容之上；点击浮层外或按 Esc 关闭
                                if (rightOpen && !rightDocked)
                                  Positioned.fill(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: layout.closeRightPanel,
                                    ),
                                  ),
                                if (rightOpen && !rightDocked)
                                  Positioned(
                                    top: 0,
                                    bottom: 0,
                                    right: 0,
                                    width: ShellBreakpoints.nowPlayingWidth,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: PanelSurface.radiusOf(
                                          context,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withAlpha(90),
                                            blurRadius: 32,
                                            offset: const Offset(-8, 0),
                                          ),
                                        ],
                                      ),
                                      child: CallbackShortcuts(
                                        bindings: {
                                          const SingleActivator(
                                            LogicalKeyboardKey.escape,
                                          ): layout.closeRightPanel,
                                        },
                                        child: const Focus(
                                          autofocus: true,
                                          child: NowPlayingPanel(),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (rightOpen && rightDocked) ...[
                            const SizedBox(width: gutter),
                            const SizedBox(
                              width: ShellBreakpoints.nowPlayingWidth,
                              child: NowPlayingPanel(),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
