import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../providers/connect_provider.dart';
import '../../providers/playback_provider.dart';
import 'media_controls_sync.dart';
import 'system_media_controls.dart';

/// 在其他设备上播放时，系统媒体控制（任务栏 / 锁屏 / 通知栏媒体卡片、键盘媒体键）跟随远程设备：
/// - 卡片显示远程曲目、播放状态与进度；
/// - 按键发给远程设备。
///
/// 何时接管与播放栏的远程模式一致（[ConnectProvider.controlsRemote]）。
/// 媒体键没有界面可以提示，命令失败（免费账号部分操作会被拒）时静默忽略。
class ConnectMediaSource implements MediaSourceOverride {
  final ConnectProvider connect;
  final PlaybackProvider playback;

  ConnectMediaSource(this.connect, this.playback) : changes = Listenable.merge([connect, playback]);

  @override
  final Listenable changes;

  @override
  ValueListenable<Duration> get position => connect.position;

  @override
  bool get active =>
      connect.controlsRemote(localPlaying: playback.isPlaying, localHasTrack: playback.currentTrack != null);

  @override
  MediaTrackInfo? get track {
    final track = connect.displayTrack;
    return track == null ? null : MediaControlsSync.trackInfo(track);
  }

  @override
  MediaPlaybackInfo get playbackInfo => MediaPlaybackInfo(
    playing: connect.player.isAudible,
    buffering: false,
    position: Duration(milliseconds: connect.player.positionAt(connect.serverNowMs)),
    canNext: true,
    canPrevious: true,
  );

  @override
  bool handle(MediaControlEvent event) {
    if (!active) return false;
    final Future<void> command = switch (event) {
      MediaButtonEvent(button: MediaButton.play) =>
        connect.player.isAudible ? Future<void>.value() : connect.togglePlayPause(),
      MediaButtonEvent(button: MediaButton.pause || MediaButton.stop) => connect.pause(),
      MediaButtonEvent(button: MediaButton.toggle) => connect.togglePlayPause(),
      MediaButtonEvent(button: MediaButton.next) => connect.skipNext(),
      MediaButtonEvent(button: MediaButton.previous) => connect.skipPrevious(),
      MediaSeekEvent(:final position) => connect.seekTo(position.inMilliseconds),
    };
    unawaited(command.catchError((Object _) {}));
    return true;
  }
}
