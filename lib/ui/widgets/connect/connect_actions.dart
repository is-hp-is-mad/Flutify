import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/connect_cluster.dart';
import '../../../providers/connect_provider.dart';
import '../../../providers/playback_provider.dart';
import '../toast/app_toast.dart';

/// 本机播放与远程设备之间的协调（涉及两个 Provider，放在 UI 层）。
///
/// 所有方法都在第一个 await 之前取完 Provider 与 ScaffoldMessenger：
/// 调用方（设备面板）往往随即关闭，之后不能再用它的 context。
class ConnectActions {
  ConnectActions._();

  /// 播放栏是否切换为远程模式（规则见 [ConnectProvider.controlsRemote]）；在 build 中调用，按需订阅。
  static bool showRemote(BuildContext context) {
    final remote = context.select<ConnectProvider?, bool>(
      (c) => c?.hasRemoteSession ?? false,
    );
    if (!remote) return false;
    final local = context.select<PlaybackProvider, (bool, bool)>(
      (p) => (p.isPlaying, p.currentTrack != null),
    );
    return context.select<ConnectProvider, bool>(
      (c) => c.controlsRemote(localPlaying: local.$1, localHasTrack: local.$2),
    );
  }

  /// 同 [showRemote]，但不订阅，供点击、快捷键等回调里使用。
  static bool isRemoteNow(BuildContext context) {
    final connect = context.read<ConnectProvider?>();
    if (connect == null) return false;
    final playback = context.read<PlaybackProvider>();
    return connect.controlsRemote(
      localPlaying: playback.isPlaying,
      localHasTrack: playback.currentTrack != null,
    );
  }

  /// 转移到远程设备：先暂停本机，避免两边同时出声。
  static Future<void> transferTo(BuildContext context, ConnectDevice device) {
    final playback = context.read<PlaybackProvider>();
    final connect = context.read<ConnectProvider>();
    final report = _reporter(context);
    return _guard(report, () async {
      await playback.pause();
      await connect.transferTo(device);
    });
  }

  /// 在此设备继续：暂停远程设备，本机从同一首、同一进度开始播放。
  static Future<void> takeOver(BuildContext context) {
    final connect = context.read<ConnectProvider>();
    final playback = context.read<PlaybackProvider>();
    final report = _reporter(context);
    final track = connect.displayTrack;
    final position = connect.player.positionAt(connect.serverNowMs);
    return _guard(report, () async {
      // 本机播放端在线：用 Connect 转移，其他设备能看到「正在 Flutify 上播放」
      if (connect.receiverOnline) {
        await connect.transferToReceiver();
        return;
      }
      await connect.pause();
      if (track == null) return;
      await playback.playLocal(
        track,
        startAt: Duration(milliseconds: position),
      );
    });
  }

  /// 执行远程命令；失败时弹出提示（免费账号部分操作会被拒绝）。
  static Future<void> run(
    BuildContext context,
    Future<void> Function() action,
  ) => _guard(_reporter(context), action);

  static VoidCallback _reporter(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = context.l10n.connectCommandFailed;
    return () => AppToast.showOn(
      messenger,
      message,
      icon: Icons.cast_rounded,
      tone: ToastTone.error,
    );
  }

  static Future<void> _guard(
    VoidCallback report,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      report();
    }
  }
}
