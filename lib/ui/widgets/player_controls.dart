import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/playback_state.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';

// 播放器通用控件。每个控件只 select 自己关心的状态，
// 例如切换随机播放不会让播放按钮、封面、歌名等重建。

/// 圆形 播放/暂停 按钮；缓冲中显示加载环。
class PlayPauseButton extends StatelessWidget {
  final double size;
  final double iconSize;
  final Color background;
  final Color foreground;
  final Duration backgroundAnimationDuration;

  const PlayPauseButton({
    super.key,
    this.size = 60,
    this.iconSize = 34,
    this.background = Colors.white,
    this.foreground = Colors.black,
    this.backgroundAnimationDuration = kThemeChangeDuration,
  });

  @override
  Widget build(BuildContext context) {
    final (isPlaying, isBuffering) =
        context.select<PlaybackProvider, (bool, bool)>((p) => (p.isPlaying, p.isBuffering));

    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: background,
        animationDuration: backgroundAnimationDuration,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          onTap: () => context.read<PlaybackProvider>().togglePlayPause(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isBuffering)
                SizedBox(
                  width: size - 8,
                  height: size - 8,
                  child: CircularProgressIndicator(strokeWidth: 2, color: foreground.withAlpha(90)),
                ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  key: ValueKey(isPlaying),
                  color: foreground,
                  size: iconSize,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ShuffleButton extends StatelessWidget {
  final double size;
  final Color inactiveColor;
  final BoxConstraints? constraints;

  const ShuffleButton({super.key, this.size = 24, this.inactiveColor = Colors.white60, this.constraints});

  @override
  Widget build(BuildContext context) {
    final shuffle = context.select<PlaybackProvider, bool>((p) => p.shuffle);
    final primary = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: shuffle ? context.l10n.playerShuffleOff : context.l10n.playerShuffleOn,
      constraints: constraints,
      padding: constraints != null ? EdgeInsets.zero : null,
      icon: _ActiveDot(
        active: shuffle,
        color: primary,
        child: Icon(Icons.shuffle_rounded, size: size, color: shuffle ? primary : inactiveColor),
      ),
      onPressed: () => context.read<PlaybackProvider>().toggleShuffle(),
    );
  }
}

class RepeatButton extends StatelessWidget {
  final double size;
  final Color inactiveColor;
  final BoxConstraints? constraints;

  const RepeatButton({super.key, this.size = 24, this.inactiveColor = Colors.white60, this.constraints});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<PlaybackProvider, SpotifyRepeatMode>((p) => p.repeatMode);
    final primary = Theme.of(context).colorScheme.primary;
    final active = mode != SpotifyRepeatMode.off;
    return IconButton(
      tooltip: switch (mode) {
        SpotifyRepeatMode.off => context.l10n.playerRepeatOn,
        SpotifyRepeatMode.context => context.l10n.playerRepeatOneOn,
        SpotifyRepeatMode.track => context.l10n.playerRepeatOff,
      },
      constraints: constraints,
      padding: constraints != null ? EdgeInsets.zero : null,
      icon: _ActiveDot(
        active: active,
        color: primary,
        child: Icon(
          mode == SpotifyRepeatMode.track ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          size: size,
          color: active ? primary : inactiveColor,
        ),
      ),
      onPressed: () => context.read<PlaybackProvider>().cycleRepeatMode(),
    );
  }
}

/// 上一首 / 下一首。
class SkipButton extends StatelessWidget {
  final bool next;
  final double size;
  final Color color;
  final BoxConstraints? constraints;

  const SkipButton({super.key, required this.next, this.size = 34, this.color = Colors.white, this.constraints});

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    return IconButton(
      tooltip: next ? context.l10n.playerNext : context.l10n.playerPrevious,
      constraints: constraints,
      padding: constraints != null ? EdgeInsets.zero : null,
      icon: Icon(next ? Icons.skip_next_rounded : Icons.skip_previous_rounded, size: size, color: color),
      onPressed: next ? playback.nextTrack : playback.previousTrack,
    );
  }
}

/// 点赞按钮（订阅 LibraryProvider 中单首歌的状态）。
class LikeButton extends StatelessWidget {
  final SpotifyTrack track;
  final double size;
  final Color inactiveColor;

  const LikeButton({super.key, required this.track, this.size = 24, this.inactiveColor = Colors.white});

  @override
  Widget build(BuildContext context) {
    final liked = context.select<LibraryProvider, bool>((l) => l.isLiked(track.id));
    final primary = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: liked ? context.l10n.likeRemove : context.l10n.likeAdd,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
        child: Icon(
          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          key: ValueKey(liked),
          size: size,
          color: liked ? primary : inactiveColor,
        ),
      ),
      onPressed: () => context.read<LibraryProvider>().toggleLike(track),
    );
  }
}

/// Spotify 风格：激活状态的按钮下方带一个小圆点。
class _ActiveDot extends StatelessWidget {
  final bool active;
  final Color color;
  final Widget child;

  const _ActiveDot({required this.active, required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        child,
        if (active)
          Positioned(
            bottom: -6,
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
      ],
    );
  }
}
