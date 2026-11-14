import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import '../../models/audio_playback_info.dart';
import '../../services/audio/audio_engine.dart';
import '../../services/audio/audio_output_service.dart';
import '../../services/protocol/audio_cache_store.dart';
import '../../services/protocol/track_audio_loader.dart';
import '../../services/protocol/track_metadata.dart';
import 'mock_catalog.dart';

/// Mock 模式无声频引擎：不初始化 libmpv/ExoPlayer/WebView2，仅以计时器模拟流畅播放进度，
/// 让 CI 无声卡环境下也能完整测试播放条、全屏播放器、进度拖拽与同步歌词动画。
class MockAudioEngine implements AudioEngine {
  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration?>.broadcast();
  final _stateCtrl = StreamController<PlayerState>.broadcast();
  final _emeErrorsCtrl = StreamController<EmePlaybackException>.broadcast();

  Duration _position = Duration.zero;
  Duration? _duration;
  bool _isPlaying = false;
  bool _hasSource = false;
  Timer? _ticker;
  bool _disposed = false;

  @override
  Stream<Duration> get positionStream => _positionCtrl.stream;

  @override
  Stream<Duration?> get durationStream => _durationCtrl.stream;

  @override
  Stream<PlayerState> get playerStateStream => _stateCtrl.stream;

  @override
  Stream<EmePlaybackException> get emeErrors => _emeErrorsCtrl.stream;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get hasSource => _hasSource;

  void _emitState() {
    if (_disposed) return;
    _stateCtrl.add(
      PlayerState(
        _isPlaying,
        _hasSource ? ProcessingState.ready : ProcessingState.idle,
      ),
    );
  }

  void _ensureTicker() {
    _ticker?.cancel();
    if (!_isPlaying || _disposed) return;
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed || !_isPlaying) return;
      final next = _position + const Duration(milliseconds: 250);
      final maxDur = _duration;
      if (maxDur != null && next >= maxDur) {
        _position = maxDur;
        _positionCtrl.add(_position);
        _isPlaying = false;
        _ticker?.cancel();
        _stateCtrl.add(PlayerState(false, ProcessingState.completed));
      } else {
        _position = next;
        _positionCtrl.add(_position);
      }
    });
  }

  Future<void> _loadMockSource({
    Duration? initialPosition,
    bool autoplay = true,
    Duration defaultDuration = const Duration(minutes: 3, seconds: 30),
  }) async {
    activePlaybackEngine.value = PlaybackEngineKind.localPlayer;
    _hasSource = true;
    _duration ??= defaultDuration;
    _position = initialPosition ?? Duration.zero;
    _isPlaying = autoplay;
    _durationCtrl.add(_duration);
    _positionCtrl.add(_position);
    _emitState();
    _ensureTicker();
  }

  @override
  Future<void> playFile(
    String path, {
    Duration? initialPosition,
    bool autoplay = true,
  }) => _loadMockSource(initialPosition: initialPosition, autoplay: autoplay);

  @override
  Future<void> playStream(
    ProgressiveAudio audio, {
    Duration? initialPosition,
    bool autoplay = true,
  }) => _loadMockSource(initialPosition: initialPosition, autoplay: autoplay);

  @override
  Future<void> playEme(
    EmeTrackContent content, {
    Duration? initialPosition,
    bool autoplay = true,
  }) => _loadMockSource(initialPosition: initialPosition, autoplay: autoplay);

  @override
  Future<void> play() async {
    if (!_hasSource) return;
    _isPlaying = true;
    _emitState();
    _ensureTicker();
  }

  @override
  Future<void> pause() async {
    _isPlaying = false;
    _ticker?.cancel();
    _emitState();
  }

  @override
  Future<void> seek(Duration position) async {
    final maxMs = _duration?.inMilliseconds;
    final clampedMs = maxMs == null
        ? position.inMilliseconds.clamp(0, 1 << 30)
        : position.inMilliseconds.clamp(0, maxMs);
    _position = Duration(milliseconds: clampedMs);
    if (!_disposed) _positionCtrl.add(_position);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    _isPlaying = false;
    _hasSource = false;
    _position = Duration.zero;
    _ticker?.cancel();
    _emitState();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _positionCtrl.close();
    _durationCtrl.close();
    _stateCtrl.close();
    _emeErrorsCtrl.close();
  }
}

/// Mock 曲目音源加载器：零网络、零解密，立即返回曲目元数据对应的 [LoadedAudio]。
class MockTrackAudioSource implements TrackAudioSource, AudioCacheStore {
  final MockCatalog catalog;
  int _maxCacheBytes = 512 * 1024 * 1024;
  int _mockCachedBytes = 12 * 1024 * 1024;

  MockTrackAudioSource(this.catalog);

  @override
  Future<LoadedAudio> load(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) async {
    progress?.call(1.0);
    final track = catalog.findTrackByIdOrUri(trackIdOrUri);
    final id = track?.id ?? trackIdOrUri.split(':').last;
    return LoadedAudio(
      playbackInfo: const AudioPlaybackInfo(bitrate: 320000, format: 'ogg'),
      file: File('${Directory.systemTemp.path}${Platform.pathSeparator}flutify_mock_$id.ogg'),
      source: TrackAudioFile(
        fileId: Uint8List(20),
        format: AudioFileFormat.oggVorbis320,
      ),
      durationMs: track?.durationMs ?? 210000,
      trackId: id,
    );
  }

  @override
  Future<LoadedAudio> open(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) => load(trackIdOrUri, progress: progress);

  @override
  Future<void> prefetch(String trackIdOrUri) async {}

  @override
  int get maxCacheBytes => _maxCacheBytes;

  @override
  set maxCacheBytes(int value) {
    _maxCacheBytes = value;
  }

  @override
  Future<int> sizeBytes() async => _mockCachedBytes;

  @override
  Future<int> clear() async {
    final freed = _mockCachedBytes;
    _mockCachedBytes = 0;
    return freed;
  }
}

/// Mock 音频输出后端，用于 CI 无声卡环境下渲染「畅联本机音频设备」UI。
class MockAudioOutputBackend implements AudioOutputBackend {
  String selectedId = '';

  @override
  Future<List<AudioOutputDevice>> list() async => const [
    AudioOutputDevice('mock/studio_speakers', 'Mock Studio Speakers'),
    AudioOutputDevice('mock/reference_cans', 'Mock Reference Headphones'),
  ];

  @override
  Future<void> select(String id) async {
    selectedId = id;
  }
}
