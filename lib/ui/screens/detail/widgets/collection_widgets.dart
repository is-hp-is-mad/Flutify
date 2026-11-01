import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/playback_context.dart';
import '../../../../models/track.dart';
import '../../../../providers/playback_provider.dart';
import '../../auth/login_screen.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/player_controls.dart';
import '../../../widgets/skeleton.dart';

// 歌单 / 专辑 / 艺人详情页共用的操作行组件（头部见 collection_hero.dart）。

/// 详情页大号播放按钮：
/// 正在播放该上下文 → 暂停；该上下文已暂停 → 继续；否则从头播放整个上下文。
///
/// 与 Spotify 一致，深浅色主题下都是强调色底 + 自动黑 / 白图标（浅色主题的 primary 是加深色，不用它）。
class ContextPlayButton extends StatelessWidget {
  final List<SpotifyTrack> tracks;
  final PlaybackContext playbackContext;
  final double size;

  /// 吸顶标题栏里的小号按钮不需要投影。
  final bool elevated;

  const ContextPlayButton({
    super.key,
    required this.tracks,
    required this.playbackContext,
    this.size = 56,
    this.elevated = true,
  });

  @override
  Widget build(BuildContext context) {
    final uri = playbackContext.uri;
    final tokens = context.tokens;
    final hyper = tokens.hyperMaterial;
    final scheme = Theme.of(context).colorScheme;
    final (isPlayingThis, isThisContext) = context.select<PlaybackProvider, (bool, bool)>(
      (p) => (p.isPlayingContext(uri), p.playbackContext.uri == uri),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          if (elevated && !hyper)
            BoxShadow(color: Colors.black.withAlpha(70), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Material(
        color: hyper ? scheme.primary : tokens.accent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          mouseCursor: tracks.isEmpty
              ? MouseCursor.defer
              : SystemMouseCursors.click,
          onTap: tracks.isEmpty
              ? null
              : () {
                  final playback = context.read<PlaybackProvider>();
                  if (isPlayingThis || isThisContext) {
                    playback.togglePlayPause();
                  } else {
                    playback.playContext(tracks, playbackContext);
                  }
                },
          child: Icon(
            isPlayingThis ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: hyper ? scheme.onPrimary : tokens.onAccent,
            size: size * 0.6,
          ),
        ),
      ),
    );
  }
}

/// 操作行。
/// - 宽（≥ 600，桌面端）：大播放键 → 随机 → 自定义按钮（收藏 / 更多），全部靠左；
/// - 窄（手机）：自定义按钮靠左，随机 + 大播放键靠右。
class CollectionActionRow extends StatelessWidget {
  final List<Widget> leading;
  final List<SpotifyTrack> tracks;
  final PlaybackContext playbackContext;

  /// 靠右的工具（歌单页的搜索 / 排序）；可被压缩，空间不够时自身省略。
  final Widget? trailing;

  const CollectionActionRow({
    super.key,
    required this.leading,
    required this.tracks,
    required this.playbackContext,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final shuffle = ShuffleButton(size: 26, inactiveColor: colorScheme.onSurfaceVariant);
    final play = ContextPlayButton(tracks: tracks, playbackContext: playbackContext);
    final trailing = this.trailing;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 600) {
          return Row(
            children: [
              play,
              const SizedBox(width: 20),
              shuffle,
              const SizedBox(width: 4),
              ...leading,
              const SizedBox(width: 16),
              // 占满剩余宽度并靠右：工具内部的输入框需要有界宽度
              Expanded(child: Align(alignment: Alignment.centerRight, child: trailing)),
            ],
          );
        }
        // 窄（手机竖屏）：按钮一行，工具（搜索 / 排序）单独一行铺满宽度——
        // 挤在同一行时输入框只剩几十像素（前缀 / 后缀图标都不够放），手指点不进去
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ...leading,
                const Spacer(),
                shuffle,
                const SizedBox(width: 8),
                play,
              ],
            ),
            if (trailing != null) ...[
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: trailing),
            ],
          ],
        );
      },
    );
  }
}

/// 收藏按钮（歌单 / 专辑 / 播客通用的描边爱心）。
class SaveToggleButton extends StatelessWidget {
  final bool saved;
  final VoidCallback onPressed;

  const SaveToggleButton({super.key, required this.saved, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: saved ? context.l10n.libraryRemove : context.l10n.libraryAdd,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
        child: Icon(
          saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          key: ValueKey(saved),
          size: 28,
          color: saved ? primary : null,
        ),
      ),
      onPressed: onPressed,
    );
  }
}

/// 列表为空 / 加载中的占位（Sliver）。
///
/// 加载中显示与 TrackTile 等高的骨架行，加载完成时列表不会跳动。
class CollectionPlaceholder extends StatelessWidget {
  final bool loading;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const CollectionPlaceholder({
    super.key,
    this.loading = false,
    this.message = '',
    this.icon = Icons.queue_music_rounded,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return SliverToBoxAdapter(
        child: SkeletonPulse(child: Column(children: [for (var i = 0; i < 6; i++) const _SkeletonTrackRow()])),
      );
    }
    return SliverToBoxAdapter(
      child: Center(
        child: EmptyState(icon: icon, title: message, compact: true, actionLabel: actionLabel, onAction: onAction),
      ),
    );
  }
}

/// 详情页拿不到数据时的占位（Sliver）：
/// - 未登录：说明需要登录，按钮打开登录页，登录成功后调用 [onRetry] 重新加载；
/// - 其他失败：说明检查网络，按钮直接 [onRetry]。
class CollectionErrorPlaceholder extends StatelessWidget {
  final bool signedOut;
  final VoidCallback onRetry;

  const CollectionErrorPlaceholder({super.key, required this.signedOut, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (signedOut) {
      return CollectionPlaceholder(
        message: l10n.detailSignInRequired,
        icon: Icons.lock_outline_rounded,
        actionLabel: l10n.shellSignIn,
        onAction: () async {
          if (await LoginScreen.open(context)) onRetry();
        },
      );
    }
    return CollectionPlaceholder(
      message: l10n.detailLoadFailed,
      icon: Icons.cloud_off_rounded,
      actionLabel: l10n.commonRetry,
      onAction: onRetry,
    );
  }
}

class _SkeletonTrackRow extends StatelessWidget {
  const _SkeletonTrackRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SkeletonBox(width: 48, height: 48, borderRadius: BorderRadius.all(Radius.circular(6))),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(widthFactor: 0.6, alignment: Alignment.centerLeft, child: SkeletonBox(height: 13)),
                SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.35,
                  alignment: Alignment.centerLeft,
                  child: SkeletonBox(height: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
