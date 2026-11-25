import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/md3e_colors.dart';
import '../../l10n/l10n.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/preferences_provider.dart';
import '../shell/shell_breakpoints.dart';
import 'toast/app_toast.dart';

/// 歌单 / 专辑曲目行的滑动手势（设置页「自定义功能」开启后生效，只在手机布局）：
/// 右滑「下个播放」，左滑加入音乐库（已在库中则移出），两者都同步到 Spotify 账号。
///
/// [trailingOverride] 替换左滑操作（自建歌单的左滑仍是移出歌单）。
/// 两个开关都关闭、桌面布局或 [enabled] 为 false 时原样返回 [child]。
class TrackSwipeGestures extends StatelessWidget {
  final SpotifyTrack track;
  final Widget child;
  final bool enabled;
  final TrackSwipeAction? trailingOverride;

  const TrackSwipeGestures({
    super.key,
    required this.track,
    required this.child,
    this.enabled = true,
    this.trailingOverride,
  });

  /// 当前是否会给曲目行加滑动手势（调用方据此决定是否保留旧的 Dismissible）。
  static bool active(BuildContext context) {
    final (
      playNext,
      library,
    ) = context.select<PreferencesProvider?, (bool, bool)>(
      (p) =>
          (p?.prefs.swipeToPlayNext ?? false, p?.prefs.swipeToLibrary ?? false),
    );
    return (playNext || library) &&
        !ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
  }

  @override
  Widget build(BuildContext context) {
    final (
      playNext,
      library,
    ) = context.select<PreferencesProvider?, (bool, bool)>(
      (p) =>
          (p?.prefs.swipeToPlayNext ?? false, p?.prefs.swipeToLibrary ?? false),
    );
    if (!enabled ||
        track.id.isEmpty ||
        ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      return child;
    }
    final saved = context.select<LibraryProvider, bool>(
      (l) => l.isLiked(track.id),
    );
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 白底上原色绿对比不足，图标改用加深版
    final green = theme.brightness == Brightness.light
        ? MD3EColors.spotifyGreenOnLight
        : MD3EColors.spotifyGreen;

    // Spotify 风格：品牌绿实心圆配黑色图标，背后一道从边缘渐隐的绿色光带
    final leading = playNext
        ? TrackSwipeAction(
            icon: Icons.playlist_play_rounded,
            iconColor: Colors.black,
            circleColor: MD3EColors.spotifyGreen,
            backgroundColor: green,
            semanticLabel: l10n.toastPlayNext,
            onTriggered: () {
              context.read<PlaybackProvider>().playNext(track);
              AppToast.show(
                context,
                l10n.toastPlayNext,
                icon: Icons.playlist_play_rounded,
                tone: ToastTone.success,
                duration: const Duration(seconds: 2),
              );
            },
          )
        : null;
    final trailing =
        trailingOverride ??
        (library
            // Spotify 的爱心：未点赞是绿色空心爱心，已点赞是绿色实心爱心（再滑即取消）
            ? TrackSwipeAction(
                icon: saved
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                iconColor: green,
                circleColor: scheme.surfaceContainerHighest,
                backgroundColor: green,
                semanticLabel: saved ? l10n.likeRemove : l10n.likeAdd,
                onTriggered: () {
                  context.read<LibraryProvider>().toggleLike(track);
                  AppToast.show(
                    context,
                    saved ? l10n.toastLikeRemoved : l10n.toastLikeAdded,
                    icon: saved
                        ? Icons.favorite_border_rounded
                        : Icons.favorite_rounded,
                    tone: ToastTone.success,
                    duration: const Duration(seconds: 2),
                  );
                },
              )
            : null);
    if (leading == null && trailing == null) return child;
    return TrackSwipeActions(
      leading: leading,
      trailing: trailing,
      child: child,
    );
  }
}

/// 曲目行左右滑动出的操作（手势参照 Apple Music，外观为 Spotify 风格）。
///
/// 行跟手滑开，露出边缘的圆形按钮：滑过一半宽度松手直接执行；只滑开一段则停在按钮宽度，
/// 再点圆形按钮执行，点行本身或往回滑收起。执行后行弹回原位。
/// [leading] 在行左侧（向右滑露出），[trailing] 在行右侧（向左滑露出），都可为 null。
class TrackSwipeActions extends StatefulWidget {
  final TrackSwipeAction? leading;
  final TrackSwipeAction? trailing;
  final Widget child;

  const TrackSwipeActions({
    super.key,
    this.leading,
    this.trailing,
    required this.child,
  });

  @override
  State<TrackSwipeActions> createState() => _TrackSwipeActionsState();
}

/// 一侧的操作：圆形按钮的图标与颜色，以及触发时的回调。
class TrackSwipeAction {
  final IconData icon;
  final Color iconColor;
  final Color circleColor;

  /// 露出区域的光带颜色：从行边缘向内渐隐，滑到可触发时加深；为 null 时透明。
  final Color? backgroundColor;
  final String semanticLabel;
  final VoidCallback onTriggered;

  const TrackSwipeAction({
    required this.icon,
    required this.iconColor,
    required this.circleColor,
    this.backgroundColor,
    required this.semanticLabel,
    required this.onTriggered,
  });
}

class _TrackSwipeActionsState extends State<TrackSwipeActions>
    with SingleTickerProviderStateMixin {
  static const double _circle = 44;

  /// 停留展开时露出的宽度（圆形按钮 + 两侧留白）。
  static const double _revealExtent = 76;

  late final AnimationController _settle = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => setState(() => _dx = _settle.value));

  double _dx = 0;
  double _width = 1;
  bool _armed = false;

  double get _triggerExtent => (_width * 0.5).clamp(_revealExtent + 24, 400);

  TrackSwipeAction? get _active => _dx > 0
      ? widget.leading
      : _dx < 0
      ? widget.trailing
      : null;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails d) {
    _settle.stop();
    var next = _dx + d.primaryDelta!;
    if (widget.leading == null && next > 0) next = 0;
    if (widget.trailing == null && next < 0) next = 0;
    // 越过触发点后阻尼，提示已经可以松手
    final limit = _triggerExtent;
    if (next.abs() > limit) {
      next = next.sign * (limit + (next.abs() - limit) * 0.35);
    }
    final armed = next.abs() >= limit;
    if (armed != _armed) HapticFeedback.mediumImpact();
    setState(() {
      _dx = next;
      _armed = armed;
    });
  }

  void _onEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final action = _active;
    if (action == null) return _animateTo(0);
    final flung = v.abs() > 1200 && v.sign == _dx.sign;
    if (_armed || flung) {
      _fire(action);
    } else if (_dx.abs() >= _revealExtent / 2) {
      _animateTo(_dx.sign * _revealExtent);
    } else {
      _animateTo(0);
    }
  }

  void _fire(TrackSwipeAction action) {
    _armed = false;
    action.onTriggered();
    _animateTo(0);
  }

  void _animateTo(double target) {
    _settle.value = _dx;
    _settle
        .animateWith(
          SpringSimulation(
            const SpringDescription(mass: 1, stiffness: 420, damping: 36),
            _dx,
            target,
            0,
          ),
        )
        // 弹簧停在容差内而非精确值：收尾对齐，回到 0 时才能卸掉背景、恢复点按
        .whenCompleteOrCancel(() {
          if (mounted && !_settle.isAnimating && (_dx - target).abs() < 1) {
            setState(() => _dx = target);
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    final action = _active;
    final open = _dx != 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _onUpdate,
          onHorizontalDragEnd: _onEnd,
          onHorizontalDragCancel: () => _animateTo(0),
          child: Stack(
            children: [
              if (action != null)
                Positioned.fill(child: _background(context, action)),
              Transform.translate(
                offset: Offset(_dx, 0),
                child: open
                    ? Stack(
                        children: [
                          // 展开时点行先收起，不触发播放
                          IgnorePointer(child: widget.child),
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _animateTo(0),
                            ),
                          ),
                        ],
                      )
                    : widget.child,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _background(BuildContext context, TrackSwipeAction action) {
    final leading = _dx > 0;
    final extent = _dx.abs();
    // 圆形按钮跟着露出的宽度长大，到停留宽度时为完整大小
    final grow = (extent / _revealExtent).clamp(0.0, 1.0);
    final scale = _armed ? 1.12 : 0.6 + 0.4 * grow;
    final circle = Semantics(
      button: true,
      label: action.semanticLabel,
      child: GestureDetector(
        onTap: () => _fire(action),
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 120),
          child: Container(
            width: _circle,
            height: _circle,
            decoration: BoxDecoration(
              color: action.circleColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(action.icon, color: action.iconColor, size: 24),
          ),
        ),
      ),
    );
    return Align(
      alignment: leading ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: extent,
            decoration: _glow(action.backgroundColor, leading),
            alignment: Alignment.center,
            child: OverflowBox(
              maxWidth: double.infinity,
              child: Opacity(opacity: grow, child: circle),
            ),
          ),
        ),
      ),
    );
  }

  /// 行边缘最浓、向内渐隐的光带；越过触发点时整体加深，提示松手即执行。
  BoxDecoration? _glow(Color? color, bool leading) {
    if (color == null) return null;
    final edge = _armed ? 0.55 : 0.32;
    final inner = _armed ? 0.22 : 0.06;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: leading ? Alignment.centerLeft : Alignment.centerRight,
        end: leading ? Alignment.centerRight : Alignment.centerLeft,
        colors: [
          color.withValues(alpha: edge),
          color.withValues(alpha: inner),
        ],
      ),
    );
  }
}
