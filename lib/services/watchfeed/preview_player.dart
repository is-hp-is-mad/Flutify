import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../models/watch_feed.dart';

/// 发现流的试听播放器：独立于主播放器（不进队列、不写播放历史），
/// 播放条目自带的约 30 秒副歌片段，对齐官方 feed 走单独播放池的做法。
///
/// - 同一条目再次 [play] 只是继续，不重新加载；
/// - 服务端要求时 5 秒淡入（官方 increase_volume_gradually）；
/// - 静音是全局状态（跨条目保持），与淡入音量互不覆盖。
class WatchFeedPreviewPlayer extends ChangeNotifier {
  WatchFeedPreviewPlayer({AudioPlayer? player})
    : _player = player ?? AudioPlayer() {
    _subscriptions.addAll([
      _player.positionStream.listen((p) => position.value = p),
      _player.durationStream.listen((d) {
        _duration = d ?? Duration.zero;
        notifyListeners();
      }),
      _player.playingStream.listen((_) => notifyListeners()),
    ]);
  }

  final AudioPlayer _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// 当前片段的播放进度（高频，单独通知）。
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  /// 当前加载的片段地址。
  String? _url;
  String? get currentUrl => _url;

  bool _muted = false;
  bool get muted => _muted;

  /// 淡入进度对应的音量（0~1），静音时实际音量为 0。
  double _fadeVolume = 1;

  /// 基准音量（桌面版跟随主播放器音量，对齐官方网页版）；实际音量 = 基准 × 淡入。
  double _baseVolume = 1;

  void setBaseVolume(double value) {
    final v = value.clamp(0.0, 1.0);
    if (v == _baseVolume) return;
    _baseVolume = v;
    unawaited(_applyVolume());
  }
  Timer? _fade;

  /// 加载序号：快速翻页时只让最后一次加载生效。
  int _generation = 0;
  bool _disposed = false;

  bool get isPlaying => _player.playing;

  /// 正在加载新片段（加载期间不算「暂停」）。
  bool _loading = false;
  bool get isLoading => _loading;

  /// 是否「应当在播」：加载期间被暂停（如切到后台）时，加载完成后不再自动起播。
  bool _wantPlaying = false;

  /// 播放某条试听；与当前片段相同则继续播放。
  Future<void> play(WatchFeedAudio audio) async {
    if (_disposed) return;
    if (_url == audio.url) {
      await resume();
      return;
    }
    _wantPlaying = true;
    final generation = ++_generation;
    _url = audio.url;
    _fade?.cancel();
    _fadeVolume = audio.fadeIn ? 0 : 1;
    await _applyVolume();
    position.value = Duration.zero;
    _loading = true;
    notifyListeners();
    try {
      await _player.setUrl(audio.url);
      if (_disposed || generation != _generation) return;
      await _player.setLoopMode(audio.shouldLoop ? LoopMode.one : LoopMode.off);
      if (_disposed || generation != _generation) return;
      if (_wantPlaying) unawaited(_player.play());
      if (audio.fadeIn) _startFade(generation);
    } catch (e) {
      // 片段失效 / 网络失败：保持静默（画面照常），不影响翻页。
      debugPrint('[watch-feed] 试听加载失败：$e');
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// 5 秒线性淡入（官方 5000ms）。
  void _startFade(int generation) {
    const steps = 25;
    var step = 0;
    _fade = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (_disposed || generation != _generation) {
        timer.cancel();
        return;
      }
      step++;
      _fadeVolume = (step / steps).clamp(0.0, 1.0);
      unawaited(_applyVolume());
      if (step >= steps) timer.cancel();
    });
  }

  Future<void> _applyVolume() =>
      _player.setVolume(_muted ? 0 : _fadeVolume * _baseVolume).catchError((_) {});

  Future<void> pause() async {
    _wantPlaying = false;
    if (_disposed) return;
    await _player.pause();
  }

  Future<void> resume() async {
    if (_disposed || _url == null) return;
    _wantPlaying = true;
    // 仍在加载：加载完成后会按 _wantPlaying 起播。
    if (_loading) return;
    unawaited(_player.play());
  }

  Future<void> toggle() =>
      isPlaying || (_loading && _wantPlaying) ? pause() : resume();

  Future<void> seek(Duration to) async {
    if (_disposed) return;
    await _player.seek(to);
  }

  void setMuted(bool value) {
    if (_muted == value) return;
    _muted = value;
    unawaited(_applyVolume());
    notifyListeners();
  }

  /// 停止并卸载当前片段（离开 feed 时）。
  Future<void> stop() async {
    _wantPlaying = false;
    _generation++;
    _loading = false;
    _fade?.cancel();
    _url = null;
    if (_disposed) return;
    await _player.stop();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _fade?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    position.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }
}
