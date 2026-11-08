import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/home_feed.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/spotify_provider.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../shell/shell_breakpoints.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/hyper_surface.dart';
import '../../widgets/user_avatar.dart';
import '../../widgets/toast/app_toast.dart';
import '../auth/login_screen.dart';
import 'widgets/home_chip_bar.dart';
import 'widgets/home_feed_grid.dart';
import 'widgets/home_shelf.dart';
import 'widgets/home_shortcuts_grid.dart';
import 'widgets/home_skeleton.dart';
import 'widgets/home_top_gradient.dart';

/// 主页：与官方 Spotify 客户端同源的 home 查询，按分区原样还原。
///
/// 自上而下：
/// 1. 筛选标签（吸顶；手机端左侧带头像，点按打开设置）；
/// 2. 快捷入口网格（最多 8 个）；
/// 3. 各分区：普通卡架 / 最近播放 / 推荐流网格（顺序与服务端一致）。
///
/// 只订阅主页数据与加载状态；播放状态一律通过 read 调用，播放过程中主页不会重建。
class HomeScreen extends StatefulWidget {
  final VoidCallback onOpenSettings;

  const HomeScreen({super.key, required this.onOpenSettings});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 悬停快捷入口时的封面主色：只驱动顶部渐变（ValueListenable 避免整页重建）。
  final ValueNotifier<Color?> _hoverTint = ValueNotifier(null);

  /// 列表垂直滚动位移：平滑驱动移动端状态栏接管
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0);

  @override
  void dispose() {
    _hoverTint.dispose();
    _scrollOffset.dispose();
    super.dispose();
  }

  void _setHoverTint(Color? color) {
    if (_hoverTint.value != color) _hoverTint.value = color;
  }

  Future<void> _refresh() async {
    if (!context.read<SpotifyApiService>().isConfigured) return;
    final provider = context.read<SpotifyProvider>();
    await provider.refreshHome();
    if (!mounted || provider.homeError == null || provider.isLoadingFeed) {
      return;
    }
    AppToast.show(
      context,
      context.l10n.homeRefreshFailed,
      tone: ToastTone.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = ShellBreakpoints.isDesktop(
      MediaQuery.sizeOf(context).width,
    );
    final home = context.select<SpotifyProvider, HomeFeed>((s) => s.home);
    final facet = context.select<SpotifyProvider, String>((s) => s.homeFacet);
    final loading = context.select<SpotifyProvider, bool>(
      (s) => s.isLoadingFeed,
    );
    final provider = context.read<SpotifyProvider>();

    return Scaffold(
      body: Stack(
        children: [
          // 顶部渐变（官方桌面端效果）：随快捷入口悬停的封面取色，固定在顶部不随滚动
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: HomeTopGradient.extent,
            child: HomeTopGradient(tint: _hoverTint),
          ),
          SafeArea(
            bottom: false,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.axis == Axis.vertical) {
                  _scrollOffset.value = notification.metrics.pixels;
                }
                return false;
              },
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    HomeChipBar(
                      chips: home.chips,
                      selected: facet,
                      onSelected: provider.selectHomeFacet,
                      pinned: false,
                      trailing: IconButton(
                        tooltip: context.l10n.homeRefresh,
                        onPressed:
                            loading ||
                                !context.read<SpotifyApiService>().isConfigured
                            ? null
                            : _refresh,
                        icon: const Icon(Icons.refresh_rounded),
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                      ),
                      leading: desktop
                          ? null
                          : MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: widget.onOpenSettings,
                                child: const UserAvatar(size: 36),
                              ),
                            ),
                    ),
                    ..._content(
                      context,
                      home: home,
                      facet: facet,
                      loading: loading,
                      desktop: desktop,
                    ),
                    const ContentBottomSpacer(),
                  ],
                ),
              ),
            ),
          ),
          // 移动端状态栏自然通透接管（顶部无滚动时完全透亮无切割，向上滚动时平滑渐变接管）
          if (!desktop)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.paddingOf(context).top + 20,
              child: ValueListenableBuilder<double>(
                valueListenable: _scrollOffset,
                builder: (context, offset, _) {
                  final t = (offset / 36.0).clamp(0.0, 1.0);
                  if (t <= 0.001) return const SizedBox.shrink();
                  return IgnorePointer(
                    child: Opacity(
                      opacity: t,
                      child: HyperAppBarBackground(
                        tintColor: theme.scaffoldBackgroundColor,
                        showBottomLine: false,
                        isDesktop: false,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _content(
    BuildContext context, {
    required HomeFeed home,
    required String facet,
    required bool loading,
    required bool desktop,
  }) {
    final l10n = context.l10n;

    if (!context.read<SpotifyApiService>().isConfigured) {
      return [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.lock_outline_rounded,
            title: l10n.detailSignInRequired,
            actionLabel: l10n.shellSignIn,
            onAction: () => LoginScreen.open(context),
          ),
        ),
      ];
    }
    if (home.isEmpty && loading)
      return [SliverToBoxAdapter(child: HomeSkeleton(desktop: desktop))];
    // 续期凭据被吊销时任何请求都会失败，提示重新登录而不是「检查网络」
    if (home.isEmpty &&
        context.select<AuthProvider, bool>((a) => a.sessionExpired)) {
      return [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.lock_clock_outlined,
            title: l10n.authSessionExpiredTitle,
            message: l10n.authSessionExpiredMessage,
            actionLabel: l10n.authSignInAgain,
            onAction: () => LoginScreen.signInAgain(context),
          ),
        ),
      ];
    }
    if (home.isEmpty) {
      final failed = context.read<SpotifyProvider>().homeError != null;
      return [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: failed
                ? Icons.wifi_off_rounded
                : Icons.library_music_outlined,
            title: failed ? l10n.homeLoadFailedTitle : l10n.homeEmptyTitle,
            message: failed
                ? l10n.homeLoadFailedMessage
                : l10n.homeEmptyMessage,
            actionLabel: l10n.commonRetry,
            onAction: _refresh,
          ),
        ),
      ];
    }

    // 切换筛选标签期间旧内容半透明，表示正在刷新
    return [
      for (final sliver in _sections(
        context,
        home,
        facet: facet,
        desktop: desktop,
      ))
        SliverAnimatedOpacity(
          opacity: loading ? 0.5 : 1,
          duration: const Duration(milliseconds: 200),
          sliver: sliver,
        ),
    ];
  }

  /// 分区 → sliver：连续的卡架合并进一个懒加载列表（30 余个分区只构建可见的几个），
  /// 推荐流单独成网格。
  List<Widget> _sections(
    BuildContext context,
    HomeFeed home, {
    required String facet,
    required bool desktop,
  }) {
    final slivers = <Widget>[
      if (home.shortcuts.isNotEmpty)
        HomeShortcutsGrid(
          items: home.shortcuts,
          desktop: desktop,
          onHoverTint: _setHoverTint,
        ),
    ];
    var shelves = <HomeSection>[];

    void flushShelves() {
      if (shelves.isEmpty) return;
      final batch = shelves;
      slivers.add(
        SliverList.builder(
          itemCount: batch.length,
          itemBuilder: (context, index) => HomeShelf(
            section: batch[index],
            desktop: desktop,
            onShowAll: () =>
                AppRoutes.openHomeSection(context, batch[index], facet: facet),
          ),
        ),
      );
      shelves = [];
    }

    for (final section in home.sections) {
      if (section.kind == HomeSectionKind.feed) {
        flushShelves();
        slivers.add(HomeFeedGrid(section: section, desktop: desktop));
      } else {
        shelves.add(section);
      }
    }
    flushShelves();
    return slivers;
  }
}
