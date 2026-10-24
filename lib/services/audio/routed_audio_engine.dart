import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../protocol/progressive_download.dart';
import 'audio_engine.dart';

/// 路由音频引擎：本地文件/流式 → just_audio 引擎；DRM 曲目 → EME 引擎。
///
/// 对 PlaybackProvider 暴露统一的流与方法；同一时刻只有一个引擎出声（切歌时先停另一个）。
/// 进度/时长/状态流只转发当前活跃引擎的事件，避免串台。
class RoutedAudioEngine implements AudioEngine {
  final AudioEngine _local;
  final AudioEngine _eme;

  /// 当前活跃引擎；null 表示都未加载。
  AudioEngine? _active;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _stateController = StreamController<PlayerState>.broadcast();

  RoutedAudioEngine({required AudioEngine local, required AudioEngine eme})
      : _local = local,
        _eme = eme {
    _local.positionStream.listen((d) {
      if (identical(_active, _local)) _positionController.add(d);
    });
    _local.durationStream.listen((d) {
      if (identical(_active, _local)) _durationController.add(d);
    });
    _local.playerStateStream.listen((s) {
      if (identical(_active, _local)) _stateController.add(s);
    });
    _eme.positionStream.listen((d) {
      if (identical(_active, _eme)) _positionController.add(d);
    });
    _eme.durationStream.listen((d) {
      if (identical(_active, _eme)) _durationController.add(d);
    });
    _eme.playerStateStream.listen((s) {
      if (identical(_active, _eme)) _stateController.add(s);
    });
  }

  /// 标记活跃引擎并暂停另一个（切歌时调用，在加载新音源前）。
  AudioEngine _activate(AudioEngine engine) {
    final other = identical(engine, _local) ? _eme : _local;
    _active = engine;
    other.pause();
    return engine;
  }

  @override
  Future<void> playFile(String path, {Duration? initialPosition, bool autoplay = true}) =>
      _activateLocal().playFile(path, initialPosition: initialPosition, autoplay: autoplay);

  @override
  Future<void> playStream(ProgressiveAudio audio, {Duration? initialPosition, bool autoplay = true}) =>
      _activateLocal().playStream(audio, initialPosition: initialPosition, autoplay: autoplay);

  @override
  Future<void> playEme(EmeTrackContent content, {Duration? initialPosition, bool autoplay = true}) =>
      // 默认按浏览器 EME；原生 DRM 引擎（Windows / Android）在音源就位后改成自己的类型
      (_markWebView()).playEme(content, initialPosition: initialPosition, autoplay: autoplay);

  AudioEngine _markWebView() {
    activePlaybackEngine.value = PlaybackEngineKind.webView;
    return _activate(_eme);
  }

  AudioEngine _activateLocal() {
    activePlaybackEngine.value = PlaybackEngineKind.localPlayer;
    return _activate(_local);
  }

  AudioEngine get _current => _active ?? _local;

  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration?> get durationStream => _durationController.stream;
  @override
  Stream<PlayerState> get playerStateStream => _stateController.stream;
  @override
  Stream<EmePlaybackException> get emeErrors => _eme.emeErrors;

  @override
  Duration get position => _current.position;
  @override
  Duration? get duration => _current.duration;
  @override
  bool get isPlaying => _current.isPlaying;
  @override
  bool get hasSource => _current.hasSource;

  @override
  Future<void> play() => _current.play();
  @override
  Future<void> pause() => _current.pause();
  @override
  Future<void> seek(Duration position) => _current.seek(position);
  @override
  Future<void> setVolume(double volume) {
    // 音量同时下发两个引擎，切引擎后仍保持
    _eme.setVolume(volume);
    return _local.setVolume(volume);
  }

  @override
  Future<void> stop() => _current.stop();

  @override
  void dispose() {
    _local.dispose();
    _eme.dispose();
  }
}
