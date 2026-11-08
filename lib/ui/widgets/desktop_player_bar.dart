import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/track.dart';
import '../../providers/connect_provider.dart';
import '../../providers/playback_provider.dart';
import '../navigation/app_routes.dart';
import '../screens/player/device_picker_sheet.dart';
import '../../core/theme/flutify_tokens.dart';
import '../screens/player/full_player_sheet.dart';
import '../screens/player/immersive_lyrics_screen.dart';
import '../screens/player/queue_sheet.dart';
import '../shell/shell_layout_controller.dart';
import 'connect/connect_actions.dart';
import 'connect/remote_player_bar.dart';
import 'liquid_glass.dart';
import 'marquee_text.dart';
import 'playback_scrubber.dart';
import 'playback_status_button.dart';
import 'player_bar_cover.dart';
import 'sleep_timer/sleep_timer_indicator.dart';
import 'player_controls.dart';

/// 桌面端底部悬浮播放器：iOS 液态玻璃风格的悬浮胶囊。
///
/// 配合 `Scaffold(extendBody: true)` 使用：三栏内容铺到窗口底部，
/// 胶囊透过模糊看到身后的内容；占位总高（[reservedHeight]）经
/// MediaQuery 底部 padding 传给页面（见 ContentBottomSpacer）。
///
/// 本组件只在切歌时重建；控制按钮、进度条、音量各自局部订阅。
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({super.key});

  /// 玻璃胶囊高度与四周留白；总占位 = 胶囊 + 上间隙 + 下边距。
  static const double capsuleHeight = 90;
  static const double marginTop = 6;
  static const double marginBottom = 12;
  static const double marginSide = 16;
  static const double reservedHeight = capsuleHeight + marginTop + marginBottom;

  @override
  Widget build(BuildContext context) {
    // 正在遥控其他设备时整条换成远程播放栏
    if (ConnectActions.showRemote(context)) return const RemotePlayerBar();
    final colorScheme = Theme.of(context).colorScheme;
    final track = context.select<PlaybackProvider, SpotifyTrack?>(
      (p) => p.currentTrack,
    );

    // 无曲目时保留同样的悬浮胶囊并显示占位，避免内容区高度跳变
    if (track == null) {
      return const PlayerBarGlassCapsule(child: _IdleBar());
    }

    return PlayerBarGlassCapsule(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final sideWidth = (totalWidth * 0.28).clamp(160.0, 300.0);

          return Row(
            children: [
              SizedBox(
                width: sideWidth,
                child: _NowPlayingInfo(track: track),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ShuffleButton(
                              size: 18,
                              inactiveColor: colorScheme.onSurfaceVariant,
                              constraints: _small,
                            ),
                            const SizedBox(width: 8),
                            SkipButton(
                              next: false,
                              size: 22,
                              color: colorScheme.onSurface,
                              constraints: _small,
                            ),
                            const SizedBox(width: 10),
                            // 深色：白底黑图标；浅色：黑底白图标
                            PlayPauseButton(
                              size: 36,
                              iconSize: 22,
                              background: colorScheme.onSurface,
                              foreground: colorScheme.surface,
                            ),
                            const SizedBox(width: 10),
                            SkipButton(
                              next: true,
                              size: 22,
                              color: colorScheme.onSurface,
                              constraints: _small,
                            ),
                            const SizedBox(width: 8),
                            RepeatButton(
                              size: 18,
                              inactiveColor: colorScheme.onSurfaceVariant,
                              constraints: _small,
                            ),
                          ],
                        ),
                        const PlaybackScrubber(compact: true),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(width: sideWidth, child: const _RightControls()),
            ],
          );
        },
      ),
    );
  }

  static const BoxConstraints _small = BoxConstraints(
    minWidth: 32,
    minHeight: 32,
  );
}

/// 桌面播放栏的悬浮液态玻璃胶囊（本机 / 远程两种播放栏共用）。
///
/// 三层观感：柔和投影（浮起）→ 背景模糊 + 提饱和（[LiquidGlass]）→
/// 极淡的表面色填充（保证文字在繁杂内容上可读）。模糊与不透明度跟随设置页「液态玻璃」。
/// [attachment]（如 Connect「正在 X 上播放」小条）包裹住胶囊底部：
/// 与胶囊同宽，顶部两角沿胶囊底角的圆弧上卷（见 AttachedStripShape）。
class PlayerBarGlassCapsule extends StatelessWidget {
  final Widget child;

  /// 包裹胶囊底部的挂件（[AttachedStripShape]），为空时胶囊只有主体高度。
  /// 挂件高度 = [attachmentVisibleHeight] + 胶囊圆角（上卷部分与胶囊重叠）。
  final Widget? attachment;

  /// 挂件露出在胶囊底缘以下的高度。
  final double attachmentVisibleHeight;

  const PlayerBarGlassCapsule({
    super.key,
    required this.child,
    this.attachment,
    this.attachmentVisibleHeight = 0,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DesktopPlayerBar.marginSide,
        DesktopPlayerBar.marginTop,
        DesktopPlayerBar.marginSide,
        DesktopPlayerBar.marginBottom,
      ),
      child: Builder(
        builder: (context) {
          final hyper = tokens.hyperMaterial;
          final corner = tokens.corner(28);
          // 在 hyperMaterial 模式下，移除外层实体黑影，改用 HyperBlendSurface 自带的 ViewShadow(hollow: true)，
          // 避免 BackdropFilter 把纯黑投影模糊进玻璃体导致发灰变脏
          final shadow = hyper
              ? null
              : BoxDecoration(
                  borderRadius: tokens.radius(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(isDark ? 70 : 36),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                );
          final barContent = SizedBox(
            height: DesktopPlayerBar.capsuleHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: child,
            ),
          );
          // 在 hyperMaterial 模式下，移除多余的深色底色垫层，恢复纯净通透与晶莹漫反射发丝描边
          final glassChild = hyper
              ? barContent
              : ColoredBox(
                  color: colorScheme.surfaceContainerLowest.withAlpha(
                    isDark ? 72 : 104,
                  ),
                  child: barContent,
                );
          final glass = LiquidGlass(
            borderRadius: tokens.radius(28),
            child: glassChild,
          );
          if (attachment == null) {
            return shadow == null
                ? glass
                : DecoratedBox(decoration: shadow, child: glass);
          }
          // 挂件与胶囊同宽，上卷部分（一个圆角高）叠在胶囊底角之上，露出部分占底部；
          // 投影包裹整个「胶囊 + 底座」组合，避免胶囊自己的阴影落在衔接缝上
          final body = Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: attachmentVisibleHeight),
                child: glass,
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: attachmentVisibleHeight + corner,
                child: attachment!,
              ),
            ],
          );
          return shadow == null
              ? body
              : DecoratedBox(decoration: shadow, child: body);
        },
      ),
    );
  }
}

/// 包裹胶囊底部的小条形状：与胶囊同宽，顶部两角沿胶囊底角的圆弧上卷，
/// 底部两角为与胶囊相同的圆角——像给胶囊底部套了一圈底座。
///
/// 小条高度 = 露出高度 + [cornerRadius]（上卷部分与胶囊重叠）；
/// 内容应放在底部「露出高度」区域内（见 RemotePlayingStrip）。
class AttachedStripShape extends OutlinedBorder {
  /// 胶囊的圆角半径（上卷弧度与底部圆角都与之一致）。
  final double cornerRadius;

  const AttachedStripShape({required this.cornerRadius});

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    const pi = 3.141592653589793;
    final c = cornerRadius;
    return Path()
      // 左上：从左上角尖沿胶囊底角圆弧下卷到 (left+c, top+c)
      ..moveTo(rect.left, rect.top)
      ..arcTo(Rect.fromCircle(center: Offset(rect.left + c, rect.top), radius: c), pi, -pi / 2, false)
      // 中段顶边：贴在胶囊底缘
      ..lineTo(rect.right - c, rect.top + c)
      // 右上：沿胶囊底角圆弧上卷到右上角尖
      ..arcTo(Rect.fromCircle(center: Offset(rect.right - c, rect.top), radius: c), pi / 2, -pi / 2, false)
      ..lineTo(rect.right, rect.bottom - c)
      // 右下外圆角
      ..arcTo(Rect.fromCircle(center: Offset(rect.right - c, rect.bottom - c), radius: c), 0, pi / 2, false)
      ..lineTo(rect.left + c, rect.bottom)
      // 左下外圆角
      ..arcTo(Rect.fromCircle(center: Offset(rect.left + c, rect.bottom - c), radius: c), pi / 2, pi / 2, false)
      ..close();
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  OutlinedBorder copyWith({BorderSide? side}) => this;

  @override
  ShapeBorder scale(double t) => this;
}

/// 空闲状态：灰色封面占位 + 提示文字 + 禁用的播放键。
class _IdleBar extends StatelessWidget {
  const _IdleBar();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.music_note_rounded,
            color: colorScheme.onSurfaceVariant.withAlpha(140),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            context.l10n.playerIdleHint,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Icon(
          Icons.play_circle_fill_rounded,
          size: 40,
          color: colorScheme.onSurfaceVariant.withAlpha(80),
        ),
        const Spacer(),
      ],
    );
  }
}

class _NowPlayingInfo extends StatelessWidget {
  final SpotifyTrack track;

  const _NowPlayingInfo({required this.track});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      children: [
        PlayerBarCover(
          url: track.coverUrl,
          layout: context.watch<ShellLayoutController?>(),
          onOpenFallback: () => FullPlayerSheet.show(context),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HoverLink(
                text: track.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
                marquee: true,
                onTap: track.album == null
                    ? null
                    : () => AppRoutes.openAlbum(context, track.album!),
              ),
              const SizedBox(height: 2),
              _HoverLink(
                text: track.artistNames,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                onTap: track.artists.isEmpty
                    ? null
                    : () {
                        final a = track.artists.first;
                        AppRoutes.openArtist(context, a);
                      },
              ),
            ],
          ),
        ),
        LikeButton(
          track: track,
          size: 20,
          inactiveColor: colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }
}

/// 悬停时显示下划线的文字链接（桌面端交互习惯）。
class _HoverLink extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final bool marquee;
  final VoidCallback? onTap;

  const _HoverLink({required this.text, this.style, this.marquee = false, this.onTap});

  @override
  State<_HoverLink> createState() => _HoverLinkState();
}

class _HoverLinkState extends State<_HoverLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: widget.marquee
            ? MarqueeText(
                text: widget.text,
                style: widget.style?.copyWith(
                  decoration: _hover && widget.onTap != null ? TextDecoration.underline : null,
                ),
              )
            : Text(
                widget.text,
                style: widget.style?.copyWith(
                  decoration: _hover && widget.onTap != null ? TextDecoration.underline : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
      ),
    );
  }
}

/// 播放栏右侧的 32px 小图标按钮样式。
///
/// M3 的 IconButton 默认把点击区域补到 48px，`constraints` 无法缩小它，
/// 这里显式收紧，否则 5 个按钮 + 音量条在 300px 内放不下。
final ButtonStyle _barIconStyle = IconButton.styleFrom(
  fixedSize: const Size.square(_RightControls.buttonSize),
  minimumSize: const Size.square(_RightControls.buttonSize),
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _RightControls extends StatelessWidget {
  const _RightControls();

  static const double buttonSize = 32;
  static const double _sliderWidth = 92;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 远程设备有会话（已暂停）时设备键高亮，提示可以转回去
    final hasDevice = context.select<ConnectProvider?, bool>(
      (c) => c?.hasRemoteSession ?? false,
    );
    // 三栏框架下：「播放状态」开关右栏的「正在播放」面板（含歌词），队列键开关独立的「播放队列」面板；
    // 没有框架（单独使用播放栏）时回退为底部面板
    final layout = context.watch<ShellLayoutController?>();

    final buttons = <Widget>[
      if (SleepTimerIndicator.isActive(context))
        SleepTimerIndicator(style: _barIconStyle),
      PlaybackStatusButton(layout: layout, style: _barIconStyle),
      IconButton(
        icon: const Icon(Icons.queue_music_rounded, size: 20),
        color: layout?.isShowing(RightPanel.queue) ?? false
            ? colorScheme.primary
            : colorScheme.onSurfaceVariant,
        tooltip: context.l10n.queueTitle,
        style: _barIconStyle,
        onPressed: layout == null
            ? () => QueueSheet.show(context)
            : () => layout.togglePanel(RightPanel.queue),
      ),
      IconButton(
        icon: Icon(
          Icons.devices_rounded,
          size: 20,
          color: hasDevice ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
        tooltip: context.l10n.deviceConnectTitle,
        style: _barIconStyle,
        onPressed: () => DevicePickerSheet.show(context),
      ),
      IconButton(
        icon: const Icon(Icons.open_in_full_rounded, size: 18),
        color: colorScheme.onSurfaceVariant,
        tooltip: context.l10n.lyricsImmersive,
        style: _barIconStyle,
        onPressed: () => ImmersiveLyricsScreen.open(context),
      ),
    ];

    // 按实际可用宽度逐级隐藏：先去掉音量滑块，再去掉音量键
    return LayoutBuilder(
      builder: (context, constraints) {
        final base = buttons.length * (buttonSize + 4);
        final showVolume = constraints.maxWidth >= base + buttonSize;
        final showSlider =
            constraints.maxWidth >= base + buttonSize + _sliderWidth + 8;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            for (final b in buttons)
              Padding(padding: const EdgeInsets.only(left: 4), child: b),
            if (showVolume)
              _VolumeControl(showSlider: showSlider, sliderWidth: _sliderWidth),
          ],
        );
      },
    );
  }
}

/// 音量：点击图标静音 / 恢复；拖动时实时生效，松手后持久化。
class _VolumeControl extends StatelessWidget {
  final bool showSlider;
  final double sliderWidth;

  const _VolumeControl({required this.showSlider, required this.sliderWidth});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final volume = context.select<PlaybackProvider, double>((p) => p.volume);
    final playback = context.read<PlaybackProvider>();

    final icon = volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(icon, size: 18),
          color: colorScheme.onSurfaceVariant,
          tooltip: volume == 0
              ? context.l10n.playerUnmute
              : context.l10n.playerMute,
          style: _barIconStyle,
          onPressed: playback.toggleMute,
        ),
        if (showSlider)
          SizedBox(
            width: sliderWidth,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
              ),
              child: Slider(
                value: volume,
                onChanged: (v) => playback.setVolume(v),
                onChangeEnd: (v) => playback.setVolume(v, persist: true),
              ),
            ),
          ),
      ],
    );
  }
}
