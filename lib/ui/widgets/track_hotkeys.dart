import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/track.dart';
import 'track_menu.dart';

/// 曲目快捷键（桌面）：鼠标悬停在曲目行上按 [TrackAction.activator]，等同于在该行菜单里点对应项。
///
/// 官方桌面端作用于「选中行」；Flutify 单击行即播放、没有选中态，所以改为作用于鼠标下的行。
/// 输入框有焦点时不拦截（字母键要留给输入）。放在外壳上，键盘事件从焦点处冒泡上来。
class TrackHotkeys extends StatelessWidget {
  final Widget child;

  const TrackHotkeys({super.key, required this.child});

  static _HoverTarget? _target;

  /// 曲目行在鼠标进入 / 移动时上报（[position] 为全局坐标，二级菜单在此弹出）。
  static void hover(BuildContext context, SpotifyTrack track, Offset position) =>
      _target = _HoverTarget(context, track, position);

  /// 鼠标离开曲目行。
  static void leave(BuildContext context) {
    if (identical(_target?.context, context)) _target = null;
  }

  static bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<EditableTextState>() != null;

  static KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final target = _target;
    if (event is! KeyDownEvent || target == null || !target.context.mounted || _typing) {
      return KeyEventResult.ignored;
    }
    for (final action in TrackAction.values) {
      final activator = action.activator;
      if (activator == null || !activator.accepts(event, HardwareKeyboard.instance)) continue;
      if (!TrackMenu.isAvailable(target.context, target.track, action)) return KeyEventResult.ignored;
      TrackMenu.perform(target.context, target.track, action, position: target.position);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: child);
  }
}

class _HoverTarget {
  final BuildContext context;
  final SpotifyTrack track;
  final Offset position;

  const _HoverTarget(this.context, this.track, this.position);
}
