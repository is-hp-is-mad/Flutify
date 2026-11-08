import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/shortcut_settings.dart';
import '../../../providers/connect_provider.dart';
import '../../../providers/playback_provider.dart';
import 'connect_actions.dart';
import '../keyboard_shortcuts.dart';
import '../toast/app_toast.dart';

/// 播放类键盘快捷键（主窗口与沉浸式歌词共用，与 Spotify 桌面端一致）。
/// 修饰键按平台取：macOS 用 ⌘（见 [PlatformShortcuts]），其余平台用 Ctrl。
///
/// 每次按键时才判断控制对象（[ConnectActions.isRemoteNow]）：播放栏处于远程模式（在其他设备上播放）时
/// 发给远程设备，失败弹出提示；否则控制本机。远程设备不支持调音量时音量键只弹出提示。
class PlaybackShortcuts {
  PlaybackShortcuts._();

  static const double _volumeStep = 0.1;

  /// 当前主焦点是否在可编辑文本组件内（TextField 等）。
  static bool _isTextInputFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// 播放 / 暂停键（默认空格），用于 `Focus.onKeyEvent`。
  /// 不能放进 CallbackShortcuts：它命中即吞掉按键，输入框就敲不进空格；这里在输入框聚焦时返回 ignored，让按键继续交给输入框。
  static KeyEventResult onSpaceKey(BuildContext context, KeyEvent event) {
    final combo = AppShortcuts.comboOf(
      AppShortcuts.of(context),
      AppShortcut.playPause,
    );
    if (combo == null || !AppShortcuts.matches(combo, event)) {
      return KeyEventResult.ignored;
    }
    if (!combo.hasCommandModifier && _isTextInputFocused()) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) togglePlayPause(context);
    return KeyEventResult.handled;
  }

  /// 播放 / 暂停（空格键与 macOS 菜单栏共用）：远程模式发给远程设备，否则控制本机。
  static void togglePlayPause(BuildContext context) {
    if (ConnectActions.isRemoteNow(context)) {
      final connect = context.read<ConnectProvider>();
      ConnectActions.run(context, () => connect.togglePlayPause());
    } else {
      context.read<PlaybackProvider>().togglePlayPause();
    }
  }

  /// 全部播放动作（[bindings] 的键盘映射与 macOS 菜单栏共用同一组回调）。
  static PlaybackShortcutActions actions(BuildContext context) {
    VoidCallback route(
      void Function(PlaybackProvider p) local,
      Future<void> Function(ConnectProvider c) remote,
    ) => () {
      if (ConnectActions.isRemoteNow(context)) {
        final connect = context.read<ConnectProvider>();
        ConnectActions.run(context, () => remote(connect));
      } else {
        local(context.read<PlaybackProvider>());
      }
    };

    VoidCallback volume(double delta) => () {
      if (ConnectActions.isRemoteNow(context)) {
        final connect = context.read<ConnectProvider>();
        final device = connect.activeDevice;
        if (device == null) return;
        if (device.supportsVolume) {
          connect.setVolume(connect.volume + delta);
        } else {
          // 连按时只保留一条提示（AppToast 默认替换当前提示）
          AppToast.show(
            context,
            context.l10n.connectVolumeUnsupported(device.name),
            icon: Icons.volume_off_rounded,
            tone: ToastTone.warning,
          );
        }
      } else {
        final playback = context.read<PlaybackProvider>();
        playback.setVolume(playback.volume + delta, persist: true);
      }
    };

    return PlaybackShortcutActions._(
      next: route((p) => p.nextTrack(), (c) => c.skipNext()),
      previous: route((p) => p.previousTrack(), (c) => c.skipPrevious()),
      volumeUp: volume(_volumeStep),
      volumeDown: volume(-_volumeStep),
      shuffle: route((p) => p.toggleShuffle(), (c) => c.toggleShuffle()),
      repeat: route((p) => p.cycleRepeatMode(), (c) => c.cycleRepeat()),
    );
  }

  static Map<ShortcutActivator, VoidCallback> bindings(BuildContext context) {
    final a = actions(context);
    final settings = AppShortcuts.of(context);
    return {
      for (final (action, callback) in [
        (AppShortcut.next, a.next),
        (AppShortcut.previous, a.previous),
        (AppShortcut.volumeUp, a.volumeUp),
        (AppShortcut.volumeDown, a.volumeDown),
        (AppShortcut.shuffle, a.shuffle),
        (AppShortcut.repeat, a.repeat),
      ])
        ?AppShortcuts.activator(settings, action): callback,
    };
  }
}

/// 播放动作回调集（键盘映射 / macOS 菜单栏共用，构造见 [PlaybackShortcuts.actions]）。
class PlaybackShortcutActions {
  /// 下一首 / 上一首。
  final VoidCallback next;

  /// 上一首。
  final VoidCallback previous;

  /// 调高音量。
  final VoidCallback volumeUp;

  /// 调低音量。
  final VoidCallback volumeDown;

  /// 随机播放开关。
  final VoidCallback shuffle;

  /// 切换循环模式。
  final VoidCallback repeat;

  const PlaybackShortcutActions._({
    required this.next,
    required this.previous,
    required this.volumeUp,
    required this.volumeDown,
    required this.shuffle,
    required this.repeat,
  });
}
