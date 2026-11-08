import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../screens/player/lyrics_sheet.dart';
import '../shell/shell_layout_controller.dart';

/// 播放栏「播放状态」键（本机 / 远程播放栏共用）。
///
/// 三栏框架下开关右栏的「正在播放 / 歌词」（两者在右栏顶部切换），右栏显示它们时高亮；
/// 没有框架（[layout] 为 null，单独使用播放栏）时打开底部歌词面板。
class PlaybackStatusButton extends StatelessWidget {
  final ShellLayoutController? layout;
  final ButtonStyle? style;

  const PlaybackStatusButton({super.key, required this.layout, this.style});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final layout = this.layout;
    final active = layout?.playbackStatusVisible ?? false;
    return IconButton(
      icon: Icon(active ? Icons.view_sidebar_rounded : Icons.view_sidebar_outlined, size: 20),
      color: active ? colorScheme.primary : colorScheme.onSurfaceVariant,
      tooltip: context.l10n.shellPlaybackStatus,
      style: style,
      onPressed: layout == null ? () => LyricsSheet.show(context) : layout.togglePlaybackStatus,
    );
  }
}
