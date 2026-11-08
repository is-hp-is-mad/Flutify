import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../screens/player/queue_list.dart';
import '../../widgets/connect/now_playing_source.dart';
import '../../widgets/empty_state.dart';
import '../panel_surface.dart';
import '../shell_layout_controller.dart';
import 'now_playing_details.dart';
import 'panel_lyrics_card.dart';

/// 桌面端右栏：顶部是当前面板的标题 + 关闭按钮，下面是面板内容。没有标签切换——
/// 「正在播放」与「播放队列」分别由播放栏上的「播放状态」键和队列键打开（见 [ShellLayoutController]）。
///
/// - 正在播放：详情列表里内嵌歌词卡；歌词卡放大后撑满整个面板，再点收起回到详情；
/// - 播放队列：完整队列。
///
/// 无播放内容时「正在播放」显示空状态，「播放队列」照常可用。
class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<ShellLayoutController>();
    // 遥控远程设备时展示远程曲目（歌词按远程进度滚动）
    final remote = NowPlayingSource.isRemote(context);
    final track = NowPlayingSource.track(context);
    final l10n = context.l10n;

    final isQueue = layout.panel == RightPanel.queue;
    final expanded = !isQueue && track != null && layout.lyricsExpanded;

    final Widget body;
    if (isQueue) {
      body = const QueueList(horizontalPadding: 16);
    } else if (track == null) {
      body = Center(
        child: EmptyState(
          icon: Icons.music_note_rounded,
          title: l10n.playerNothingPlayingTitle,
          message: l10n.playerNothingPlayingMessage,
        ),
      );
    } else if (expanded) {
      body = Padding(
        // 底部留白随播放栏占位：放大歌词不被悬浮胶囊压住最后一行
        padding: EdgeInsets.fromLTRB(12, 0, 12, 12 + MediaQuery.paddingOf(context).bottom),
        child: PanelLyricsCard(track: track, remote: remote, expanded: true),
      );
    } else {
      body = NowPlayingDetails(track: track, remote: remote);
    }

    return PanelSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeader(
            title: isQueue ? l10n.queueTitle : l10n.nowPlaying,
            closeTooltip: l10n.shellHidePanel,
            onClose: layout.closeRightPanel,
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: context.motion(const Duration(milliseconds: 320)),
              reverseDuration: context.motion(const Duration(milliseconds: 160)),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // 歌词放大 / 收起：从顶部轻微放大淡入，像卡片「长」满面板
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  alignment: Alignment.topCenter,
                  scale: Tween(begin: 0.96, end: 1.0).animate(animation),
                  child: child,
                ),
              ),
              child: KeyedSubtree(key: ValueKey((layout.panel, expanded)), child: body),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板标题栏：粗体标题（随面板切换淡入淡出）+ 右侧关闭按钮。
class _PanelHeader extends StatelessWidget {
  final String title;
  final String closeTooltip;
  final VoidCallback onClose;

  const _PanelHeader({required this.title, required this.closeTooltip, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: context.motion(const Duration(milliseconds: 200)),
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              child: Text(
                title,
                key: ValueKey(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: closeTooltip,
            color: theme.colorScheme.onSurfaceVariant,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
