import 'package:flutter/foundation.dart';

import '../../models/audio_playback_info.dart';
import '../../models/connect_cluster.dart';
import '../../models/playback_context.dart';
import '../../models/playback_error.dart';
import '../../models/playback_state.dart';
import '../../models/track.dart';

/// 本地播放状态与控制端口（供系统媒体控制 `MediaControlsSync` / `ConnectMediaSource` 使用，
/// 解耦 `services/` 对 `PlaybackProvider` 的反向依赖）。
abstract interface class LocalPlaybackMediaPort implements Listenable {
  ValueListenable<Duration> get positionNotifier;
  SpotifyTrack? get currentTrack;
  Duration get position;
  Duration get duration;
  bool get isPlaying;
  bool get isBuffering;
  bool get isPlaybackActive;
  bool get canSkipNext;
  PlaybackError? get playbackError;
  PlaybackContext get playbackContext;

  List<SpotifyTrack> upcomingTracks(int limit);
  Future<bool> playUpcoming(int index, String trackId);
  Future<void> togglePlayPause();
  Future<void> pause();
  Future<void> nextTrack();
  Future<void> previousTrack();
  Future<void> seekTo(Duration position);
}

/// Connect 接收端宿主控制端口（供 `PlaybackReceiverHost` 使用，解耦对 `PlaybackProvider` 的依赖）。
abstract interface class ReceiverPlaybackPort implements Listenable {
  ValueListenable<Duration> get positionNotifier;
  SpotifyTrack? get currentTrack;
  Duration get position;
  Duration get duration;
  bool get isPlaying;
  bool get isBuffering;
  bool get isLoadingTrack;
  bool get shuffle;
  SpotifyRepeatMode get repeatMode;
  double get volume;
  AudioPlaybackInfo get audioPlaybackInfo;

  Future<bool> Function({bool? shuffle, SpotifyRepeatMode? repeat})?
      get syncOptionsBeforeApply;
  set syncOptionsBeforeApply(
    Future<bool> Function({bool? shuffle, SpotifyRepeatMode? repeat})? callback,
  );

  List<SpotifyTrack> Function()? get receiverWindow;
  set receiverWindow(List<SpotifyTrack> Function()? callback);

  Future<void> playReceiverQueue(
    List<SpotifyTrack> currentAndNext, {
    required Duration startAt,
    required bool paused,
  });

  void updateReceiverQueue(List<SpotifyTrack> tracks);
  void setShuffle(bool enabled);
  void setRepeatMode(SpotifyRepeatMode mode);
  Future<void> seekTo(Duration position);
  Future<void> pause();
  Future<void> togglePlayPause();
  void setVolume(double value, {bool persist = true});
}

/// 远程 Connect 控制端口（供 `ConnectMediaSource` 使用，解耦对 `ConnectProvider` 的依赖）。
abstract interface class RemoteConnectMediaPort implements Listenable {
  ValueListenable<Duration> get position;
  SpotifyTrack? get displayTrack;
  ConnectPlayerState get player;
  int get serverNowMs;

  bool controlsRemote({
    required bool localPlaying,
    required bool localHasTrack,
  });

  Future<void> togglePlayPause();
  Future<void> pause();
  Future<void> skipNext();
  Future<void> skipPrevious();
  Future<void> seekTo(int positionMs);
}
