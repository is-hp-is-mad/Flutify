import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../models/shortcut_settings.dart';
import '../../../services/media_controls/system_media_controls.dart';
import '../../widgets/keyboard_shortcuts.dart';

/// 处理发现流内的播放快捷键（上一首 / 下一首 / 播放暂停→静音）与硬件媒体键。
KeyEventResult handleWatchFeedMediaKey(
  BuildContext context,
  KeyEvent event, {
  required VoidCallback onPrevious,
  required VoidCallback onNext,
  required VoidCallback onToggleMute,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final key = event.logicalKey;
  final shortcuts = AppShortcuts.of(context);
  final nextCombo = AppShortcuts.comboOf(shortcuts, AppShortcut.next);
  if ((nextCombo != null && AppShortcuts.matches(nextCombo, event)) ||
      key == LogicalKeyboardKey.mediaTrackNext) {
    onNext();
    return KeyEventResult.handled;
  }
  final prevCombo = AppShortcuts.comboOf(shortcuts, AppShortcut.previous);
  if ((prevCombo != null && AppShortcuts.matches(prevCombo, event)) ||
      key == LogicalKeyboardKey.mediaTrackPrevious) {
    onPrevious();
    return KeyEventResult.handled;
  }
  final playPauseCombo = AppShortcuts.comboOf(
    shortcuts,
    AppShortcut.playPause,
  );
  if ((playPauseCombo != null && AppShortcuts.matches(playPauseCombo, event)) ||
      key == LogicalKeyboardKey.mediaPlayPause ||
      key == LogicalKeyboardKey.mediaPlay ||
      key == LogicalKeyboardKey.mediaPause ||
      key == LogicalKeyboardKey.audioVolumeMute) {
    if (event is KeyDownEvent) {
      onToggleMute();
    }
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// 处理发现流激活期间的系统媒体控制按键（SMTC / MPRemoteCommandCenter 等）。
bool handleWatchFeedMediaButton(
  MediaControlEvent event, {
  required VoidCallback onPrevious,
  required VoidCallback onNext,
  required bool Function() isMuted,
  required ValueChanged<bool> setMuted,
}) {
  if (event is! MediaButtonEvent) return false;
  switch (event.button) {
    case MediaButton.next:
      onNext();
      return true;
    case MediaButton.previous:
      onPrevious();
      return true;
    case MediaButton.toggle:
      setMuted(!isMuted());
      return true;
    case MediaButton.pause:
    case MediaButton.stop:
      setMuted(true);
      return true;
    case MediaButton.play:
      setMuted(false);
      return true;
  }
}
