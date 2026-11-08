import 'dart:async';

import 'package:audio_service/audio_service.dart' hide MediaButton;
import 'package:flutter/foundation.dart';

import 'system_media_controls.dart';

typedef ArtworkFileResolver = Future<String?> Function(String url);

/// Android / iOS：通过 audio_service 提供通知栏、锁屏与蓝牙耳机按键控制。
///
/// 实际播放由音频引擎完成；这里的 [AudioHandler] 只做状态展示和按键转发。
class AudioServiceMediaControls implements SystemMediaControls {
  final FlutifyAudioHandler _handler;

  final ArtworkFileResolver? _artworkFile;

  int _trackSeq = 0;

  AudioServiceMediaControls._(this._handler, this._artworkFile);

  @visibleForTesting
  AudioServiceMediaControls.withHandler(this._handler, [this._artworkFile]);

  static Future<AudioServiceMediaControls> init({
    ArtworkFileResolver? artworkFile,
  }) async {
    final handler = await AudioService.init(
      builder: FlutifyAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.flutify.music.playback',
        androidNotificationChannelName: '播放',
        androidNotificationIcon: 'drawable/ic_stat_music',
        // 暂停时允许划掉通知、让出前台服务
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        artDownscaleWidth: 512,
        artDownscaleHeight: 512,
      ),
    );
    return AudioServiceMediaControls._(handler, artworkFile);
  }

  @override
  Stream<MediaControlEvent> get events => _handler.events.stream;

  @override
  bool get needsPeriodicTimeline => false; // 系统按 updateTime + speed 自行推算进度

  @override
  Future<void> setTrack(MediaTrackInfo? track) async {
    final seq = ++_trackSeq;
    if (track == null) {
      _handler.mediaItem.add(null);
      _handler.playbackState.add(
        PlaybackState(processingState: AudioProcessingState.idle),
      );
      return;
    }
    final artUri = _artworkFile == null
        ? _remoteArtUri(track.artUrl)
        : await _resolveArtUri(track.artUrl);
    if (seq != _trackSeq) return;
    _handler.mediaItem.add(_mediaItem(track, artUri));
  }

  static Uri? _remoteArtUri(String url) =>
      url.isEmpty ? null : Uri.tryParse(url);

  Future<Uri?> _resolveArtUri(String url) async {
    if (url.isEmpty) return null;
    String? path;
    try {
      path = await _artworkFile!(url).timeout(const Duration(seconds: 5));
    } catch (_) {
      path = null;
    }
    if (path != null && path.isNotEmpty) return Uri.file(path);
    return _remoteArtUri(url);
  }

  static MediaItem _mediaItem(MediaTrackInfo track, Uri? artUri) => MediaItem(
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    duration: track.duration,
    artUri: artUri,
  );

  @override
  Future<void> setPlayback(MediaPlaybackInfo info) async {
    _handler.playbackState.add(
      PlaybackState(
        controls: [
          if (info.canPrevious) MediaControl.skipToPrevious,
          info.playing ? MediaControl.pause : MediaControl.play,
          if (info.canNext) MediaControl.skipToNext,
        ],
        // 同时声明 MediaSession 能力与通知按钮。Android 13+ 以及部分 OEM
        // 系统卡片读取 PlaybackState actions，不使用 compact notification 布局。
        systemActions: {
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.stop,
          MediaAction.seek,
          if (info.canPrevious) MediaAction.skipToPrevious,
          if (info.canNext) MediaAction.skipToNext,
        },
        androidCompactActionIndices: [
          for (
            var i = 0;
            i < 1 + (info.canPrevious ? 1 : 0) + (info.canNext ? 1 : 0);
            i++
          )
            i,
        ],
        processingState: info.buffering
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: info.playing,
        updatePosition: info.position,
        speed: info.playing && !info.buffering ? 1.0 : 0.0,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(setTrack(null));
  }
}

class FlutifyAudioHandler extends BaseAudioHandler with SeekHandler {
  final StreamController<MediaControlEvent> events =
      StreamController.broadcast();

  void _button(MediaButton b) => events.add(MediaButtonEvent(b));

  @override
  Future<void> play() async => _button(MediaButton.play);

  @override
  Future<void> pause() async => _button(MediaButton.pause);

  @override
  Future<void> stop() async => _button(MediaButton.stop);

  @override
  Future<void> skipToNext() async => _button(MediaButton.next);

  @override
  Future<void> skipToPrevious() async => _button(MediaButton.previous);

  @override
  Future<void> seek(Duration position) async =>
      events.add(MediaSeekEvent(position));
}
