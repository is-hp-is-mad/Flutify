import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../providers/playback_provider.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/cover_image.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;

/// 播放队列列表：正在播放 / 队列中的下一首 / 接下来播放（上下文）。
///
/// 两个待播列表都支持拖拽排序、左滑移除、点击跳播。
/// 移动端的 QueueSheet 与桌面端右栏「播放队列」标签共用本组件。
class QueueList extends StatelessWidget {
  /// 行的水平内边距（底部面板 20，桌面右栏更紧凑）。
  final double horizontalPadding;

  const QueueList({super.key, this.horizontalPadding = 20});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 进度不再触发 PlaybackProvider 通知，这里直接 watch 也只会在队列/切歌时重建
    final playback = context.watch<PlaybackProvider>();
    final current = playback.currentTrack;
    final userQueue = playback.userQueue;
    final upNext = playback.upNext;
    final ctx = playback.playbackContext;
    final l10n = context.l10n;

    return CustomScrollView(
      slivers: [
        if (current != null) ...[
          _SectionHeader(title: l10n.nowPlaying, padding: horizontalPadding),
          SliverToBoxAdapter(
            child: _QueueRow(
              coverUrl: current.coverUrl,
              title: current.name,
              subtitle: current.artistNames,
              highlighted: true,
              padding: horizontalPadding,
            ),
          ),
        ],

        if (userQueue.isNotEmpty) ...[
          _SectionHeader(
            title: l10n.queueNextInQueue,
            padding: horizontalPadding,
            action: M3EButton.text(
              onPressed: playback.clearUserQueue,
              child: Text(l10n.queueClear),
            ),
          ),
          SliverReorderableList(
            itemCount: userQueue.length,
            onReorderItem: playback.reorderUserQueue,
            itemBuilder: (context, i) {
              final entry = userQueue[i];
              return _DismissibleRow(
                key: ValueKey('uq_${entry.uid}'),
                index: i,
                padding: horizontalPadding,
                onDismissed: () => playback.removeFromUserQueue(i),
                onTap: () => playback.playFromUserQueue(i),
                coverUrl: entry.track.coverUrl,
                title: entry.track.name,
                subtitle: entry.track.artistNames,
              );
            },
          ),
        ],

        if (upNext.isNotEmpty) ...[
          _SectionHeader(
            title: ctx.isNone ? l10n.queueNextUp : l10n.queueNextFrom(ctx.name),
            padding: horizontalPadding,
          ),
          SliverReorderableList(
            itemCount: upNext.length,
            onReorderItem: playback.reorderUpNext,
            itemBuilder: (context, i) {
              final entry = upNext[i];
              return _DismissibleRow(
                key: ValueKey('ctx_${entry.uid}'),
                index: i,
                padding: horizontalPadding,
                onDismissed: () => playback.removeFromUpNext(i),
                onTap: () => playback.playFromUpNext(i),
                coverUrl: entry.track.coverUrl,
                title: entry.track.name,
                subtitle: entry.track.artistNames,
              );
            },
          ),
        ],

        if (userQueue.isEmpty && upNext.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                l10n.queueEmpty,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
          ),

        // 末尾留白随底部播放栏占位（ContentBottomSpacer：MediaQuery 底部 padding + 基础间距）
        const ContentBottomSpacer(),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  final double padding;

  const _SectionHeader({
    required this.title,
    required this.padding,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(padding, 16, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// 可左滑删除、可拖拽排序的队列行。
class _DismissibleRow extends StatelessWidget {
  final int index;
  final double padding;
  final VoidCallback onDismissed;
  final VoidCallback onTap;
  final String coverUrl;
  final String title;
  final String subtitle;

  const _DismissibleRow({
    super.key,
    required this.index,
    required this.padding,
    required this.onDismissed,
    required this.onTap,
    required this.coverUrl,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: key!,
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismissed(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Icon(Icons.delete_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: _QueueRow(
          coverUrl: coverUrl,
          title: title,
          subtitle: subtitle,
          padding: padding,
          onTap: onTap,
          trailing: ReorderableDragStartListener(
            index: index,
            child: const MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: EdgeInsets.all(8.0),
                child: Icon(Icons.drag_handle_rounded, color: Colors.grey),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final String coverUrl;
  final String title;
  final String subtitle;
  final double padding;
  final bool highlighted;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _QueueRow({
    required this.coverUrl,
    required this.title,
    required this.subtitle,
    required this.padding,
    this.highlighted = false,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.only(left: padding, right: 8),
      onTap: onTap,
      leading: CoverImage(
        url: coverUrl,
        size: 44,
        borderRadius: BorderRadius.circular(6),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: highlighted ? colorScheme.primary : colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}
