import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playback_context.dart';
import '../../../models/track.dart';
import '../../../providers/connect_provider.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/connect/remote_progress.dart';
import '../../widgets/connect/remote_transport_controls.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/liquid_glass.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/playback_scrubber.dart';
import '../../widgets/player_controls.dart';
import '../../widgets/text_metrics.dart';
import '../../widgets/track_menu.dart';
import 'device_picker_sheet.dart';
import 'player_lyrics_motion.dart';

/// 中间区域显示的内容。
enum PlayerView { artwork, lyrics, queue }

/// 歌名 + 进度条 + 播放控件；歌词视图下收进一块液态玻璃，歌词可从其上方滚过时仍清晰可读。
class PlayerSceneControlsGroup extends StatelessWidget {
  final SpotifyTrack track;
  final bool glass;
  final bool remote;
  final bool showTitle;
  final double? lyricsProgress;
  final Widget? footer;

  const PlayerSceneControlsGroup({
    required this.track,
    required this.glass,
    required this.remote,
    this.showTitle = true,
    this.lyricsProgress,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final compactness = lyricsProgress ?? 0.0;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle) PlayerSceneTitleRow(track: track),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: lerpDouble(16, 4, compactness)!,
          ),
          child: remote
              ? RemoteScrubber(
                  compact: false,
                  compactProgress: lyricsProgress,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  labelColor: Colors.white60,
                )
              : PlaybackScrubber(
                  compactProgress: lyricsProgress,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  labelColor: Colors.white60,
                ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: lerpDouble(20, 8, compactness)!,
          ),
          child: remote
              ? const RemoteTransportControls(
                  showModes: true,
                  style: RemoteControlsStyle.glassFull,
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const ShuffleButton(),
                    const SkipButton(next: false),
                    PlayPauseButton(
                      size: lerpDouble(60, 52, compactness)!,
                      iconSize: lerpDouble(34, 44, compactness)!,
                      background: Colors.white.withValues(
                        alpha: 1 - compactness,
                      ),
                      foreground: Color.lerp(
                        Colors.black,
                        Colors.white,
                        compactness,
                      )!,
                      backgroundAnimationDuration: lyricsProgress == null
                          ? kThemeChangeDuration
                          : Duration.zero,
                    ),
                    const SkipButton(next: true),
                    const RepeatButton(),
                  ],
                ),
        ),
        if (footer != null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: lerpDouble(16, 4, compactness)!,
            ),
            child: footer,
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
    if (!glass) return content;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: LiquidGlass(
        borderRadius: context.tokens.radius(28),
        child: content,
      ),
    );
  }
}

/// 在系统 / 用户的文字缩放之上再叠加展开放大（而不是覆盖它）。
class PlayerSceneExpandScale extends StatelessWidget {
  final ValueListenable<double> scale;
  final double gain;
  final Widget child;

  const PlayerSceneExpandScale({
    required this.scale,
    required this.gain,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: scale,
    child: child,
    builder: (context, v, child) {
      final media = MediaQuery.of(context);
      final base = media.textScaler.scale(100) / 100;
      return MediaQuery(
        data: media.copyWith(
          textScaler: TextScaler.linear(base * (1 + gain * v)),
        ),
        child: child!,
      );
    },
  );
}

class PlayerSceneTopBar extends StatelessWidget {
  final SpotifyTrack track;
  final PlaybackContext playbackContext;
  final VoidCallback onConnect;
  final Widget? pin;

  const PlayerSceneTopBar({
    required this.track,
    required this.playbackContext,
    required this.onConnect,
    this.pin,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
            color: Colors.white,
            tooltip: context.l10n.commonClose,
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  context.l10n.playingFrom(playbackContext),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: Colors.white.withAlpha(180),
                  ),
                ),
                if (!playbackContext.isNone) ...[
                  const SizedBox(height: 2),
                  Text(
                    playbackContext.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          ?pin,
          Builder(
            // 独立 context：桌面对话框中菜单锚定在按钮下方
            builder: (buttonContext) => IconButton(
              icon: const Icon(Icons.more_vert_rounded, size: 22),
              color: Colors.white,
              tooltip: context.l10n.commonMoreOptions,
              onPressed: () =>
                  TrackMenu.show(buttonContext, track, onConnect: onConnect),
            ),
          ),
        ],
      ),
    );
  }
}

class PlayerSceneTitleRow extends StatelessWidget {
  final SpotifyTrack track;
  final bool compact;
  final double lyricsProgress;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// 展开放大进度：只放大歌名 / 歌手文字，不影响按钮 tooltip。
  final ValueListenable<double>? textScale;
  final double textScaleGain;

  const PlayerSceneTitleRow({
    required this.track,
    this.compact = false,
    this.lyricsProgress = 0,
    this.onTap,
    this.trailing,
    this.textScale,
    this.textScaleGain = 0.14,
  });

  @override
  Widget build(BuildContext context) {
    Widget buildTitle(BuildContext context) {
      final theme = Theme.of(context);
      final titleStyle =
          theme.textTheme.titleLarge ?? const TextStyle(fontSize: 22);
      final baseSize = titleStyle.fontSize ?? 22;
      final titleSize = baseSize * (1 - 0.35 * lyricsProgress);
      final artist = Text(
        track.artistNames,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.white70,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reserve the unscaled line's measured height. Static text and the
          // marquee can use different line boxes, especially with large text.
          SizedBox(
            height: compact
                ? TextMetrics.lineHeight(
                    context,
                    titleStyle.copyWith(fontWeight: FontWeight.w600),
                  )
                : null,
            child: Align(
              alignment: Alignment.centerLeft,
              heightFactor: 1,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: compact
                    ? PlayerLyricsMotion.curve
                    : Curves.linear,
                switchOutCurve: compact
                    ? PlayerLyricsMotion.curve
                    : Curves.linear,
                child: MarqueeText(
                  text: track.name,
                  key: ValueKey(track.id),
                  style: titleStyle.copyWith(
                    fontSize: compact ? titleSize : null,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          MouseRegion(
            cursor: onTap == null && track.artists.isNotEmpty
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            child: GestureDetector(
              onTap: onTap != null || track.artists.isEmpty
                  ? null
                  : () => AppRoutes.openArtist(context, track.artists.first),
              child: artist,
            ),
          ),
        ],
      );
    }

    final title = textScale == null
        ? Builder(builder: buildTitle)
        : PlayerSceneExpandScale(
            scale: textScale!,
            gain: textScaleGain,
            child: Builder(builder: buildTitle),
          );
    return Padding(
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(24, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: compact
                ? Semantics(
                    button: onTap != null,
                    child: InkWell(
                      key: const ValueKey('player-card-title'),
                      onTap: onTap,
                      canRequestFocus: onTap != null,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          heightFactor: 1,
                          child: title,
                        ),
                      ),
                    ),
                  )
                : title,
          ),
          LikeButton(track: track, size: 28),
          ?trailing,
        ],
      ),
    );
  }
}

/// 底栏：Connect 设备 + 歌词 / 队列视图切换（当前视图高亮并带小圆点）。
class PlayerSceneBottomBar extends StatelessWidget {
  final PlayerView view;
  final ValueChanged<PlayerView> onToggle;
  final double? lyricsProgress;
  final Widget? translation;
  final Widget? pin;
  /// 非空时设备入口在卡片底部就地展开设备列表，而不是弹出浮层。
  final ValueNotifier<bool>? devicesOpen;

  const PlayerSceneBottomBar({
    required this.view,
    required this.onToggle,
    this.lyricsProgress,
    this.translation,
    this.pin,
    this.devicesOpen,
  });

  @override
  Widget build(BuildContext context) {
    final deviceName = context.select<ConnectProvider?, String?>(
      (c) => (c?.hasRemoteSession ?? false) ? c?.activeDevice?.name : null,
    );
    final primary = Theme.of(context).colorScheme.primary;
    final deviceColor = deviceName != null ? primary : Colors.white70;

    Widget toggle(PlayerView target, IconData icon, String tooltip) {
      final active = view == target;
      return IconButton(
        tooltip: tooltip,
        isSelected: active,
        onPressed: () => onToggle(target),
        icon: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Icon(icon, color: active ? primary : Colors.white70, size: 22),
            if (active)
              Positioned(
                bottom: -7,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    final bar = Padding(
      padding: EdgeInsets.lerp(
        const EdgeInsets.fromLTRB(20, 4, 12, 8),
        const EdgeInsets.symmetric(horizontal: 8),
        lyricsProgress ?? 0,
      )!,
      child: Row(
        children: [
          Expanded(
            // Only the icon/label is a device action. The remaining footer
            // space belongs to the scene's card-reveal gesture.
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              // 设备入口做成小胶囊按钮，文字缩小以便在窄卡片里放下
              child: InkWell(
                borderRadius: context.tokens.pill,
                mouseCursor: SystemMouseCursors.click,
                onTap: devicesOpen == null
                    ? () => DevicePickerSheet.show(context)
                    : () {
                        context.read<ConnectProvider?>()?.refresh();
                        devicesOpen!.value = !devicesOpen!.value;
                      },
                child: ConstrainedBox(
                  // 点击区域保持 48 高，视觉上只是个小胶囊
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        borderRadius: context.tokens.pill,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6.0,
                          horizontal: 10.0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.devices_rounded,
                              size: 14,
                              color: deviceColor,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                deviceName ?? context.l10n.playerThisDevice,
                                style: TextStyle(
                                  color: deviceColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 10,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          ?pin,
          ?translation,
          toggle(
            PlayerView.lyrics,
            Icons.lyrics_outlined,
            context.l10n.lyricsTitle,
          ),
          toggle(
            PlayerView.queue,
            Icons.queue_music_rounded,
            context.l10n.queueTitle,
          ),
        ],
      ),
    );
    final open = devicesOpen;
    if (open == null) return bar;
    return ValueListenableBuilder<bool>(
      valueListenable: open,
      child: bar,
      builder: (context, isOpen, bar) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bar!,
          // 设备列表放在底栏下面，正好对应左下角的「正在本设备收听」按钮
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: isOpen
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: InlineDevicePanel(onClose: () => open.value = false),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// 底栏里的「固定控制区」开关：固定后控制卡片不再因静止收起成底部迷你栏。
class PlayerScenePinButton extends StatelessWidget {
  final bool pinned;
  final ValueChanged<bool> onChanged;

  const PlayerScenePinButton({required this.pinned, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: pinned
          ? context.l10n.lyricsUnpinControls
          : context.l10n.lyricsPinControls,
      isSelected: pinned,
      onPressed: () => onChanged(!pinned),
      icon: Icon(
        pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        color: pinned ? primary : Colors.white70,
        size: 22,
      ),
    );
  }
}

/// 控制区收起后留在底部的迷你栏（仅横屏）：封面、歌名 / 歌手、喜欢、设备（畅联）、播放暂停、下一首。
class PlayerSceneMiniBar extends StatelessWidget {
  final SpotifyTrack track;
  final bool remote;
  final VoidCallback onDevices;

  const PlayerSceneMiniBar({
    required this.track,
    required this.remote,
    required this.onDevices,
  });

  static const _remoteStyle = RemoteControlsStyle(
    foreground: Colors.white,
    muted: Colors.white60,
    playBackground: Colors.white,
    playForeground: Colors.black,
    skipSize: 24,
    playSize: 34,
    playIconSize: 20,
    gap: 0,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceActive = context.select<ConnectProvider?, bool>(
      (c) => c?.hasRemoteSession ?? false,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          CoverImage(
            url: track.coverUrl,
            size: 34,
            borderRadius: BorderRadius.circular(7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  track.artistNames,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          LikeButton(track: track, size: 20),
          IconButton(
            tooltip: context.l10n.deviceConnectShort,
            visualDensity: VisualDensity.compact,
            onPressed: onDevices,
            icon: Icon(
              Icons.devices_rounded,
              size: 19,
              color: deviceActive ? theme.colorScheme.primary : Colors.white70,
            ),
          ),
          if (remote)
            const RemoteTransportControls(showModes: false, style: _remoteStyle)
          else ...[
            const PlayPauseButton(size: 34, iconSize: 20),
            const SkipButton(
              next: true,
              size: 24,
              constraints: BoxConstraints.tightFor(width: 32, height: 32),
            ),
          ],
        ],
      ),
    );
  }
}
