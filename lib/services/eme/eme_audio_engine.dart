import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/audio_engine.dart';
import '../protocol/progressive_download.dart';
import 'eme_player.dart';
import 'fairplay.dart';

/// EME 音频引擎：用隐藏 WebView2（Widevine + HLS.js）播放 DRM 加密曲目。
///
/// 把 [EmePlayer] 适配成 [AudioEngine]（just_audio 语义），供 PlaybackProvider 统一调用。
/// 密钥反代（licensePoster / certFetcher）由装配层注入（依赖 Web token）。
class EmeAudioEngine implements AudioEngine {
  final EmePlayer _player;

  /// license 反代：把 CDM 的 license 请求体 POST 到 Spotify，返回响应。
  final Future<Uint8List> Function(Uint8List request) _licensePoster;

  /// 取 Widevine application-certificate。
  final Future<Uint8List> Function() _certFetcher;

  /// Expensive desktop WebView startup happens only when DRM playback is used.
  final Future<void> Function()? _initialize;
  Future<void>? _initializing;

  EmeAudioEngine({
    required EmePlayer player,
    required Future<Uint8List> Function(Uint8List request) licensePoster,
    required Future<Uint8List> Function() certFetcher,
    Future<void> Function()? initialize,
  }) : _player = player,
       _licensePoster = licensePoster,
       _certFetcher = certFetcher,
       _initialize = initialize {
    _player.positionStream.listen((p) {
      _position = p;
      _positionController.add(p);
    });
    _player.durationStream.listen((d) {
      _duration = d;
      _durationController.add(d);
    });
    _player.stateStream.listen(_onState);
  }

  // ---- 状态 ----
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _stateController = StreamController<PlayerState>.broadcast();
  final _errorController = StreamController<EmePlaybackException>.broadcast();

  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  ProcessingState _processing = ProcessingState.idle;
  bool _hasSource = false;
  double _volume = 1;
  int _loadGeneration = 0;
  int _intentRevision = 0;
  bool _wantsPlay = false;
  bool _disposed = false;

  void _onState(EmePlayerState s) {
    if (_disposed) return;
    if (s == EmePlayerState.playing && !_wantsPlay) return;
    switch (s) {
      case EmePlayerState.playing:
        _playing = true;
        _processing = ProcessingState.ready;
      case EmePlayerState.buffering:
        _processing = ProcessingState.buffering;
      case EmePlayerState.paused:
        _playing = false;
        _processing = ProcessingState.ready;
      case EmePlayerState.ended:
        _playing = false;
        _processing = ProcessingState.completed;
      case EmePlayerState.error:
        // 状态事件是异步投递的：error 发出后、送达前若已开播下一首（[EmePlayer.play]
        // 清空了 lastError），这条就是上一首的残留——丢弃，别把正在加载的新曲目标成失败。
        // （EmePlayer 侧已按代次过滤反代失败与页面事件，这里兜住投递间隙。）
        final err = _player.lastError;
        if (err == null) {
          debugPrint('[eme] 忽略上一首残留 error 状态（lastError 已随换歌清空）');
          return;
        }
        _playing = false;
        _processing = ProcessingState.idle;
        if (_hasSource) {
          // 运行期错误（license / HLS fatal 等，在 play 返回后才暴露）：
          // 带上 [_player.lastError] 的原因上报给 PlaybackProvider 转成用户可见提示，
          // 并把 _hasSource 复位，让上层知道要重试必须重新整载
          _hasSource = false;
          _errorController.add(err);
        }
    }
    _emit();
  }

  void _emit() {
    _stateController.add(PlayerState(_playing, _processing));
  }

  @override
  Stream<Duration> get positionStream => _positionController.stream;
  @override
  Stream<Duration?> get durationStream => _durationController.stream;
  @override
  Stream<PlayerState> get playerStateStream => _stateController.stream;
  @override
  Stream<EmePlaybackException> get emeErrors => _errorController.stream;

  @override
  Duration get position => _position;
  @override
  Duration? get duration => _duration;
  @override
  bool get isPlaying => _playing;
  @override
  bool get hasSource => _hasSource;

  @override
  Future<void> playEme(
    EmeTrackContent content, {
    Duration? initialPosition,
    bool autoplay = true,
  }) async {
    final generation = ++_loadGeneration;
    _intentRevision++;
    _wantsPlay = autoplay;
    _hasSource = false;
    _processing = ProcessingState.loading;
    _emit();
    try {
      await (_initializing ??= _initialize?.call() ?? Future.value());
    } catch (_) {
      _initializing = null;
      if (_disposed || generation != _loadGeneration) return;
      _processing = ProcessingState.idle;
      _emit();
      rethrow;
    }
    if (_disposed || generation != _loadGeneration) return;
    await _player.setVolume(_volume);
    if (_disposed || generation != _loadGeneration) return;
    // macOS / iOS：WKWebView 无 Widevine，只能走 FairPlay（见 EmePlayer.play / fairplay.dart）。
    // licensePoster/certFetcher 的 fairplay 端点选择由 license 客户端同步按平台默认，
    // 两端（本地页 keySystem 切换与反代端点切换）必须保持同一判定，否则端点与 CDM 错配。
    final fairPlay = useFairPlay;
    if (fairPlay)
      debugPrint('[eme] WKWebView：启用 FairPlay 全曲播放链路（com.apple.fps）');
    await _player.play(
      m4a: File(content.m4aPath),
      m3u8: content.m3u8,
      licensePoster: _licensePoster,
      certFetcher: _certFetcher,
      fairPlay: fairPlay,
      fairPlayFileId: content.fileIdHex,
      autoplay: _wantsPlay,
      initialPosition: initialPosition,
    );
    if (_disposed || generation != _loadGeneration) return;
    _hasSource = true;
  }

  // just_audio 路径在 EME 引擎上不可用（路由层保证不调用）
  @override
  Future<void> playFile(
    String path, {
    Duration? initialPosition,
    bool autoplay = true,
  }) => throw UnimplementedError('EME 引擎不支持本地文件');
  @override
  Future<void> playStream(
    ProgressiveAudio audio, {
    Duration? initialPosition,
    bool autoplay = true,
  }) => throw UnimplementedError('EME 引擎不支持流式下载');

  @override
  Future<void> play() async {
    final revision = ++_intentRevision;
    _wantsPlay = true;
    await _player.resume();
    if (_disposed || revision != _intentRevision) return;
    _playing = true;
    _processing = ProcessingState.ready;
    _emit();
  }

  @override
  Future<void> pause() async {
    final revision = ++_intentRevision;
    _wantsPlay = false;
    await _player.pause();
    if (_disposed || revision != _intentRevision) return;
    _playing = false;
    _emit();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    return _player.setVolume(_volume);
  }

  @override
  Future<void> stop() async {
    _loadGeneration++;
    final revision = ++_intentRevision;
    _wantsPlay = false;
    await _player.stop();
    if (_disposed || revision != _intentRevision) return;
    _playing = false;
    _processing = ProcessingState.idle;
    _hasSource = false;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _intentRevision++;
    _player.dispose();
  }
}
