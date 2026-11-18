import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/watch_feed.dart';
import '../../../../providers/library_provider.dart';
import '../../../../services/watchfeed/preview_player.dart';
import '../../../widgets/track_menu.dart';
import 'desktop_watch_feed_source.dart';

/// 右栏：顶部静音 + 关闭；中间更多 / 复制链接 / 加入队列 / 保存；底部上一首 / 下一首。
class DesktopWatchFeedRightColumn extends StatelessWidget {
  const DesktopWatchFeedRightColumn({
    super.key,
    required this.item,
    required this.size,
    required this.canPrevious,
    required this.canNext,
    required this.interacted,
    required this.onClose,
    required this.onPrevious,
    required this.onNext,
    required this.onToggleSave,
    required this.onAddToQueue,
    required this.onCopyLink,
  });

  final WatchFeedItem item;
  final DesktopWatchFeedSize size;
  final bool canPrevious;
  final bool canNext;
  final bool interacted;
  final VoidCallback onClose;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToggleSave;
  final VoidCallback onAddToQueue;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final track = item.playableTrack;
    final muted = context.select<WatchFeedPreviewPlayer, bool>((p) => p.muted);
    final playing = context.select<WatchFeedPreviewPlayer, bool>(
      (p) => p.isPlaying,
    );
    final saved = context.select<LibraryProvider?, bool>(
      (l) => track != null && (l?.isLiked(track.id) ?? false),
    );
    final stackGap = size == DesktopWatchFeedSize.small ? 32.0 : 48.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 窄档（右栏内宽只有 54）放不下两个按钮时折成两行。
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            _TertiaryButton(
              key: const Key('desktop-watch-feed-mute'),
              tooltip: muted ? l10n.watchFeedUnmute : l10n.watchFeedMute,
              onPressed: () =>
                  context.read<WatchFeedPreviewPlayer>().setMuted(!muted),
              child: muted
                  ? const Icon(Icons.volume_off_rounded, size: 20)
                  : _MiniEqualizer(playing: playing),
            ),
            _TertiaryButton(
              key: const Key('desktop-watch-feed-close'),
              tooltip: l10n.commonClose,
              onPressed: onClose,
              child: const Icon(Icons.close_rounded, size: 22),
            ),
          ],
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (track != null)
              Builder(
                builder: (buttonContext) => _TertiaryButton(
                  key: const Key('desktop-watch-feed-more'),
                  tooltip: l10n.commonMoreOptions,
                  onPressed: () => TrackMenu.show(buttonContext, track),
                  child: const Icon(Icons.more_horiz_rounded, size: 24),
                ),
              ),
            SizedBox(height: stackGap / 3),
            _TertiaryButton(
              tooltip: l10n.shareCopyLink,
              onPressed: onCopyLink,
              child: const Icon(Icons.link_rounded, size: 22),
            ),
            SizedBox(height: stackGap / 3),
            _TertiaryButton(
              tooltip: l10n.trackAddToQueue,
              onPressed: onAddToQueue,
              child: const Icon(Icons.queue_music_rounded, size: 22),
            ),
            SizedBox(height: stackGap / 3),
            _TertiaryButton(
              key: const Key('desktop-watch-feed-save'),
              tooltip: saved ? l10n.likeRemove : l10n.likeAdd,
              onPressed: onToggleSave,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: Icon(
                  saved
                      ? Icons.check_circle_rounded
                      : Icons.add_circle_outline_rounded,
                  key: ValueKey(saved),
                  size: 26,
                  color: saved ? const Color(0xFF1ED760) : Colors.white,
                ),
              ),
            ),
          ],
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (canPrevious) ...[
              _TertiaryButton(
                key: const Key('desktop-watch-feed-previous'),
                tooltip: l10n.playerPrevious,
                onPressed: onPrevious,
                child: const Icon(Icons.keyboard_arrow_up_rounded, size: 28),
              ),
              const SizedBox(height: 8),
            ],
            // 首次翻页前的「下一首」胶囊浮在对话框右下角（见 _buildRow），这里不重复放。
            if (interacted || !canNext)
              _TertiaryButton(
                key: const Key('desktop-watch-feed-next'),
                tooltip: l10n.playerNext,
                onPressed: canNext ? onNext : null,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: size == DesktopWatchFeedSize.small ? 24 : 28,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Encore 三级按钮：无底色，图标 #B3B3B3，悬停变白并加 30% 白底圆。
class _TertiaryButton extends StatelessWidget {
  const _TertiaryButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      // Encore 三级图标按钮：36×36，比 Material 默认的 48 紧凑（右栏最窄只有 54 宽）。
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0x4DFFFFFF)
              : states.contains(WidgetState.hovered)
              ? Colors.white
              : const Color(0xFFB3B3B3),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? const Color(0x1AFFFFFF)
              : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      icon: child,
    );
  }
}

/// 首次翻页前的「下一首」白色胶囊：带向下箭头，0.8s 上下跳动并在白色 / 60% 白之间呼吸，悬停停住。
class DesktopWatchFeedNextPill extends StatefulWidget {
  const DesktopWatchFeedNextPill({
    super.key,
    required this.label,
    required this.onPressed,
    this.large = true,
  });

  final String label;
  final VoidCallback onPressed;

  /// 中 / 大档：高 48、字号 16；小档：高 40、字号 14。
  final bool large;

  @override
  State<DesktopWatchFeedNextPill> createState() =>
      _DesktopWatchFeedNextPillState();
}

class _DesktopWatchFeedNextPillState extends State<DesktopWatchFeedNextPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !MediaQuery.disableAnimationsOf(context)) {
        _bounce.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _bounce,
      curve: const Cubic(0.58, 0, 0.43, 1),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        _bounce.stop();
      },
      onExit: (_) {
        setState(() => _hover = false);
        if (!MediaQuery.disableAnimationsOf(context)) {
          _bounce.repeat(reverse: true);
        }
      },
      child: GestureDetector(
        key: const Key('desktop-watch-feed-next-pill'),
        onTap: widget.onPressed,
        child: AnimatedBuilder(
          animation: curve,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, _hover ? 0 : -8 * curve.value),
            child: Container(
              height: widget.large ? 48 : 40,
              padding: EdgeInsets.symmetric(horizontal: widget.large ? 24 : 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover
                    ? Colors.white
                    : Color.lerp(
                        const Color(0xFFFFFFFF),
                        const Color(0x99FFFFFF),
                        curve.value,
                      ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x4D000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: child,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                    fontSize: widget.large ? 16 : 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_downward_rounded,
                size: widget.large ? 20 : 18,
                color: Colors.black,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 静音按钮里的小均衡器（官方是一张白色动图）：三根竖条，播放时跳动。
class _MiniEqualizer extends StatefulWidget {
  const _MiniEqualizer({required this.playing});

  final bool playing;

  @override
  State<_MiniEqualizer> createState() => _MiniEqualizerState();
}

class _MiniEqualizerState extends State<_MiniEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _MiniEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.playing) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.white;
    return SizedBox.square(
      dimension: 20,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                height:
                    4 +
                    12 *
                        (widget.playing
                            ? (0.5 -
                                  0.5 *
                                      math.cos(
                                        (_c.value + i * 0.3) * 2 * math.pi,
                                      ))
                            : 0.3),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
