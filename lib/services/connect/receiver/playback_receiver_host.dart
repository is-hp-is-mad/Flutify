import 'dart:async';
import '../../../models/audio_playback_info.dart';

import '../../../models/album.dart';
import '../../../models/artist.dart';
import '../../../models/image.dart';
import '../../../models/playback_state.dart';
import '../../../models/track.dart';
import '../../../providers/playback_provider.dart';
import 'connect_receiver.dart';
import 'track_playback_state.dart';

/// 把 [ConnectReceiver] 接到本机 [PlaybackProvider]：
/// - 远程命令 → 本机播放（[PlaybackProvider.playReceiverQueue] 不经远程转发）；
/// - 本机状态变化（切歌 / 暂停 / 拖动 / 播满 30 秒 / 音量）→ 回报给 [ConnectReceiver]。
///
/// 本机按状态机的「播完自动进入」顺序排队，播完一首由 PlaybackProvider 自己接下一首，
/// 再由 [ConnectReceiver.onLocalTrackChanged] 对回状态机里的目标状态。
class PlaybackReceiverHost implements ReceiverHost {
  @override
  bool get isAudible => playback.isPlaying && !playback.isBuffering;
  @override
  AudioPlaybackInfo get audioPlaybackInfo => playback.audioPlaybackInfo;
  final PlaybackProvider playback;
  late final ConnectReceiver receiver;

  String? _lastTrackUri;
  bool _lastPlaying = false;
  int _lastPositionMs = 0;
  double _lastVolume;

  /// 正在执行远程命令：期间本机变化是命令造成的，不回报。
  int _applyingCount = 0;
  bool get _applying => _applyingCount > 0;

  /// 本机在 Connect 之外开始出声（继续上次的歌、本地队列切歌等）时调用：把当前曲目、待播与进度
  /// 交给服务端，服务端再以 replace_state 下发回本机。和官方客户端一样，任何播放都对其他设备可见。
  Future<bool> Function(int positionMs)? handOver;
  bool _handingOver = false;
  String? _handedOverUri;
  String? _handoverTrackUri;
  int _handoverAttempts = 0;
  Timer? _handoverRetry;
  bool _disposed = false;
  final Duration handoverRetryDelay;
  int _commandGeneration = 0;
  int _handoverGeneration = 0;

  /// 本机改了随机 / 循环时调用：经 Connect 命令发给服务端（本机即目标设备），其他设备同步显示。
  Future<bool> Function({
    bool? shuffle,
    bool? repeatContext,
    bool? repeatTrack,
  })?
  onLocalOptions;
  bool _applyingOptions = false;
  late bool _lastShuffle = playback.shuffle;
  late SpotifyRepeatMode _lastRepeat = playback.repeatMode;

  bool _optionsPending = false;
  Timer? _optionsTimer;
  bool? _expectedShuffle;
  SpotifyRepeatMode? _expectedRepeat;

  PlaybackReceiverHost(
    this.playback, {
    this.handoverRetryDelay = const Duration(seconds: 2),
  }) : _lastVolume = playback.volume {
    playback.syncOptionsBeforeApply = syncLocalOptions;
    playback.receiverWindow = _window;
    playback.addListener(_onPlaybackChanged);
    playback.positionNotifier.addListener(_onPosition);
  }

  void dispose() {
    _disposed = true;
    _optionsTimer?.cancel();
    if (identical(playback.syncOptionsBeforeApply, syncLocalOptions)) {
      playback.syncOptionsBeforeApply = null;
    }
    if (identical(playback.receiverWindow, _window)) {
      playback.receiverWindow = null;
    }
    ++_handoverGeneration;
    _handoverRetry?.cancel();
    playback.removeListener(_onPlaybackChanged);
    playback.positionNotifier.removeListener(_onPosition);
  }

  @override
  Future<void> load(
    TpStateMachine machine,
    List<int> order, {
    required int positionMs,
    required bool paused,
  }) async {
    final generation = ++_commandGeneration;
    final tracks = [
      for (final i in order)
        if (machine.state(i) case final state?)
          if (machine.trackOf(state) case final t?)
            if (!t.isAdvertisement) _toTrack(t),
    ];
    if (tracks.isEmpty) return;
    // 交接回来的就是正在放的这首：只对齐进度 / 暂停，不重新加载
    if (playback.currentTrack?.uri == tracks.first.uri) {
      _lastTrackUri = tracks.first.uri;
      updateQueue(machine, order);
      return sync(positionMs: positionMs, paused: paused);
    }
    await _apply(() async {
      _lastTrackUri = tracks.first.uri;
      await playback.playReceiverQueue(
        tracks,
        startAt: Duration(milliseconds: positionMs),
        paused: paused,
      );
      // 服务端已经排过随机顺序，本机不要再随机一次。
      if (generation == _commandGeneration &&
          playback.currentTrack?.uri == tracks.first.uri) {
        playback.updateReceiverQueue(tracks);
      }
    });
  }

  List<SpotifyTrack> _window() {
    final w = receiver.window;
    if (w == null) return const [];
    return [
      for (final i in w.order)
        if (w.machine.state(i) case final state?)
          if (w.machine.trackOf(state) case final track?)
            if (!track.isAdvertisement) _toTrack(track),
    ];
  }

  @override
  void updateQueue(TpStateMachine machine, List<int> order) {
    _applyingCount++;
    try {
      playback.updateReceiverQueue([
        for (final i in order)
          if (machine.state(i) case final state?)
            if (machine.trackOf(state) case final track?)
              if (!track.isAdvertisement) _toTrack(track),
      ]);
    } finally {
      _applyingCount--;
    }
  }

  @override
  int get positionMs => playback.position.inMilliseconds;

  Future<bool> syncLocalOptions({
    bool? shuffle,
    SpotifyRepeatMode? repeat,
  }) async {
    final sender = onLocalOptions;
    if (!receiver.isActive || sender == null) return true;
    _optionsTimer?.cancel();
    _optionsPending = true;
    _expectedShuffle = shuffle;
    _expectedRepeat = repeat;
    if (shuffle != null) _lastShuffle = shuffle;
    if (repeat != null) _lastRepeat = repeat;
    _optionsTimer = Timer(const Duration(seconds: 5), () {
      _optionsPending = false;
      _expectedShuffle = null;
      _expectedRepeat = null;
    });
    final ok = await sender(
      shuffle: shuffle,
      repeatContext: repeat == null ? null : repeat != SpotifyRepeatMode.off,
      repeatTrack: repeat == null ? null : repeat == SpotifyRepeatMode.track,
    );
    if (!ok) {
      _optionsPending = false;
      _optionsTimer?.cancel();
    }
    return ok;
  }

  @override
  void applyOptions(TpOptions options) {
    _applyingOptions = true;
    try {
      if (_optionsPending) {
        final matchesRepeat =
            _expectedRepeat == null || _repeatModeOf(options) == _expectedRepeat;
        final matchesShuffle =
            _expectedShuffle == null || options.shuffle == _expectedShuffle;
        if (!matchesRepeat || !matchesShuffle) return;
        _optionsPending = false;
        _optionsTimer?.cancel();
      }
      if (options.shuffle case final shuffle?) playback.setShuffle(shuffle);
      if (options.repeatTrack != null || options.repeatContext != null) {
        playback.setRepeatMode(_repeatModeOf(options));
      }
      _lastShuffle = playback.shuffle;
      _lastRepeat = playback.repeatMode;
    } finally {
      _applyingOptions = false;
    }
  }

  static SpotifyRepeatMode _repeatModeOf(TpOptions options) {
    if (options.repeatTrack == true) return SpotifyRepeatMode.track;
    if (options.repeatContext == true) return SpotifyRepeatMode.context;
    return SpotifyRepeatMode.off;
  }

  @override
  Future<void> sync({required int? positionMs, required bool paused}) {
    final generation = ++_commandGeneration;
    return _apply(() async {
      if (positionMs != null &&
          (playback.position.inMilliseconds - positionMs).abs() > 2000) {
        await playback.seekTo(Duration(milliseconds: positionMs));
      }
      if (generation != _commandGeneration) return;
      if (paused) {
        await playback.pause();
      } else if (!playback.isPlaying && !playback.isLoadingTrack) {
        // A remote resume while loading keeps the pending play intent. The UI
        // toggle cancels loading, so it must not be used for this state sync.
        await playback.togglePlayPause();
      }
    });
  }

  /// 注册恢复后重新尝试同步仍在本机播放的歌曲。
  void onReceiverRegistered() {
    if (_disposed) return;
    _handoverRetry?.cancel();
    _handedOverUri = null;
    _handoverAttempts = 0;
    _tryHandOver();
  }

  void _tryHandOver() {
    if (_disposed ||
        _applying ||
        _handingOver ||
        (_handoverRetry?.isActive ?? false))
      return;
    final track = playback.currentTrack;
    if (!playback.isPlaying || receiver.isActive || track == null) return;
    if (_handoverTrackUri != track.uri) {
      _handoverTrackUri = track.uri;
      _handoverAttempts = 0;
    }
    final hand = handOver;
    if (hand == null || _handedOverUri == track.uri || _handoverAttempts >= 3)
      return;
    _handoverRetry?.cancel();
    _handingOver = true;
    final generation = _handoverGeneration;
    _handoverAttempts++;
    unawaited(() async {
      var succeeded = false;
      try {
        succeeded = await hand(playback.position.inMilliseconds);
      } catch (_) {
        // 注册尚未可见或临时网络错误：最多再尝试两次。
      } finally {
        _handingOver = false;
      }
      if (_disposed) return;
      if (generation != _handoverGeneration) {
        // An explicit local resume may have happened while this revoked request
        // was still in flight. Re-evaluate the current intent, never its result.
        _tryHandOver();
        return;
      }
      if (succeeded) _handedOverUri = track.uri;
      if (!succeeded || playback.currentTrack?.uri != track.uri) {
        _handoverRetry = Timer(handoverRetryDelay, _tryHandOver);
      }
    }());
  }

  @override
  void setVolume(double volume) {
    _lastVolume = volume;
    playback.setVolume(volume, persist: true);
  }

  @override
  Future<void> stop() {
    ++_commandGeneration;
    ++_handoverGeneration;
    _handoverRetry?.cancel();
    _handoverRetry = null;
    _handedOverUri = null;
    _handoverAttempts = 0;
    return _apply(playback.pause);
  }

  Future<void> _apply(Future<void> Function() action) async {
    _applyingCount++;
    try {
      await action();
    } finally {
      _applyingCount--;
      _lastPlaying = playback.isPlaying;
      _lastPositionMs = playback.position.inMilliseconds;
    }
  }

  void _onPlaybackChanged() {
    if (_applying) return;
    final track = playback.currentTrack;
    final durationMs = playback.duration.inMilliseconds;
    final position = playback.position.inMilliseconds;
    if (track != null && track.uri != _lastTrackUri) {
      _lastTrackUri = track.uri;
      receiver.onLocalTrackChanged(track.uri, durationMs: durationMs);
    }
    // 出声了但服务端不知道：失败允许有限重试，成功后不重复交接。
    if (!playback.isPlaying && !playback.isBuffering) {
      _handedOverUri = null;
      _handoverAttempts = 0;
      _handoverRetry?.cancel();
    }
    _tryHandOver();
    // 加载 / 缓冲中的「未播放」不算暂停
    if (!playback.isBuffering && playback.isPlaying != _lastPlaying) {
      _lastPlaying = playback.isPlaying;
      receiver.onLocalPausedChanged(
        !_lastPlaying,
        positionMs: position,
        durationMs: durationMs,
      );
    }
    if (!_applyingOptions &&
        !_optionsPending &&
        (playback.shuffle != _lastShuffle ||
            playback.repeatMode != _lastRepeat)) {
      final shuffleChanged = playback.shuffle != _lastShuffle;
      final repeatChanged = playback.repeatMode != _lastRepeat;
      _lastShuffle = playback.shuffle;
      _lastRepeat = playback.repeatMode;
      if (receiver.isActive) {
        onLocalOptions?.call(
          shuffle: shuffleChanged ? _lastShuffle : null,
          repeatContext: repeatChanged ? _lastRepeat != SpotifyRepeatMode.off : null,
          repeatTrack: repeatChanged ? _lastRepeat == SpotifyRepeatMode.track : null,
        );
      }
    }
    if ((playback.volume - _lastVolume).abs() > 0.01) {
      _lastVolume = playback.volume;
      receiver.onLocalVolume(_lastVolume);
    }
  }

  void _onPosition() {
    final pos = playback.position.inMilliseconds;
    final prev = _lastPositionMs;
    _lastPositionMs = pos;
    if (_applying) return;
    final durationMs = playback.duration.inMilliseconds;
    // 进度流约每 200ms 一次，跳变超过 3 秒视为拖动
    if ((pos - prev).abs() > 3000 &&
        playback.currentTrack?.uri == _lastTrackUri) {
      receiver.onLocalSeek(prev, pos, durationMs: durationMs);
    }
    receiver.onLocalProgress(pos, durationMs: durationMs);
  }

  static SpotifyTrack _toTrack(TpTrack t) {
    String idOf(String uri) => uri.split(':').last;
    final images = [for (final url in t.imageUrls) SpotifyImage(url: url)];
    return SpotifyTrack(
      id: idOf(t.uri),
      name: t.name,
      uri: t.uri,
      durationMs: t.durationMs,
      explicit: t.explicit,
      artists: [
        for (final a in t.artists)
          SpotifyArtist(id: idOf(a.uri), name: a.name, uri: a.uri),
      ],
      album: SpotifyAlbum(
        id: idOf(t.albumUri),
        name: t.albumName,
        uri: t.albumUri,
        images: images,
      ),
    );
  }
}
