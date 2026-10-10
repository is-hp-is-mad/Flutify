import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/audio_playback_info.dart';
import 'package:just_audio/just_audio.dart';

import '../models/playback_context.dart';
import '../models/playback_error.dart';
import '../models/playback_retry.dart';
import '../models/playback_session.dart';
import '../models/playback_state.dart';
import '../models/track.dart';
import '../services/audio/audio_engine.dart';
import '../services/playback_session_store.dart';
import '../services/network/network_failure.dart';
import '../services/protocol/track_audio_loader.dart';
import '../services/storage_service.dart';

export '../models/playback_error.dart';

/// 队列条目：[uid] 在所属列表中唯一，用作拖拽排序时的稳定 Key
/// （同一首歌可能被多次加入队列）。
class QueueEntry {
  final int uid;
  final SpotifyTrack track;

  const QueueEntry(this.uid, this.track);
}

/// 远程播放接管：见 [PlaybackProvider.remotePlay]。
typedef RemotePlayHandler =
    Future<bool> Function(
      PlaybackContext context,
      List<SpotifyTrack> tracks,
      SpotifyTrack? start,
    );

/// 播放状态与队列管理。
///
/// 性能约定：
/// - 播放进度（每秒多次）只写入 [positionNotifier]，**不会**调用 notifyListeners，
///   需要进度的组件通过 ValueListenableBuilder 局部重建。
/// - 其余低频状态（切歌、播放/暂停、随机、循环、队列、音量）走 notifyListeners，
///   组件应使用 `context.select` 只订阅自己关心的字段。
///
/// 队列语义与 Spotify 一致：
/// - [userQueue]：用户手动 "Add to queue" 的曲目，优先播放（Next in queue）。
/// - [upNext]：当前上下文（歌单/专辑等）中剩余的曲目（Next from: ...）。
class PlaybackProvider extends ChangeNotifier {
  final AudioEngine _audio;
  final StorageService _storage;

  /// 协议链路完整曲目加载器（AP 密钥 + CDN 解密）；为空（未接入）时任何曲目都无法播放，
  /// 会报 [TrackPlaybackFailure.notSignedIn] 错误。
  final TrackAudioSource? audioLoader;

  /// 上次播放会话的存储；为空时不还原也不保存（测试默认）。
  final PlaybackSessionStore? sessionStore;
  final Random _random;

  /// 远程播放接管（由 main.dart 接上 Spotify Connect）：点歌时先问它，返回 true 表示已交给远程设备播放，
  /// 本机不再加载；[start] 为 null 表示从头播放整个上下文。为空或返回 false 时照常在本机播放。
  RemotePlayHandler? remotePlay;

  /// 还原会话后、或尚未加载音频时拖动进度条：下次加载这首歌时从这里开始播放。
  Duration? _resumeAt;

  /// 会话保存：同一事件循环内的多次变化合并为一次写入。
  bool _saveScheduled = false;

  /// 上次保存会话时的播放进度；播放中进度每推进 [_positionSaveInterval] 保存一次。
  Duration _savedPosition = Duration.zero;
  static const Duration _positionSaveInterval = Duration(seconds: 15);

  /// 协议加载代次号：连续切歌时丢弃过期的加载结果，避免串音。
  int _loadGeneration = 0;
  int _playIntent = 0;
  int _networkRetries = 0;
  Timer? _retryTimer;
  Completer<void>? _retryWait;
  final ValueNotifier<PlaybackRetry?> retryNotifier = ValueNotifier(null);

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final wait = _retryWait;
    _retryWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
    retryNotifier.value = null;
  }

  Future<bool> _waitForRetry(Object error, int generation) async {
    if (!isConnectionFailure(error) || _networkRetries >= PlaybackRetry.limit) {
      return false;
    }
    final attempt = ++_networkRetries;
    final delay = Duration(seconds: attempt);
    final wait = Completer<void>();
    _retryWait = wait;
    retryNotifier.value = PlaybackRetry(attempt, delay);
    _retryTimer = Timer(delay, () => wait.complete());
    await wait.future;
    if (generation != _loadGeneration) return false;
    _retryWait = null;
    _retryTimer = null;
    retryNotifier.value = PlaybackRetry(attempt, delay, waiting: false);
    return true;
  }

  /// 已经把音频交给播放器的曲目 id；与当前曲目不一致时，点播放需要（重新）加载。
  String? _loadedTrackId;
  LoadedAudio? _currentAudio;
  bool _currentDownloadReady = false;
  bool _prefetching = false;
  String? _prefetchedTrackId;

  /// 随机列表循环的下一轮顺序：预取与实际切歌共用，避免切歌时再次洗牌。
  List<int>? _nextCycleOrder;
  AudioPlaybackInfo _audioPlaybackInfo = const AudioPlaybackInfo();
  AudioPlaybackInfo get audioPlaybackInfo =>
      _loadedTrackId != null && _loadedTrackId == _currentTrack?.id
      ? _audioPlaybackInfo
      : const AudioPlaybackInfo();

  /// 连续「不可播放 → 自动跳过」的次数；超过一轮上下文长度就停下，避免整个歌单都不可播时死循环。
  int _consecutiveSkips = 0;

  /// 连续多少首不可播放时自动暂停（[pauseAfterFailures] 开启时生效）。
  static const int failureLimit = 3;

  bool _pauseAfterFailures;

  /// 最近一次播放失败（成功开始播放新曲目或调用 [clearPlaybackError] 后为 null）。
  PlaybackError? _playbackError;
  int _errorSerial = 0;
  final StreamController<PlaybackError> _errorController =
      StreamController<PlaybackError>.broadcast();

  /// 曲目下载 / 解密进度（0~1），仅在 [isBuffering] 且走完整加载时有意义。
  final ValueNotifier<double> loadProgressNotifier = ValueNotifier(0);

  /// 高频进度通知器，独立于 ChangeNotifier。
  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);

  SpotifyTrack? _currentTrack;
  PlaybackContext _context = PlaybackContext.none;

  /// 上下文原始曲目顺序。
  List<SpotifyTrack> _contextTracks = [];

  ({
    Object ticket,
    PlaybackContext context,
    List<SpotifyTrack> tracks,
    String? startUri,
  })?
  _receiverQueue;

  /// Connect 只下发短窗口；先保留点歌入口已经拿到的完整上下文。
  /// ticket 防止旧请求失败后清掉后一次点歌的队列。
  Object prepareReceiverQueue(
    PlaybackContext context,
    List<SpotifyTrack> tracks,
    SpotifyTrack? start,
  ) {
    final ticket = Object();
    _receiverQueue = (
      ticket: ticket,
      context: context,
      tracks: List.of(tracks),
      startUri: start?.uri,
    );
    return ticket;
  }

  void cancelReceiverQueue(Object ticket) {
    if (identical(_receiverQueue?.ticket, ticket)) _receiverQueue = null;
  }

  /// 实际播放顺序（指向 [_contextTracks] 的下标），随机播放时为洗牌后的顺序。
  List<int> _order = [];

  /// 当前上下文曲目在 [_order] 中的位置。
  int _orderPos = 0;

  final List<QueueEntry> _userQueue = [];
  int _nextQueueUid = 0;

  bool _isPlaying = false;
  bool _isBuffering = false;

  // Internal pauses while replacing a source are not user pauses. Keep the
  // playback session active until the new source reports playing or is cancelled.
  bool _isStartingPlayback = false;

  /// 正在通过协议链路加载曲目（下载 + 解密），此时播放器还没有新音源。
  bool _isLoadingTrack = false;
  Duration _duration = Duration.zero;
  bool _shuffle = false;
  SpotifyRepeatMode _repeatMode = SpotifyRepeatMode.off;
  double _volume;
  double _volumeBeforeMute;
  ProcessingState? _lastProcessingState;

  bool _normalize;
  int _fadeSeconds;

  /// 当前曲目文件的响度数据（音量均衡用）；未知时为 null（倍率按 1）。
  AudioNormalization? _normalization;

  /// 淡入淡出倍率（0–1），由进度驱动。
  double _fadeFactor = 1;

  /// 上次真正下发给播放器的音量；初始 -1 保证第一次一定下发。
  double _appliedVolume = -1;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<EmePlaybackException>? _emeErrSub;

  PlaybackProvider(
    AudioEngine audio,
    this._storage, {
    Random? random,
    this.audioLoader,
    this.sessionStore,
  }) : _audio = audio,
       _random = random ?? Random(),
       _pauseAfterFailures = _storage.pauseAfterFailures,
       _volume = _storage.volume,
       _volumeBeforeMute = _storage.volume > 0 ? _storage.volume : 0.8,
       _normalize = _storage.normalizeVolume,
       _fadeSeconds = _storage.fadeSeconds.clamp(0, maxFadeSeconds) {
    _initAudioListeners();
    _applyVolume();
    // 有上次会话时还原为「暂停在上次的位置」；否则没有当前曲目，播放器条隐藏，直到用户点播一首歌
    _restoreSession();
  }

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------
  SpotifyTrack? get currentTrack => _currentTrack;

  /// 最近一次播放失败；UI 读取后提示用户，并可调用 [clearPlaybackError] 清除。
  /// 对话框 / SnackBar 建议监听 [playbackErrors]（每次失败触发一次事件）。
  PlaybackError? get playbackError => _playbackError;

  /// 播放失败事件流（广播）：不可播放、未登录、网络错误等都会在这里发出一次。
  Stream<PlaybackError> get playbackErrors => _errorController.stream;
  PlaybackContext get playbackContext => _context;
  bool get isPlaying => _isPlaying;

  /// Playback intent for system media controls, including automatic transitions
  /// and pending starts. Unlike [isPlaying], this survives internal source pauses
  /// so Android does not drop its foreground service / wake lock between tracks.
  bool get isPlaybackActive => _isPlaying || _isStartingPlayback;

  /// 缓冲中：播放器自身缓冲，或正在下载 / 解密整首曲目。
  bool get isBuffering => _isBuffering || _isLoadingTrack;
  bool get isLoadingTrack => _isLoadingTrack;
  Duration get position => positionNotifier.value;
  Duration get duration => _duration;
  bool get shuffle => _shuffle;
  SpotifyRepeatMode get repeatMode => _repeatMode;
  double get volume => _volume;

  /// 连续 [failureLimit] 首无法播放时自动暂停，而不是继续跳过（设置页「播放」分组，持久化）。
  bool get pauseAfterFailures => _pauseAfterFailures;

  void setPauseAfterFailures(bool value) {
    if (value == _pauseAfterFailures) return;
    _pauseAfterFailures = value;
    _storage.setPauseAfterFailures(value);
    notifyListeners();
  }

  /// 用户手动添加的待播队列（只读）。
  List<QueueEntry> get userQueue => List.unmodifiable(_userQueue);

  /// 系统媒体卡片与实际 nextTrack 使用同一套规则，包括列表末尾回绕。
  bool get canSkipNext =>
      _userQueue.isNotEmpty ||
      _orderPos + 1 < _order.length ||
      (_repeatMode == SpotifyRepeatMode.context && _order.isNotEmpty);

  /// 上下文中接下来要播放的曲目（按实际播放顺序），uid 为其在上下文中的下标。
  List<QueueEntry> get upNext {
    if (_order.isEmpty || _orderPos + 1 >= _order.length) return const [];
    return [
      for (final i in _order.sublist(_orderPos + 1))
        QueueEntry(i, _contextTracks[i]),
    ];
  }

  /// 当前曲目播完后暂停、不接下一首（睡眠定时器「本首结束时」）；生效一次后自动复位。
  bool get stopAfterCurrent => _stopAfterCurrent;
  bool _stopAfterCurrent = false;

  set stopAfterCurrent(bool value) {
    if (value == _stopAfterCurrent) return;
    _stopAfterCurrent = value;
    _prefetchNext();
    notifyListeners();
  }

  /// 暂停，并取消尚未完成的加载，避免设备转走后本机又开始出声。
  Future<void> pause() async {
    ++_playIntent;
    ++_loadGeneration;
    _cancelRetry();
    _isStartingPlayback = false;
    if (_isPlaying) _scheduleSave();
    _isPlaying = false;
    _isBuffering = false;
    if (_isLoadingTrack) {
      _loadedTrackId = null;
      _resumeAt = position;
      _isLoadingTrack = false;
    }
    // Dispatch before notifying: a listener may issue a newer resume command.
    final pausing = Future<void>.sync(_audio.pause);
    notifyListeners();
    await pausing;
  }

  bool isCurrent(String trackId) => _currentTrack?.id == trackId;

  /// 当前是否正在播放给定上下文（用于详情页大播放按钮的 播放/暂停 状态）。
  bool isPlayingContext(String contextUri) =>
      _isPlaying && contextUri.isNotEmpty && _context.uri == contextUri;

  // ---------------------------------------------------------------------------
  // Audio engine listeners
  // ---------------------------------------------------------------------------
  void _initAudioListeners() {
    _posSub = _audio.positionStream.listen((pos) {
      // 还原会话后音频尚未加载：播放器报的 0 不能覆盖还原的进度
      if (_loadedTrackId == null && _resumeAt != null) return;
      positionNotifier.value = pos;
      if (_fadeSeconds > 0) _updateFade(pos);
      if ((pos - _savedPosition).abs() >= _positionSaveInterval)
        _scheduleSave();
    });

    _durSub = _audio.durationStream.listen((dur) {
      if (dur != null && dur != Duration.zero && dur != _duration) {
        _duration = dur;
        notifyListeners();
      }
    });

    _stateSub = _audio.playerStateStream.listen((state) {
      final generation = _loadGeneration;
      final ps = state.processingState;
      final playing = state.playing && ps != ProcessingState.completed;
      final buffering =
          ps == ProcessingState.loading || ps == ProcessingState.buffering;
      final ended = ps == ProcessingState.completed &&
          _lastProcessingState != ProcessingState.completed;
      _lastProcessingState = ps;

      // Set continuation intent BEFORE notifying media controls of completion.
      // Loading the next source (and repeat-one's seek) can take arbitrarily long.
      final wasStarting = _isStartingPlayback;
      if (ended) {
        _isStartingPlayback = !_stopAfterCurrent &&
            (_repeatMode == SpotifyRepeatMode.track || canSkipNext);
      } else if (playing &&
          _loadedTrackId != null &&
          _loadedTrackId == _currentTrack?.id) {
        _isStartingPlayback = false;
      }

      if (_isPlaying != playing ||
          _isBuffering != buffering ||
          wasStarting != _isStartingPlayback) {
        // 暂停时记下进度：之后关掉 App 也能从这里继续
        if (_isPlaying && !playing) _scheduleSave();
        _isPlaying = playing;
        _isBuffering = buffering;
        notifyListeners();
      }

      // 只在「进入 completed」的那一刻处理，避免重复事件导致连跳多首。
      if (ended && generation == _loadGeneration) {
        _handleTrackEnded();
      }
    });

    // EME 运行期错误（license / HLS fatal 等在加载成功后才暴露）：
    // 转成可见的播放错误，不再静默停在 0:00
    _emeErrSub = _audio.emeErrors.listen(_onEmeError);
  }

  void _handleTrackEnded() {
    if (_stopAfterCurrent) {
      // 睡眠定时器「本首结束时」：停在本首开头，不接下一首（单曲循环也停）
      _stopAfterCurrent = false;
      unawaited(pause());
      seekTo(Duration.zero);
      notifyListeners();
      return;
    }
    if (_repeatMode == SpotifyRepeatMode.track) {
      unawaited(_repeatCurrentTrack());
    } else {
      nextTrack();
    }
  }

  Future<void> _repeatCurrentTrack() async {
    final track = _currentTrack;
    if (track == null) return;
    final generation = ++_loadGeneration;
    try {
      await seekTo(Duration.zero);
      if (generation != _loadGeneration) return;
      _resumeAudio(track, generation);
    } catch (error) {
      if (generation != _loadGeneration) return;
      await _handleLoadFailure(track, _asPlaybackFailure(error));
    }
  }

  void _resumeAudio(SpotifyTrack track, int generation) {
    // just_audio can already be playing after repeat-one's seek. Its no-op
    // play() then emits no new state, so do not re-arm the pending-start flag.
    _isStartingPlayback = !_isPlaying;
    notifyListeners();
    if (generation != _loadGeneration) return;
    // play() 要到暂停 / 结束才完成；异步起播错误仍需进入可重试的错误状态。
    unawaited(
      _audio.play().catchError((Object error) async {
        if (generation != _loadGeneration || _currentTrack?.id != track.id)
          return;
        _loadedTrackId = null;
        _resumeAt = position;
        if (isConnectionFailure(error)) {
          await _playAudio(track, connectionError: error);
          return;
        }
        await _handleLoadFailure(
          track,
          TrackPlaybackException(
            TrackPlaybackFailure.network,
            '播放失败，请稍后重试',
            error,
          ),
        );
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Order helpers
  // ---------------------------------------------------------------------------

  /// 以 [currentIndex] 为当前曲目重建播放顺序。
  /// 随机模式：当前曲目置顶，其余洗牌；顺序模式：自然顺序。
  void _rebuildOrder(int currentIndex) {
    _nextCycleOrder = null;
    final n = _contextTracks.length;
    if (n == 0) {
      _order = [];
      _orderPos = 0;
      return;
    }
    if (_shuffle) {
      final rest = [
        for (var i = 0; i < n; i++)
          if (i != currentIndex) i,
      ]..shuffle(_random);
      _order = [currentIndex, ...rest];
      _orderPos = 0;
    } else {
      _order = List.generate(n, (i) => i);
      _orderPos = currentIndex;
    }
  }

  Future<void> _startTrack(
    SpotifyTrack track, {
    bool isRetry = false,
    Duration? startAt,
    bool deferLoad = false,
  }) async {
    final intent = ++_playIntent;
    _isStartingPlayback = !deferLoad;
    if (deferLoad) _isPlaying = false;
    _currentAudio = null;
    _nextCycleOrder = null;
    _currentTrack = track;
    _duration = Duration(milliseconds: track.durationMs);
    positionNotifier.value = startAt ?? Duration.zero;
    _resumeAt = startAt;
    _scheduleSave();
    if (!isRetry) {
      _consecutiveSkips = 0;
      // 用户主动开始新曲目：旧错误作废。自动跳过时保留，让 UI 能读到「哪首被跳过、为什么」
      _playbackError = null;
    }
    notifyListeners();
    if (intent != _playIntent) return;
    if (deferLoad) {
      // 只切到这首歌、暂停在 startAt，点播放时才加载（_loadedTrackId 不匹配 → 重新加载）
      ++_loadGeneration;
      _cancelRetry();
      _loadedTrackId = null;
      _setLoading(false);
      await _audio.pause();
      return;
    }
    await _playAudio(track);
  }

  /// 通过协议链路加载并播放完整曲目（metadata → AP 音频密钥 → CDN 解密）。
  ///
  /// 已缓存的曲目直接播放本地文件；未缓存时文件头一到就边下边播，不等整首下载完。
  /// 有 [_resumeAt]（还原的会话 / 加载前拖动过进度）时从该位置开始。
  ///
  /// 失败规则：
  /// - [TrackPlaybackFailure.unavailable]（无权限 / DRM / 地区限制 / 文件损坏）：记录错误并自动跳到下一首；
  /// - [TrackPlaybackFailure.notSignedIn] / [TrackPlaybackFailure.network]：记录错误并停在当前曲目，
  ///   用户再点播放即重试，不跳歌（跳过没有意义）。
  Future<void> _playAudio(SpotifyTrack track, {Object? connectionError}) async {
    final generation = ++_loadGeneration;
    _cancelRetry();
    if (connectionError == null) _networkRetries = 0;
    _loadedTrackId = null;
    _currentAudio = null;
    _currentDownloadReady = false;
    _prefetchedTrackId = null;
    _isStartingPlayback = true;
    loadProgressNotifier.value = 0;
    _setLoading(true);
    if (generation != _loadGeneration) return;
    // 新曲目加载期间先停掉上一首，避免「点了新歌还在放旧歌」
    try {
      await _audio.pause();
    } catch (error) {
      if (generation == _loadGeneration) {
        await _handleLoadFailure(track, _asPlaybackFailure(error));
      }
      return;
    }
    if (generation != _loadGeneration) return;

    if (connectionError != null) {
      final retry = await _waitForRetry(connectionError, generation);
      if (generation != _loadGeneration) return;
      if (!retry) {
        await _handleLoadFailure(track, _asPlaybackFailure(connectionError));
        return;
      }
    }
    while (generation == _loadGeneration) {
      try {
        final loader = audioLoader;
        if (loader == null) {
          throw const TrackPlaybackException(
            TrackPlaybackFailure.notSignedIn,
            '请先登录 Spotify 账号再播放',
          );
        }
        if (!track.isPlayable) {
          throw const TrackPlaybackException(
            TrackPlaybackFailure.unavailable,
            '这首歌在你所在的地区暂不可播放',
          );
        }
        // 单集必须传完整 URI（加载器按 spotify:episode: 前缀走 mercury 单集链路）；
        // 曲目优先传 id（缓存键与历史行为一致）。
        final audio = await loader.open(
          track.uri.startsWith('spotify:episode:')
              ? track.uri
              : (track.id.isNotEmpty ? track.id : track.uri),
          progress: (p) {
            if (generation == _loadGeneration) loadProgressNotifier.value = p;
          },
        );
        if (generation != _loadGeneration) return; // 已切歌，丢弃
        final resumeAt = _resumeAt;
        // 新文件的均衡倍率；开启淡入时从静音起步，由进度流逐步升起
        _normalization = audio.normalization;
        _updateFade(resumeAt ?? Duration.zero);
        _applyVolume();
        final eme = audio.emeContent;
        final stream = audio.stream;
        if (eme != null) {
          // DRM 曲目：走 EME 引擎（WebView2 Widevine 解密播放）
          await _audio.playEme(eme, initialPosition: resumeAt, autoplay: false);
        } else if (stream != null) {
          await _audio.playStream(
            stream,
            initialPosition: resumeAt,
            autoplay: false,
          );
          _watchStream(stream, track, generation);
        } else {
          await _audio.playFile(
            audio.path,
            initialPosition: resumeAt,
            autoplay: false,
          );
        }
        if (generation != _loadGeneration) return;
        if (_resumeAt == resumeAt) _resumeAt = null;
        // 加载音源期间也可能收到新的 seek；在开始出声前应用最新进度。
        var startPosition = resumeAt;
        while (_resumeAt != null) {
          startPosition = _resumeAt;
          _resumeAt = null;
          await _audio.seek(startPosition!);
          if (generation != _loadGeneration) return;
        }
        _loadedTrackId = track.id;
        _audioPlaybackInfo = audio.playbackInfo;
        _resumeAudio(track, generation);
        if (generation != _loadGeneration) return;
        if (startPosition != null) positionNotifier.value = startPosition;
        _consecutiveSkips = 0;
        // 等整首下载完再预取；暂停不应丢掉下载完成信号，切歌则丢弃旧结果。
        // 在 ready 通知前登记，监听器同步切歌时的新状态不能被旧曲目覆盖。
        _currentAudio = audio;
        final downloadComplete = audio.downloadComplete ?? stream?.done;
        _currentDownloadReady = downloadComplete == null;
        downloadComplete?.then((_) {
          if (!identical(_currentAudio, audio)) return;
          _currentDownloadReady = true;
          _prefetchNext();
        }, onError: (Object _) {});
        _setLoading(false);
        retryNotifier.value = null;
        _prefetchNext();
        return;
      } catch (e) {
        if (generation != _loadGeneration) return;
        final retry = await _waitForRetry(e, generation);
        if (generation != _loadGeneration) return;
        if (retry) {
          loadProgressNotifier.value = 0;
          continue;
        }
        retryNotifier.value = null;
        await _handleLoadFailure(track, _asPlaybackFailure(e));
        return;
      }
    }
  }

  TrackPlaybackException _asPlaybackFailure(Object error) =>
      error is TrackPlaybackException
      ? error
      : TrackPlaybackException(
          TrackPlaybackFailure.network,
          '播放失败，请稍后重试',
          error,
        );

  /// 处理加载失败：暴露错误状态；「不可播放」类自动跳到下一首（有上限）。
  ///
  /// 上限有两层：
  /// - 开启 [pauseAfterFailures]（默认）：连续第 [failureLimit] 首仍不可播放时停下，标记 autoPaused；
  /// - 始终：跳过次数不超过一轮上下文长度，避免整个歌单都不可播时死循环。
  Future<void> _handleLoadFailure(
    SpotifyTrack track,
    TrackPlaybackException failure,
  ) async {
    final failures = _consecutiveSkips + 1;
    final hitLimit =
        failure.shouldSkip && _pauseAfterFailures && failures >= failureLimit;
    final canSkip =
        failure.shouldSkip &&
        !hitLimit &&
        _consecutiveSkips < max(max(_order.length, _userQueue.length + 1), 1) &&
        (_userQueue.isNotEmpty ||
            _orderPos + 1 < _order.length ||
            _repeatMode == SpotifyRepeatMode.context);
    _playbackError = PlaybackError(
      serial: ++_errorSerial,
      track: track,
      exception: failure,
      skipped: canSkip,
      autoPaused: hitLimit,
      consecutiveFailures: failures,
    );
    _errorController.add(_playbackError!);
    if (!canSkip) {
      _isStartingPlayback = false;
      _isPlaying = false;
      _isBuffering = false;
    }
    _setLoading(false);
    if (canSkip) {
      _consecutiveSkips++;
      await nextTrack(isAutoSkip: true);
    } else {
      notifyListeners();
    }
  }

  /// EME 引擎运行期错误（license 换取失败 / HLS 致命错误 / Widevine 不可用）：
  /// 加载已成功、播放建立后才暴露的失败，复用 [_handleLoadFailure] 转成可见提示；
  /// 清掉 [_loadedTrackId] 并记下进度，下次点播放重新整载。
  void _onEmeError(EmePlaybackException err) {
    final track = _currentTrack;
    // 残留事件（已切歌 / 已换源）与重复事件（一次失败多次 HLS error）忽略
    if (track == null || _loadedTrackId != track.id) return;
    _loadedTrackId = null;
    _resumeAt = positionNotifier.value;
    final failure = err.webSignInSuggested
        ? TrackPlaybackException(
            TrackPlaybackFailure.webSignInRequired,
            'Web 登录态已失效，请重新完成 Web 登录',
            err,
          )
        : TrackPlaybackException(
            TrackPlaybackFailure.network,
            '全曲播放失败，请重试',
            err,
          );
    if (isConnectionFailure(failure)) {
      unawaited(_playAudio(track, connectionError: failure));
    } else {
      unawaited(_handleLoadFailure(track, failure));
    }
  }

  void _setLoading(bool value) {
    if (_isLoadingTrack == value) return;
    _isLoadingTrack = value;
    notifyListeners();
  }

  /// 边下边播途中下载彻底失败（已自动续传、换 CDN 仍不行）：已缓冲的部分会播完，
  /// 这里提示网络错误，并让下次点播放重新加载（不自动跳歌）。
  void _watchStream(
    ProgressiveAudio stream,
    SpotifyTrack track,
    int generation,
  ) {
    stream.done.catchError((Object e) {
      if (generation != _loadGeneration) return;
      _loadedTrackId = null;
      _resumeAt = positionNotifier.value;
      if (isConnectionFailure(e)) {
        unawaited(_playAudio(track, connectionError: e));
        return;
      }
      _playbackError = PlaybackError(
        serial: ++_errorSerial,
        track: track,
        exception: TrackPlaybackException(
          TrackPlaybackFailure.network,
          '音频下载中断，请检查网络后重试',
          e,
        ),
        skipped: false,
        autoPaused: false,
        consecutiveFailures: 1,
      );
      _errorController.add(_playbackError!);
      notifyListeners();
    });
  }

  List<int> _prepareNextCycle() {
    if (_nextCycleOrder == null) {
      _nextCycleOrder = List.of(_order);
      if (_shuffle) _nextCycleOrder!.shuffle(_random);
    }
    return _nextCycleOrder!;
  }

  /// 预取下一首（用户队列优先，其次上下文顺序）；只运行一个后台预取。
  void _prefetchNext() {
    final loader = audioLoader;
    if (loader == null ||
        _currentAudio == null ||
        _loadedTrackId != _currentTrack?.id ||
        !_currentDownloadReady ||
        _isLoadingTrack ||
        _stopAfterCurrent ||
        _repeatMode == SpotifyRepeatMode.track ||
        _prefetching) {
      return;
    }
    SpotifyTrack? next;
    if (_userQueue.isNotEmpty) {
      next = _userQueue.first.track;
    } else if (_orderPos + 1 < _order.length) {
      next = _contextTracks[_order[_orderPos + 1]];
    } else if (_repeatMode == SpotifyRepeatMode.context && _order.isNotEmpty) {
      next = _contextTracks[_prepareNextCycle().first];
    }
    // 长播客按需读取，不提前下载整集。
    if (next != null &&
        next.isPlayable &&
        next.id.isNotEmpty &&
        next.id != _prefetchedTrackId &&
        !next.uri.startsWith('spotify:episode:')) {
      final nextId = next.id;
      _prefetchedTrackId = nextId;
      _prefetching = true;
      unawaited(() async {
        try {
          await loader.prefetch(nextId);
        } catch (_) {
          // 预取不是播放失败；正式切歌时仍可按原流程重新加载。
        } finally {
          _prefetching = false;
          // 下载期间队列可能已经改变，只追赶最新的下一首。
          _prefetchNext();
        }
      }());
    }
  }

  /// 清除播放错误状态（UI 提示已读时调用）。
  void clearPlaybackError() {
    if (_playbackError == null) return;
    _playbackError = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Playback commands
  // ---------------------------------------------------------------------------

  /// 播放指定曲目。[contextQueue] 为所在列表（歌单/专辑/搜索结果），
  /// 未提供时以单曲作为上下文。
  Future<void> playTrack(
    SpotifyTrack track, {
    List<SpotifyTrack>? contextQueue,
    PlaybackContext? context,
  }) async {
    final intent = ++_playIntent;
    final remote = remotePlay;
    if (remote != null &&
        await remote(
          context ?? PlaybackContext.none,
          contextQueue ?? [track],
          track,
        ))
      return;
    if (intent != _playIntent) return;
    await _playLocal(track, contextQueue: contextQueue, context: context);
  }

  /// 在本机播放，不经 [remotePlay]：Connect 播放端收到远程命令时用，避免又转发回远程。
  /// 从 [startAt] 开始；[paused] 时加载完停在该处。
  Future<void> playLocal(
    SpotifyTrack track, {
    List<SpotifyTrack>? contextQueue,
    PlaybackContext? context,
    Duration? startAt,
    bool paused = false,
  }) async {
    ++_playIntent;
    await _playLocal(
      track,
      contextQueue: contextQueue,
      context: context,
      startAt: startAt,
      deferLoad: paused,
    );
  }

  /// 在本机播放（不经远程接管）。
  Future<void> _playLocal(
    SpotifyTrack track, {
    List<SpotifyTrack>? contextQueue,
    PlaybackContext? context,
    Duration? startAt,
    bool deferLoad = false,
  }) async {
    _receiverQueue = null;
    var tracks = (contextQueue == null || contextQueue.isEmpty)
        ? [track]
        : List.of(contextQueue);
    var index = tracks.indexWhere((t) => t.id == track.id);
    if (index == -1) {
      tracks = [track, ...tracks];
      index = 0;
    }
    _contextTracks = tracks;
    _context = context ?? PlaybackContext.none;
    _rebuildOrder(index);
    await _startTrack(track, startAt: startAt, deferLoad: deferLoad);
  }

  /// 接收服务端的实际顺序，不再在本机洗牌。匹配的完整上下文只补充
  /// 未下发的尾部；服务端改序或启用随机时绝不拼接原歌单顺序。
  Future<void> playReceiverQueue(
    List<SpotifyTrack> currentAndNext, {
    required Duration startAt,
    required bool paused,
  }) async {
    if (currentAndNext.isEmpty) return;
    final queue = _receiverOrder(currentAndNext);
    _contextTracks = queue.tracks;
    _context = queue.context;
    _order = List.generate(_contextTracks.length, (i) => i);
    _orderPos = queue.index;
    await _startTrack(
      currentAndNext.first,
      startAt: startAt,
      deferLoad: paused,
    );
  }

  ({List<SpotifyTrack> tracks, PlaybackContext context, int index})
  _receiverOrder(List<SpotifyTrack> window) {
    final seed = _receiverQueue;
    final matchesSeed =
        seed != null &&
        (seed.startUri == null || seed.startUri == window.first.uri) &&
        seed.tracks.any((t) => t.uri == window.first.uri);
    final existing = matchesSeed
        ? seed.tracks
        : [for (final i in _order) _contextTracks[i]];
    final context = matchesSeed ? seed.context : _context;
    if (matchesSeed) _receiverQueue = null;
    // 从当前位置往后匹配，重复曲目仍按播放位置区分。
    var index = existing.indexWhere(
      (t) => t.uri == window.first.uri,
      matchesSeed ? 0 : _orderPos.clamp(0, existing.length),
    );
    if (index < 0 && !matchesSeed)
      index = existing.indexWhere((t) => t.uri == window.first.uri);
    final prefix =
        index >= 0 &&
        window.length <= existing.length - index &&
        List.generate(
          window.length,
          (i) => existing[index + i].uri == window[i].uri,
        ).every((v) => v);
    // 已经由服务端确认的随机顺序可以保留；原歌单 seed 不代表随机后的顺序。
    if (prefix && !(matchesSeed && _shuffle)) {
      return (
        tracks: [
          ...existing.take(index),
          ...window,
          ...existing.skip(index + window.length),
        ],
        context: context,
        index: index,
      );
    }
    return (
      tracks: List.of(window),
      context: matchesSeed ? seed.context : PlaybackContext.none,
      index: 0,
    );
  }

  /// 更新 Connect 的滑动队列窗口，不重新加载音频或重置进度。
  /// 保留已播历史；本机已有完整列表且窗口是其前缀时，不截掉尚未下发的尾部。
  void updateReceiverQueue(List<SpotifyTrack> currentAndNext) {
    if (currentAndNext.isEmpty ||
        currentAndNext.first.uri != _currentTrack?.uri)
      return;
    final seed = _receiverQueue;
    if (seed != null &&
        (seed.startUri == null || seed.startUri == currentAndNext.first.uri) &&
        seed.tracks.any((t) => t.uri == currentAndNext.first.uri)) {
      final queue = _receiverOrder(currentAndNext);
      _contextTracks = queue.tracks;
      _context = queue.context;
      _order = List.generate(_contextTracks.length, (i) => i);
      _orderPos = queue.index;
      _queueChanged();
      return;
    }
    final existing = [for (final i in _order) _contextTracks[i]];
    final matchesCurrent =
        existing.isNotEmpty && existing[_orderPos].uri == _currentTrack?.uri;
    // 插队曲目播放时，_orderPos 仍指向上一首上下文曲目。
    // 该位置也属于历史，不能因为当前曲目不在上下文中就清空历史和尾部。
    final history = existing
        .take(matchesCurrent ? _orderPos : _orderPos + 1)
        .toList();
    final remaining = matchesCurrent
        ? existing.sublist(_orderPos)
        : [currentAndNext.first, ...existing.skip(_orderPos + 1)];
    final isPrefix =
        currentAndNext.length <= remaining.length &&
        List.generate(
          currentAndNext.length,
          (i) => currentAndNext[i].uri == remaining[i].uri,
        ).every((v) => v);
    final next = [
      ...currentAndNext,
      if (isPrefix) ...remaining.skip(currentAndNext.length),
    ];
    if (listEquals(
      existing.map((t) => t.uri).toList(),
      [...history, ...next].map((t) => t.uri).toList(),
    ))
      return;
    _contextTracks = [...history, ...next];
    _order = List.generate(_contextTracks.length, (i) => i);
    _orderPos = history.length;
    _queueChanged();
  }

  /// 从头播放整个上下文（详情页大播放按钮）。随机模式下从随机曲目开始。
  Future<void> playContext(
    List<SpotifyTrack> tracks,
    PlaybackContext context,
  ) async {
    if (tracks.isEmpty) return;
    // 远程设备按它自己的随机 / 循环设置从头播放
    final intent = ++_playIntent;
    final remote = remotePlay;
    if (remote != null && await remote(context, tracks, null)) return;
    if (intent != _playIntent) return;
    final start = _shuffle ? _random.nextInt(tracks.length) : 0;
    await _playLocal(tracks[start], contextQueue: tracks, context: context);
  }

  Future<void> togglePlayPause() async {
    final track = _currentTrack;
    if (track == null) return;

    if (_isLoadingTrack) {
      await pause();
      return;
    }
    if (isPlaybackActive) {
      await pause();
    } else if (_loadedTrackId != track.id) {
      // 还没加载过 / 上次加载失败（重试）
      _playbackError = null;
      await _playAudio(track);
    } else {
      _resumeAudio(track, _loadGeneration);
    }
  }

  /// 下一首。[isAutoSkip] 表示由「不可播放自动跳过」触发（不重置连续跳过计数）。
  Future<void> nextTrack({bool isAutoSkip = false}) async {
    if (_userQueue.isNotEmpty) {
      await _startTrack(_userQueue.removeAt(0).track, isRetry: isAutoSkip);
      return;
    }

    if (_orderPos + 1 < _order.length) {
      _orderPos++;
      await _startTrack(_contextTracks[_order[_orderPos]], isRetry: isAutoSkip);
      return;
    }

    if (_repeatMode == SpotifyRepeatMode.context && _order.isNotEmpty) {
      _order = _prepareNextCycle();
      _nextCycleOrder = null;
      _orderPos = 0;
      await _startTrack(_contextTracks[_order[_orderPos]], isRetry: isAutoSkip);
      return;
    }

    // 上下文播放完毕：停在当前曲目开头
    await pause();
    await seekTo(Duration.zero);
  }

  Future<void> previousTrack() async {
    if (_orderPos == 0 || _order.isEmpty) {
      await seekTo(Duration.zero);
      return;
    }
    _orderPos--;
    await _startTrack(_contextTracks[_order[_orderPos]]);
  }

  Future<void> seekTo(Duration pos) async {
    final maxMs = _duration.inMilliseconds;
    final clamped = Duration(
      milliseconds: pos.inMilliseconds.clamp(
        0,
        maxMs > 0 ? maxMs : pos.inMilliseconds,
      ),
    );
    positionNotifier.value = clamped;
    _scheduleSave();
    // 音频还没加载（还原的会话 / 上次加载失败）：记下位置，点播放时从这里开始
    if (_currentTrack != null && _loadedTrackId != _currentTrack!.id) {
      _resumeAt = clamped;
      return;
    }
    await _audio.seek(clamped);
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    if (_order.isNotEmpty) _rebuildOrder(_order[_orderPos]);
    _scheduleSave();
    _prefetchNext();
    notifyListeners();
  }

  /// 直接设定随机（Connect 远程命令用）；与当前相同时不重排。
  void setShuffle(bool value) {
    if (value != _shuffle) toggleShuffle();
  }

  /// 直接设定循环方式（Connect 远程命令用）。
  void setRepeatMode(SpotifyRepeatMode mode) {
    if (mode == _repeatMode) return;
    _repeatMode = mode;
    _nextCycleOrder = null;
    _scheduleSave();
    _prefetchNext();
    notifyListeners();
  }

  void cycleRepeatMode() {
    setRepeatMode(switch (_repeatMode) {
      SpotifyRepeatMode.off => SpotifyRepeatMode.context,
      SpotifyRepeatMode.context => SpotifyRepeatMode.track,
      SpotifyRepeatMode.track => SpotifyRepeatMode.off,
    });
  }

  // ---------------------------------------------------------------------------
  // 上次播放会话
  // ---------------------------------------------------------------------------

  /// 启动时还原：暂停在上次的曲目与进度，队列、随机、循环、播放来源一并还原。
  /// 音频不立即加载（避免启动就联网下载），点播放时再从记下的进度开始。
  void _restoreSession() {
    final session = sessionStore?.read();
    if (session == null) return;
    _currentTrack = session.current;
    _duration = Duration(milliseconds: session.current.durationMs);
    _context = session.context;
    _shuffle = session.shuffle;
    _repeatMode = session.repeatMode;
    // 保存的是播放顺序，还原后按自然顺序即为原来的顺序
    _contextTracks = List.of(session.tracks);
    _order = List.generate(_contextTracks.length, (i) => i);
    _orderPos = session.index;
    for (final t in session.userQueue) {
      _userQueue.add(QueueEntry(_nextQueueUid++, t));
    }
    final maxMs = _duration.inMilliseconds;
    final position = maxMs > 0 && session.position.inMilliseconds >= maxMs
        ? Duration.zero
        : session.position;
    positionNotifier.value = position;
    _savedPosition = position;
    _resumeAt = position > Duration.zero ? position : null;
  }

  /// 当前状态 → 会话快照；没有当前曲目时为 null。
  PlaybackSession? _snapshot() {
    final current = _currentTrack;
    if (current == null) return null;
    var tracks = const <SpotifyTrack>[];
    var index = 0;
    if (_order.isNotEmpty) {
      final from = max(0, _orderPos - PlaybackSession.maxBefore);
      final to = min(_order.length, _orderPos + 1 + PlaybackSession.maxAfter);
      tracks = [for (final i in _order.sublist(from, to)) _contextTracks[i]];
      index = _orderPos - from;
    }
    return PlaybackSession(
      tracks: tracks,
      index: index,
      current: current,
      userQueue: [
        for (final e in _userQueue.take(PlaybackSession.maxUserQueue)) e.track,
      ],
      context: _context,
      position: positionNotifier.value,
      shuffle: _shuffle,
      repeatMode: _repeatMode,
    );
  }

  /// 合并同一轮事件里的多次变化，只写一次。
  void _scheduleSave() {
    if (sessionStore == null || _saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() {
      _saveScheduled = false;
      unawaited(flushSession());
    });
  }

  /// 立即保存当前会话（退出 App / 切到后台时调用）。
  Future<void> flushSession() async {
    final store = sessionStore;
    final session = _snapshot();
    if (store == null || session == null) return;
    _savedPosition = session.position;
    await store.write(session);
  }

  /// 登出 / 切换账号：上次播放会话属于旧账号，停止播放并清除（内存 + 磁盘）。
  Future<void> discardSession() async {
    ++_playIntent;
    ++_loadGeneration;
    _cancelRetry();
    _isLoadingTrack = false;
    _isStartingPlayback = false;
    _loadedTrackId = null;
    _currentTrack = null;
    _currentAudio = null;
    _nextCycleOrder = null;
    _context = PlaybackContext.none;
    _contextTracks = [];
    _order = [];
    _orderPos = 0;
    _userQueue.clear();
    _resumeAt = null;
    _savedPosition = Duration.zero;
    _duration = Duration.zero;
    _isPlaying = false;
    positionNotifier.value = Duration.zero;
    loadProgressNotifier.value = 0;
    try {
      await _audio.stop();
    } catch (_) {}
    await sessionStore?.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Volume
  // ---------------------------------------------------------------------------

  /// 拖动过程中 [persist] 为 false，松手时再写盘，避免每帧写 SharedPreferences。
  void setVolume(double value, {bool persist = false}) {
    _volume = value.clamp(0.0, 1.0);
    if (_volume > 0) _volumeBeforeMute = _volume;
    _applyVolume();
    if (persist) _storage.setVolume(_volume);
    notifyListeners();
  }

  /// 音量均衡：按文件自带的响度数据衰减偏响的歌（设置页「播放」分组，持久化）。
  bool get normalizeVolume => _normalize;

  void setNormalizeVolume(bool value) {
    if (value == _normalize) return;
    _normalize = value;
    _storage.setNormalizeVolume(value);
    _applyVolume();
    notifyListeners();
  }

  /// 歌曲间淡入淡出时长（秒），0 为关闭。
  int get fadeSeconds => _fadeSeconds;

  void setFadeSeconds(int value) {
    final next = value.clamp(0, maxFadeSeconds);
    if (next == _fadeSeconds) return;
    _fadeSeconds = next;
    _storage.setFadeSeconds(next);
    _updateFade(positionNotifier.value);
    notifyListeners();
  }

  static const int maxFadeSeconds = 12;

  /// 实际交给播放器的音量 = 用户音量 × 均衡倍率 × 淡入淡出倍率。
  /// 与上次下发的值几乎相同时跳过（淡入淡出随进度流高频调用）。
  void _applyVolume() {
    final gain = _normalize ? (_normalization?.volumeFactor ?? 1.0) : 1.0;
    final effective = (_volume * gain * _fadeFactor).clamp(0.0, 1.0);
    if ((effective - _appliedVolume).abs() < 0.002) return;
    _appliedVolume = effective;
    _audio.setVolume(effective);
  }

  /// 按进度计算淡入淡出倍率（单播放器实现，两首不重叠）：
  /// - 开头在 [_fadeSeconds] 的一半内（0.5–3 秒）从静音升到原音量；
  /// - 结尾最后 [_fadeSeconds] 秒降到静音；曲目短于两倍淡出时长时不淡出；
  /// - 用平方曲线：线性振幅在听感上前段降得太快，平方更接近匀速变轻。
  void _updateFade(Duration position) {
    var factor = 1.0;
    if (_fadeSeconds > 0) {
      final fadeMs = _fadeSeconds * 1000;
      final posMs = position.inMilliseconds;
      final durMs = _duration.inMilliseconds;
      final fadeInMs = (fadeMs / 2).clamp(500.0, 3000.0);
      if (posMs < fadeInMs) factor = posMs / fadeInMs;
      if (durMs > fadeMs * 2) factor = min(factor, (durMs - posMs) / fadeMs);
      factor = factor.clamp(0.0, 1.0);
      factor *= factor;
    }
    if (factor == _fadeFactor) return;
    _fadeFactor = factor;
    _applyVolume();
  }

  void toggleMute() {
    setVolume(_volume > 0 ? 0 : _volumeBeforeMute, persist: true);
  }

  // ---------------------------------------------------------------------------
  // Queue management
  // ---------------------------------------------------------------------------
  /// 队列变化：通知界面并保存会话。
  void _queueChanged() {
    _nextCycleOrder = null;
    _scheduleSave();
    _prefetchNext();
    notifyListeners();
  }

  void addToQueue(SpotifyTrack track) {
    _userQueue.add(QueueEntry(_nextQueueUid++, track));
    _queueChanged();
  }

  void clearUserQueue() {
    if (_userQueue.isEmpty) return;
    _userQueue.clear();
    _queueChanged();
  }

  void removeFromUserQueue(int index) {
    if (index < 0 || index >= _userQueue.length) return;
    _userQueue.removeAt(index);
    _queueChanged();
  }

  /// [newIndex] 为移除原条目后的目标位置（与 SliverReorderableList.onReorderItem 一致）。
  void reorderUserQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _userQueue.length) return;
    final item = _userQueue.removeAt(oldIndex);
    _userQueue.insert(newIndex.clamp(0, _userQueue.length), item);
    _queueChanged();
  }

  /// 从上下文待播列表中移除（仅从本轮播放顺序中跳过，不修改原歌单）。
  void removeFromUpNext(int index) {
    final pos = _orderPos + 1 + index;
    if (index < 0 || pos >= _order.length) return;
    _order.removeAt(pos);
    _queueChanged();
  }

  /// [newIndex] 为移除原条目后的目标位置（与 SliverReorderableList.onReorderItem 一致）。
  void reorderUpNext(int oldIndex, int newIndex) {
    final base = _orderPos + 1;
    final count = _order.length - base;
    if (oldIndex < 0 || oldIndex >= count) return;
    final item = _order.removeAt(base + oldIndex);
    _order.insert(base + newIndex.clamp(0, count - 1), item);
    _queueChanged();
  }

  /// 点击 "Next in queue" 中的曲目：跳过它之前的排队曲目并立即播放。
  Future<void> playFromUserQueue(int index) async {
    if (index < 0 || index >= _userQueue.length) return;
    _userQueue.removeRange(0, index);
    await _startTrack(_userQueue.removeAt(0).track);
  }

  /// 点击 "Next from" 中的曲目：直接跳到该位置。
  Future<void> playFromUpNext(int index) async {
    final pos = _orderPos + 1 + index;
    if (index < 0 || pos >= _order.length) return;
    _orderPos = pos;
    await _startTrack(_contextTracks[_order[_orderPos]]);
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _currentAudio = null;
    _cancelRetry();
    unawaited(flushSession()); // 快照同步生成，写文件在后台完成
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _emeErrSub?.cancel();
    _errorController.close();
    positionNotifier.dispose();
    loadProgressNotifier.dispose();
    retryNotifier.dispose();
    _audio.dispose();
    super.dispose();
  }
}
