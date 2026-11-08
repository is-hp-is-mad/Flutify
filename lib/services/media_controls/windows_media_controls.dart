import 'dart:async';

import 'package:flutter/services.dart';

import 'system_media_controls.dart';

/// Windows SMTC（SystemMediaTransportControls）。
///
/// 原生实现在 `windows/runner/media_controls.cpp`，通过 MethodChannel `flutify/media_controls` 通信：
/// - Dart → 原生：`setTrack`（null 清除）、`setPlayback`（状态、能否切歌、进度）；
/// - 原生 → Dart：`button`（play / pause / toggle / next / previous / stop）、`seek`（毫秒）。
/// 键盘媒体键由系统路由给 SMTC，因此也走这里。
class WindowsMediaControls implements SystemMediaControls {
  static const MethodChannel _channel = MethodChannel('flutify/media_controls');

  final StreamController<MediaControlEvent> _events = StreamController.broadcast();

  WindowsMediaControls() {
    _channel.setMethodCallHandler(_onCall);
  }

  @override
  Stream<MediaControlEvent> get events => _events.stream;

  @override
  bool get needsPeriodicTimeline => true;

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'button':
        final button = MediaButton.values.where((b) => b.name == call.arguments).firstOrNull;
        if (button != null) _events.add(MediaButtonEvent(button));
      case 'seek':
        final ms = call.arguments;
        if (ms is int) _events.add(MediaSeekEvent(Duration(milliseconds: ms)));
    }
  }

  @override
  Future<void> setTrack(MediaTrackInfo? track) => _invoke('setTrack', track == null
      ? null
      : {
          'title': track.title,
          'artist': track.artist,
          'album': track.album,
          'artUrl': track.artUrl,
          'durationMs': track.duration.inMilliseconds,
        });

  @override
  Future<void> setPlayback(MediaPlaybackInfo info) => _invoke('setPlayback', {
    'playing': info.playing,
    'buffering': info.buffering,
    'positionMs': info.position.inMilliseconds,
    'canNext': info.canNext,
    'canPrevious': info.canPrevious,
  });

  /// 原生端不可用（如测试环境、旧版 runner）时静默忽略：媒体控制只是锦上添花，不能影响播放。
  Future<void> _invoke(String method, Object? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // 忽略
    } on PlatformException {
      // 忽略
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_invoke('setTrack', null));
    _events.close();
  }
}
