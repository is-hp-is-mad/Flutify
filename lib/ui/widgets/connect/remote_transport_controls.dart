import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../providers/connect_provider.dart';
import 'connect_actions.dart';

/// 远程控制按钮的外观：桌面播放栏（跟随主题）与歌词玻璃控制台（白色、大尺寸）两套。
class RemoteControlsStyle {
  /// 上一首 / 下一首图标色；为 null 时取 onSurface。
  final Color? foreground;

  /// 随机 / 循环未开启时的颜色；为 null 时取 onSurfaceVariant。
  final Color? muted;

  /// 播放键底色与图标色；为 null 时分别取 onSurface / surface（深色白底黑图标，浅色反之）。
  final Color? playBackground;
  final Color? playForeground;

  final double skipSize;
  final double modeSize;
  final double playSize;
  final double playIconSize;

  /// 按钮之间的间距；[spread] 为 true 时改为在可用宽度内均分。
  final double gap;
  final bool spread;

  const RemoteControlsStyle({
    this.foreground,
    this.muted,
    this.playBackground,
    this.playForeground,
    this.skipSize = 22,
    this.modeSize = 18,
    this.playSize = 36,
    this.playIconSize = 22,
    this.gap = 10,
    this.spread = false,
  });

  /// 桌面播放栏。
  static const RemoteControlsStyle bar = RemoteControlsStyle();

  /// 歌词液态玻璃控制台（与本机 LyricsGlassControls 尺寸一致）。
  static const RemoteControlsStyle glass = RemoteControlsStyle(
    foreground: Colors.white,
    muted: Colors.white60,
    playBackground: Colors.white,
    playForeground: Colors.black,
    skipSize: 32,
    modeSize: 24,
    playSize: 56,
    playIconSize: 32,
    gap: 28,
  );

  /// 歌词玻璃控制台的完整版（桌面沉浸式）：带随机 / 循环，按钮均分宽度。
  static const RemoteControlsStyle glassFull = RemoteControlsStyle(
    foreground: Colors.white,
    muted: Colors.white60,
    playBackground: Colors.white,
    playForeground: Colors.black,
    skipSize: 32,
    modeSize: 24,
    playSize: 56,
    playIconSize: 32,
    spread: true,
  );
}

/// 远程播放控制：随机 / 上一首 / 播放暂停 / 下一首 / 循环，全部作用于当前活动设备。
class RemoteTransportControls extends StatelessWidget {
  /// 是否显示随机与循环。
  final bool showModes;
  final RemoteControlsStyle style;

  const RemoteTransportControls({super.key, this.showModes = true, this.style = RemoteControlsStyle.bar});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connect = context.watch<ConnectProvider>();
    final player = connect.player;
    final l10n = context.l10n;
    final s = style;
    final accent = colorScheme.primary;
    final muted = s.muted ?? colorScheme.onSurfaceVariant;

    Widget button(
      IconData icon,
      String tooltip,
      Future<void> Function() action, {
      required Color color,
      required double size,
    }) {
      // M3 IconButton 默认补到 48px 点击区；小图标收紧，避免播放栏一行放不下
      final extent = size <= 22 ? 32.0 : size + 16;
      return IconButton(
        icon: Icon(icon, size: size),
        color: color,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          fixedSize: Size.square(extent),
          minimumSize: Size.square(extent),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => ConnectActions.run(context, action),
      );
    }

    final repeatOn = player.repeatContext || player.repeatTrack;
    // 提示文字描述「点按后会怎样」，与本机播放控件一致
    final repeatTooltip = player.repeatTrack
        ? l10n.playerRepeatOff
        : (player.repeatContext ? l10n.playerRepeatOneOn : l10n.playerRepeatOn);
    final foreground = s.foreground ?? colorScheme.onSurface;

    final children = <Widget>[
      if (showModes)
        button(
          Icons.shuffle_rounded,
          player.shuffle ? l10n.playerShuffleOff : l10n.playerShuffleOn,
          connect.toggleShuffle,
          color: player.shuffle ? accent : muted,
          size: s.modeSize,
        ),
      button(
        Icons.skip_previous_rounded,
        l10n.playerPrevious,
        connect.skipPrevious,
        color: foreground,
        size: s.skipSize,
      ),
      Material(
        color: s.playBackground ?? colorScheme.onSurface,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          onTap: () => ConnectActions.run(context, connect.togglePlayPause),
          child: SizedBox.square(
            dimension: s.playSize,
            child: Icon(
              player.isAudible ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: s.playIconSize,
              color: s.playForeground ?? colorScheme.surface,
            ),
          ),
        ),
      ),
      button(Icons.skip_next_rounded, l10n.playerNext, connect.skipNext, color: foreground, size: s.skipSize),
      if (showModes)
        button(
          player.repeatTrack ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          repeatTooltip,
          connect.cycleRepeat,
          color: repeatOn ? accent : muted,
          size: s.modeSize,
        ),
    ];

    if (s.spread) {
      return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(width: s.gap), children[i]],
      ],
    );
  }
}
