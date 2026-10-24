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
import '../services/playback/playback_region_gate.dart';
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

  /// 起播前的网络出口地区门控；为空（测试 / 未注入）时不做任何检测。
  final PlaybackRegionGate? regionGate;

  /// 设置里的「默认循环方式」（切换歌单等播放列表时默认生效）；null 表示不干预。
  /// 见 [defaultRepeatMode]。
  SpotifyRepeatMode? _defaultRepeatMode;
  final Random _random;

  /// 远程播放接管（由 main.dart 接上 Spotify Connect）：点歌时先问它，返回 true 表示已交给远程设备播放，
  /// 本机不再加载；[start] 为 null 表示从头播放整个上下文。为空或返回 false 时照常在本机播放。
  RemotePlayHandler? remotePlay;

  /// 本机修改随机 / 循环时与服务端同步的钩子：等服务端确认后再在前端应用，彻底消除抖动。
  Future<bool> Function({bool? shuffle, SpotifyRepeatMode? repeat})?
  syncOptionsBeforeApply;

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

  /// 重试的预算按「一次播放尝试」算，不是按曲目算：
  /// 一次 [playTrack] 或一次自动跳过给 [PlaybackRetry.limit] 次重试
  /// （[_handleLoadFailure] 里接着重放也算在同一次尝试里），
  /// 用光后 [_playAudio] 立刻交出失败，不会在每个后台重试上都干等一轮退避。
  bool _retryingTrack = false;
  int _retriesUsed = 0;

  /// 本首歌的网络类失败已经重放过一次（[_retryTrack]）。
  ///
  /// 重放会把预算还回去，好让它和第一次一样有完整的退避机会；这一位就是防止
  /// 「还回去」变成「用不完」：重放再失败时不再接着重放，交给用户决定
  /// （错误提示条上的「重试」）。
  bool _transientRetried = false;

  /// [PlaybackRetry.limit] 次重试用完；剩下的失败不再等退避，直接交给调用方处理。
  bool get _budgetExhausted => _retriesUsed >= PlaybackRetry.limit;

  /// 记一次重试。调用方必须已经用 [_budgetExhausted] 确认还有预算。
  int _takeRetry() => ++_retriesUsed;

  /// 退避等待的握手：切歌 / 登出 / 用户取消时由 [_cancelRetry] 完成，
  /// 等待方据此提前收手，不再空等到点。
  Completer<void>? _retryWait;
  final ValueNotifier<PlaybackRetry?> retryNotifier = ValueNotifier(null);

  void _cancelRetry() {
    final wait = _retryWait;
    _retryWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
    retryNotifier.value = null;
  }

  Future<bool> _waitForRetry(Object error, int generation) async {
    if (!isConnectionFailure(error) || _budgetExhausted) {
      return false;
    }
    final attempt = _takeRetry();
    final delay = Duration(seconds: attempt);
    final wait = Completer<void>();
    _retryWait = wait;
    retryNotifier.value = PlaybackRetry(attempt, delay);
    final timer = Timer(delay, () {
      if (!wait.isCompleted) wait.complete();
    });
    await wait.future;
    timer.cancel();
    // 注意顺序：先认 [_retryWait] 再认代次。用户取消 / 切歌 / 登出时
    // [_cancelRetry] 已经把 [_retryWait] 清空，这里立刻收手，不再空等到点。
    if (!identical(_retryWait, wait)) return false;
    _retryWait = null;
    // 代次对不上说明期间切了歌：这次加载的结果已经作废，不重试。
    if (generation != _loadGeneration) return false;
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
    this.regionGate,
    SpotifyRepeatMode? defaultRepeatMode,
  }) : _audio = audio,
       _random = random ?? Random(),
       _pauseAfterFailures = _storage.pauseAfterFailures,
       _volume = _storage.volume,
       _volumeBeforeMute = _storage.volume > 0 ? _storage.volume : 0.8,
       _normalize = _storage.normalizeVolume,
       _fadeSeconds = _storage.fadeSeconds.clamp(0, maxFadeSeconds) {
    _initAudioListeners();
    _applyVolume();
    _defaultRepeatMode = defaultRepeatMode;
    if (defaultRepeatMode != null) _repeatMode = defaultRepeatMode;
    regionGate?.onNetworkChanged = _onRegionNetworkChanged;
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

  /// 设置里的「默认循环方式」；null 表示不干预，循环方式由用户当场点的（或上次会话）决定。
  SpotifyRepeatMode? get defaultRepeatMode => _defaultRepeatMode;

  /// 本次点歌应使用的循环方式（切换歌单 / 从头播放上下文时为默认循环方式）。
  ///
  /// 经 Connect 下发给本机播放端时要随请求带上：服务端回推的 replace_state 会携带播放选项
  /// 并覆盖本机，不带的话默认循环方式就被服务端上一次的状态冲掉。
  SpotifyRepeatMode get repeatModeForNextPlay => _repeatModeForNextPlay ?? _repeatMode;
  SpotifyRepeatMode? _repeatModeForNextPlay;

  /// 设置页改动「默认循环方式」时同步进来。
  ///
  /// 它同时是当前循环方式：否则设置里选完要等下次启动才生效，
  /// 用户在设置页看到的和播放器实际用的会不一致。
  void updateDefaultRepeatMode(SpotifyRepeatMode? mode) {
    if (mode == _defaultRepeatMode) return;
    _defaultRepeatMode = mode;
    if (mode == null) return;
    setRepeatMode(mode);
  }

  void _applyDefaultRepeatMode() {
    final mode = _defaultRepeatMode;
    if (mode != null) {
      setRepeatMode(mode);
    }
  }

  bool _isSwitchingContext(PlaybackContext? next) {
    final target = next ?? PlaybackContext.none;
    if (_currentTrack == null) return true;
    if (target.uri.isEmpty || _context.uri.isEmpty) return true;
    return target.uri != _context.uri;
  }

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
      (_repeatMode != SpotifyRepeatMode.off && _order.isNotEmpty);

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
      final ended =
          ps == ProcessingState.completed &&
          _lastProcessingState != ProcessingState.completed;
      _lastProcessingState = ps;

      // Set continuation intent BEFORE notifying media controls of completion.
      // Loading the next source (and repeat-one's seek) can take arbitrarily long.
      final wasStarting = _isStartingPlayback;
      if (ended) {
        _isStartingPlayback =
            !_stopAfterCurrent &&
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
    if (!isRetry) {
      // 新的手动播放尝试（含自动跳过的下一首）：重试预算重新计
      _retryingTrack = false;
      _retriesUsed = 0;
      _transientRetried = false;
    } else if (!_retryingTrack) {
      // 自动跳过的下一首是「换一首接着放」，不是同曲重试：预算重新计
      _retriesUsed = 0;
      _transientRetried = false;
    }
    _releaseCurrentAudio();
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
    _loadedTrackId = null;
    _releaseCurrentAudio();
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
    if (regionGate != null) {
      final blocked = await _blockOnRegion(track, generation: generation);
      if (blocked || generation != _loadGeneration) return;
    }
    while (generation == _loadGeneration) {
      // 已打开但还没交给播放器的音源：中途切歌 / 失败时要释放，否则下载会在后台一直跑完
      LoadedAudio? opened;
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
        opened = audio;
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
        // 这次尝试成功了：重试预算还回去，用户在下一首上仍有完整的重试机会
        _retryingTrack = false;
        _retriesUsed = 0;
        _transientRetried = false;
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
        debugPrint('[playback] 加载失败: $e');
        final retry = await _waitForRetry(e, generation);
        if (generation != _loadGeneration) return;
        if (retry) {
          loadProgressNotifier.value = 0;
          continue;
        }
        retryNotifier.value = null;
        await _handleLoadFailure(track, _asPlaybackFailure(e));
        return;
      } finally {
        if (opened != null && !identical(opened, _currentAudio)) {
          opened.release();
        }
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

  /// 「这首歌播不了」——URL 过期 / 区域限制 / 已下架。
  ///
  /// 这类失败重试多少次都一样，只能跳下一首。
  static bool _isUnsuitableTrack(TrackPlaybackException failure) =>
      failure.kind == TrackPlaybackFailure.unavailable;

  /// 「这一下没加载上」——断网、超时、对端半路关连接。
  ///
  /// 和 [TrackPlaybackFailure.kind] 分开看：后者由状态码推导，会把传输层的抖动
  /// 也归进 `network`，而那未必代表这首歌有问题。
  static bool _isTransientFailure(TrackPlaybackException failure) =>
      isConnectionFailure(failure);

  /// 处理加载失败：暴露错误状态；「不可播放」类自动跳到下一首（有上限）。
  ///
  /// 上限有两层：
  /// - 开启 [pauseAfterFailures]（默认）：连续第 [failureLimit] 首仍不可播放时停下，标记 autoPaused；
  /// - 始终：跳过次数不超过一轮上下文长度，避免整个歌单都不可播时死循环。
  ///
  /// 网络类失败不算「这首歌播不了」，不参与这两层上限：先自动重放一次当前曲目，
  /// 重放仍失败则停在当前曲目并提示用户点「重试」。
  Future<void> _handleLoadFailure(
    SpotifyTrack track,
    TrackPlaybackException failure,
  ) async {
    final unsuitable = _isUnsuitableTrack(failure);
    final failures = unsuitable ? _consecutiveSkips + 1 : _consecutiveSkips;
    final hitLimit =
        unsuitable && _pauseAfterFailures && failures >= failureLimit;
    // 网络类失败可以再重放一次：退避重放已经把预算用光，这里把预算还回去，
    // 让它和第一次一样有完整的 [PlaybackRetry.limit] 次机会。
    // [_transientRetried] 保证这一下只做一次——重放再失败就报错，不再自己循环下去，
    // 否则用户永远只能看着「正在重试」，听不到也点不动。
    final retryable =
        _isTransientFailure(failure) &&
        !unsuitable &&
        !_transientRetried &&
        !_retryingTrack;
    final canSkip =
        !hitLimit &&
        unsuitable &&
        _consecutiveSkips < max(max(_order.length, _userQueue.length + 1), 1) &&
        (_userQueue.isNotEmpty ||
            _orderPos + 1 < _order.length ||
            _repeatMode != SpotifyRepeatMode.off);
    final error = PlaybackError(
      serial: ++_errorSerial,
      track: track,
      exception: failure,
      skipped: canSkip,
      autoPaused: hitLimit,
      consecutiveFailures: failures,
      retryable: retryable,
    );
    // 还要退避重放这首歌：先不报错。后台切歌时断流很平常，重来一次往往就成了，
    // 每抖一下都给用户弹一条「加载失败」是噪音；等重放也失败再报。
    if (retryable) {
      _setLoading(false);
      await _retryTrack();
      return;
    }
    _playbackError = error;
    _errorController.add(_playbackError!);
    if (!canSkip) {
      // 重放也没成功：没打算在这首歌上再自动重来，把「这一下没加载上」的预算
      // 留给用户下一次点「重试」（那是一次新的手动播放尝试，见 [_startTrack]）。
      _retriesUsed = 0;
      _transientRetried = false;
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

  /// 不再播放当前音源：交还给加载器（边下边播的下载没有其他使用者时会在宽限期后取消）。
  void _releaseCurrentAudio() {
    final audio = _currentAudio;
    _currentAudio = null;
    audio?.release();
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
    final switching = _isSwitchingContext(context);
    final remote = remotePlay;
    _repeatModeForNextPlay = switching ? _defaultRepeatMode : null;
    try {
      if (remote != null &&
          await remote(
            context ?? PlaybackContext.none,
            contextQueue ?? [track],
            track,
          ))
        return;
    } finally {
      _repeatModeForNextPlay = null;
    }
    if (intent != _playIntent) return;
    if (switching) _applyDefaultRepeatMode();
    await _playLocal(
      track,
      contextQueue: contextQueue,
      context: context,
      applyDefaultRepeat: false,
    );
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
    bool applyDefaultRepeat = true,
  }) async {
    _receiverQueue = null;
    if (applyDefaultRepeat && _isSwitchingContext(context)) {
      _applyDefaultRepeatMode();
    }
    var tracks = (contextQueue == null || contextQueue.isEmpty)
        ? [track]
        : List.of(contextQueue);
    // 同一首歌可能在列表里出现多次：优先按对象身份定位到用户点的那一行，
    // 找不到（调用方传的是另一份对象）再按 id 匹配。
    var index = tracks.indexWhere((t) => identical(t, track));
    if (index == -1 && track.id.isNotEmpty) {
      index = tracks.indexWhere((t) => t.id == track.id);
    }
    if (index == -1) {
      tracks = [track, ...tracks];
      index = 0;
    }
    _contextTracks = tracks;
    _context = context ?? PlaybackContext.none;
    _rebuildOrder(index);
    await _startTrack(track, startAt: startAt, deferLoad: deferLoad);
  }

  void _onRegionNetworkChanged() {
    final track = _currentTrack;
    if (track == null || !isPlaybackActive) return;
    unawaited(_recheckActivePlaybackRegion(track));
  }

  Future<void> _recheckActivePlaybackRegion(SpotifyTrack track) async {
    final gate = regionGate;
    if (gate == null) return;
    final block = await gate.ensureAllowed();
    if (block == null) return;
    if (_currentTrack?.id == track.id) {
      final savedPos = position;
      await pause();
      _loadedTrackId = null;
      _resumeAt = savedPos;
      await _blockOnRegion(track);
    }
  }

  /// 起播前及网络变动时的出口地区门控：检测到中国大陆就停在这首歌上并提示，不加载任何音频。
  ///
  /// 只拦本机播放，不拦后台预取（预取失败本来就不出声）。
  Future<bool> _blockOnRegion(SpotifyTrack track, {int? generation}) async {
    final gate = regionGate;
    if (gate == null || track.id.isEmpty) return false;
    PlaybackRegionBlock? block;
    try {
      block = await gate.ensureAllowed();
    } catch (_) {
      // 检测本身出问题按「未知」处理，不因为探测失败就不让听歌
      return false;
    }
    if (block == null) return false;
    if (generation != null && generation != _loadGeneration) return true;
    _playbackError = PlaybackError(
      serial: ++_errorSerial,
      track: track,
      exception: TrackPlaybackException(
        TrackPlaybackFailure.regionBlocked,
        '当前网络出口在中国大陆，Spotify 无法播放',
      ),
      skipped: false,
      autoPaused: false,
      consecutiveFailures: 1,
      retryable: false,
    );
    _errorController.add(_playbackError!);
    _isStartingPlayback = false;
    _isPlaying = false;
    _isBuffering = false;
    _setLoading(false);
    notifyListeners();
    return true;
  }

  /// 接收服务端的实际顺序，不再在本机洗牌。匹配的完整上下文只补充
  /// 未下发的尾部；服务端改序或启用随机时绝不拼接原歌单顺序。
  Future<void> playReceiverQueue(
    List<SpotifyTrack> currentAndNext, {
    required Duration startAt,
    required bool paused,
  }) async {
    if (currentAndNext.isEmpty) return;
    final hadSeed = _receiverQueue != null;
    final prevContextUri = _context.uri;
    final queue = _receiverOrder(currentAndNext);
    final switchingContext =
        hadSeed ||
        prevContextUri.isEmpty ||
        queue.context.uri.isEmpty ||
        queue.context.uri != prevContextUri;
    _contextTracks = queue.tracks;
    _context = queue.context;
    _order = List.generate(_contextTracks.length, (i) => i);
    _orderPos = queue.index;
    if (switchingContext) {
      _applyDefaultRepeatMode();
    }
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
    final intent = ++_playIntent;
    final remote = remotePlay;
    _repeatModeForNextPlay = _defaultRepeatMode;
    try {
      if (remote != null && await remote(context, tracks, null)) return;
    } finally {
      _repeatModeForNextPlay = null;
    }
    if (intent != _playIntent) return;
    // 切换歌单 / 从头播放上下文时应用设置的默认循环方式（交给远程设备时不动本机设置）
    _applyDefaultRepeatMode();
    final start = _shuffle ? _random.nextInt(tracks.length) : 0;
    await _playLocal(
      tracks[start],
      contextQueue: tracks,
      context: context,
      applyDefaultRepeat: false,
    );
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
      _retryingTrack = false;
      _retriesUsed = 0;
      _transientRetried = false;
      _playbackError = null;
      await _playAudio(track);
    } else {
      _resumeAudio(track, _loadGeneration);
    }
  }

  /// 只跳过、不换曲：拿当前曲目重放。
  ///
  /// 用在网络类失败上——加载这一首时链路断了，同一首重来一次往往就成了。
  /// 重试预算按曲目连续计：重置预算，好让这次重放拿到和第一次同样的
  /// [PlaybackRetry.limit] 次机会（[_waitForRetry] 随后按预算逐次退避）。
  ///
  /// 再失败就只是又走一遍 [_handleLoadFailure]：那时 [_transientRetried] 已经成立，
  /// 不会再重放第三次，而是报错收手——所以不必在这里判断重放有没有成。
  Future<void> _retryTrack() async {
    _retriesUsed = 0;
    _transientRetried = true;
    // 闸门要一直立到重放彻底结束：重放失败时 [_handleLoadFailure] 会在
    // `_startTrack` 内部同步再跑一遍，那时 [_transientRetried] 已经为真，
    // 唯一拦住「再来一次重放」的就是这一位。等它返回之后再放下。
    _retryingTrack = true;
    try {
      await _startTrack(_currentTrack!, isRetry: true);
    } finally {
      _retryingTrack = false;
      // 「连续跳过」计数还原：网络抖动不算「这首歌播不了」，不该攒进那两重上限
      _consecutiveSkips = (_consecutiveSkips - 1).clamp(0, 1 << 30);
    }
  }

  /// 下一首。[isAutoSkip] 表示由「不可播放自动跳过」触发（不重置连续跳过计数）。
  ///
  /// 单曲循环只作用于「自然播完」（见 [_handleTrackEnded]）；手动下一首 / 不可播放自动跳过
  /// 都换到下一首，列表末尾按循环回绕——否则单曲循环时点下一首跳不走，
  /// 坏掉的曲目也会被反复重试。
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

    if (_repeatMode != SpotifyRepeatMode.off && _order.isNotEmpty) {
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

  /// 上一首（不论已播多久都直接切歌，见测试约定）；列表开头在循环模式下回绕到末尾。
  Future<void> previousTrack() async {
    if (_order.isEmpty) {
      await seekTo(Duration.zero);
      return;
    }
    if (_orderPos == 0) {
      if (_repeatMode == SpotifyRepeatMode.off || _order.length < 2) {
        await seekTo(Duration.zero);
        return;
      }
      _orderPos = _order.length - 1;
      await _startTrack(_contextTracks[_order[_orderPos]]);
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

  Future<void> toggleShuffle() async {
    final next = !_shuffle;
    final sync = syncOptionsBeforeApply;
    if (sync != null) {
      final ok = await sync(shuffle: next);
      if (!ok) return;
    }
    _shuffle = next;
    if (_order.isNotEmpty) _rebuildOrder(_order[_orderPos]);
    _scheduleSave();
    _prefetchNext();
    notifyListeners();
  }

  /// 直接设定随机（Connect 远程命令用）；与当前相同时不重排。
  void setShuffle(bool value) {
    if (value != _shuffle) {
      _shuffle = value;
      if (_order.isNotEmpty) _rebuildOrder(_order[_orderPos]);
      _scheduleSave();
      _prefetchNext();
      notifyListeners();
    }
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

  Future<void> cycleRepeatMode() async {
    final next = switch (_repeatMode) {
      SpotifyRepeatMode.off => SpotifyRepeatMode.context,
      SpotifyRepeatMode.context => SpotifyRepeatMode.track,
      SpotifyRepeatMode.track => SpotifyRepeatMode.off,
    };
    final sync = syncOptionsBeforeApply;
    if (sync != null) {
      final ok = await sync(repeat: next);
      if (!ok) return;
    }
    setRepeatMode(next);
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
    // 设置里指定了默认循环方式时以它为准，否则沿用上次会话
    _repeatMode = _defaultRepeatMode ?? session.repeatMode;
    // 保存的是播放顺序，还原后按自然顺序即为原来的顺序
    _contextTracks = List.of(session.tracks);
    _order = List.generate(_contextTracks.length, (i) => i);
    _orderPos = _order.isEmpty ? 0 : session.index.clamp(0, _order.length - 1);
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
    _releaseCurrentAudio();
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
    _isBuffering = false;
    _playbackError = null;
    _normalization = null;
    _currentDownloadReady = false;
    _prefetchedTrackId = null;
    _consecutiveSkips = 0;
    _fadeFactor = 1;
    _applyVolume();
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
    if (identical(regionGate?.onNetworkChanged, _onRegionNetworkChanged)) {
      regionGate?.onNetworkChanged = null;
    }
    ++_loadGeneration;
    _releaseCurrentAudio();
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
