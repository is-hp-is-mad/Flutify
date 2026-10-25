import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/connect_cluster.dart';
import 'connect_state_client.dart';
import 'dealer_client.dart';

export 'connect_state_client.dart' show ConnectException;
export 'dealer_client.dart' show DealerConnector;

/// Connect 连接状态（对外只有这四种）。
enum ConnectStatus {
  /// 未启动（或已 [ConnectService.stop]）。
  idle,

  /// 正在连接 dealer / 注册观察者。
  connecting,

  /// 已注册，能收到状态推送、能发控制命令。
  online,

  /// 连接失败或中断，正在自动重试。
  offline,
}

/// Spotify Connect 遥控服务：本机以隐藏观察者身份接入账号的 Connect 网络，收状态、控制其他设备，自己不出声。
///
/// 约定：
/// - [start] 依次完成 dealer 连接 → 拿连接 id → 注册观察者 → 发出首个 cluster；不会抛网络错误，
///   失败时 [status] 变为 [ConnectStatus.offline] 并自动重试，重连拿到新连接 id 时自动重新注册；
/// - [clusters] 在注册成功、每次推送、[refresh] 后发出；[stop] 后快照清空为 [ConnectCluster.empty] 并发出；
/// - 控制命令只在 [ConnectStatus.online] 时发送，否则抛 [ConnectException]；命令的效果以随后的推送为准；
/// - [observerId] 在本次进程内固定：设备 id 是 40 位 hex 时由它派生，否则随机生成。
class ConnectService {
  static final RegExp _hex40 = RegExp(r'^[0-9a-fA-F]{40}$');
  static const String _clusterUri = 'hm://connect-state/v1/cluster';

  final String Function() _deviceId;
  final DealerClient _dealer;
  late final ConnectStateClient _state;
  final Duration _registerRetryDelay;
  final Duration confirmationTimeout;
  int _snapshotRevision = 0;
  int _commandGeneration = 0;
  Future<void> _commandTail = Future.value();

  final _clusters = StreamController<ConnectCluster>.broadcast();
  final _statusChanges = StreamController<ConnectStatus>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];

  ConnectCluster _current = ConnectCluster.empty;
  final Stopwatch _sinceSnapshot = Stopwatch();
  ConnectStatus _status = ConnectStatus.idle;
  String? _observerId;

  bool _running = false;
  bool _disposed = false;
  Future<void>? _starting;

  /// 当前连接 id 的注册状态；换连接 / 掉线后全部作废。
  String? _registrationId;
  Future<void>? _registration;
  bool _registered = false;
  bool _registerFailed = false;
  int _registerAttempts = 0;
  Timer? _registerRetryTimer;

  /// [dealer] 与 [registerRetryDelay] 仅供测试注入（缩短计时、使用假通道）。
  ConnectService({
    required http.Client client,
    required Future<Map<String, String>> Function() headers,
    required this._deviceId,
    DealerConnector? connector,
    Uri? apresolve,
    DealerClient? dealer,
    this._registerRetryDelay = const Duration(seconds: 3),
    this.confirmationTimeout = const Duration(seconds: 2),
  }) : _dealer =
           dealer ??
           DealerClient(
             client: client,
             headers: headers,
             connector: connector,
             apresolve: apresolve,
           ) {
    _state = ConnectStateClient(
      client: client,
      headers: headers,
      spclientHost: () =>
          _dealer.spclientHost ?? DealerClient.defaultSpclientHost,
      connectionId: () => _dealer.connectionId,
    );
    _subscriptions
      ..add(_dealer.messages.listen(_onDealerMessage))
      ..add(_dealer.connectionIds.listen(_onConnectionId))
      ..add(_dealer.statusChanges.listen(_onDealerStatus));
  }

  /// 广播：注册成功、每次推送、[refresh] 后发出最新快照。
  Stream<ConnectCluster> get clusters => _clusters.stream;

  /// 最近一次快照；初始为 [ConnectCluster.empty]。
  ConnectCluster get current => _current;

  Stream<ConnectStatus> get statusChanges => _statusChanges.stream;

  ConnectStatus get status => _status;

  /// 本机观察者 id：`hobs_` + 40 位 hex。
  String get observerId => _observerId ??= _deriveObserverId();

  /// 按最近快照的服务端时间与本地收到时刻估算的服务端当前时间（毫秒）；还没有快照时用本地时钟。
  int get serverNowMs {
    final serverMs = _current.serverTimestampMs;
    if (serverMs == 0) return DateTime.now().millisecondsSinceEpoch;
    return serverMs + _sinceSnapshot.elapsedMilliseconds;
  }

  /// 启动并保持连接；幂等。已启动但处于离线状态时会立即重试一次。
  Future<void> start() {
    if (_disposed) throw StateError('ConnectService 已释放');
    _running = true;
    _refreshStatus();
    return _starting ??= _run().whenComplete(() => _starting = null);
  }

  Future<void> _run() async {
    try {
      await _dealer.connect();
      final id = _dealer.connectionId;
      if (id != null && _running) await _register(id);
    } catch (_) {
      // 失败已体现在 status 上，dealer 与注册各自按退避重试
    } finally {
      // dealer 的状态流是异步送达的，这里先同步一次，保证 start 返回时 status 已是最新
      _refreshStatus();
    }
  }

  /// 注销观察者（尽力而为，失败忽略）、关闭 dealer，状态回到 idle。
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    ++_commandGeneration;
    final id = _dealer.connectionId;
    final wasRegistered = _registered;
    _resetRegistration();
    _refreshStatus();
    if (wasRegistered && id != null) {
      try {
        await _state
            .unregister(observerId, id)
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await _dealer.close();
    _applyCluster(ConnectCluster.empty);
    _refreshStatus();
  }

  /// 重新注册观察者以取全量 cluster。
  Future<void> refresh() async {
    final id = _requireOnline();
    final revision = _snapshotRevision;
    final cluster = await _state.registerObserver(observerId, id);
    if (_running && _dealer.connectionId == id && revision == _snapshotRevision)
      _applyCluster(cluster);
  }

  /// 把播放转移到 [toDeviceId]；[play] 为 false 时到达后保持暂停。
  Future<void> transfer(
    String toDeviceId, {
    bool play = true,
    bool confirm = false,
  }) => _runPlaybackCommand(
    () async {
      _requireOnline();
      await _state.transfer(observerId, toDeviceId, play: play);
    },
    (cluster) => cluster.activeDeviceId == toDeviceId,
    confirm: confirm,
  );

  /// 在 [deviceId] 上播放新内容。
  ///
  /// - 有上下文（歌单 / 专辑 / 艺人 / 已点赞的歌曲）时传 [contextUri]，由远程设备自己展开曲目与后续播放；
  /// - 没有可用上下文（搜索结果、单曲、只存在本机的歌单）时传 [trackUris]，以临时列表播放；
  /// - [trackUri] / [trackIndex] 指定从哪一首开始（都不传则从头）。
  Future<void> play(
    String deviceId, {
    String contextUri = '',
    List<String> trackUris = const [],
    String? trackUri,
    int? trackIndex,
    int? seekToMs,
    bool paused = false,
    bool? repeatingContext,
    bool? repeatingTrack,
    bool confirm = false,
  }) => _runPlaybackCommand(
    () => _command(deviceId, 'play', {
      'context': contextUri.isNotEmpty
          ? {
              'uri': contextUri,
              'url': 'context://$contextUri',
              'metadata': <String, Object?>{},
            }
          : {
              'uri': '',
              'url': '',
              'metadata': <String, Object?>{},
              'pages': [
                {
                  'tracks': [
                    for (final uri in trackUris) {'uri': uri},
                  ],
                },
              ],
            },
      'play_origin': <String, Object?>{},
      'options': {
        'license': 'on-demand',
        'skip_to': {'track_uri': ?trackUri, 'track_index': ?trackIndex},
        'seek_to': ?seekToMs,
        if (paused) 'initially_paused': true,
        'player_options_override': <String, Object?>{
          if (repeatingContext != null) 'repeating_context': repeatingContext,
          if (repeatingTrack != null) 'repeating_track': repeatingTrack,
        },
      },
    }),
    (cluster) =>
        cluster.activeDeviceId == deviceId &&
        ((trackUri == null && (contextUri.isNotEmpty || trackUris.isEmpty)) ||
            cluster.player.trackUri ==
                (trackUri ??
                    trackUris[(trackIndex ?? 0).clamp(
                      0,
                      trackUris.length - 1,
                    )])) &&
        (paused ? cluster.player.isPaused : cluster.player.isAudible),
    confirm: confirm,
  );

  /// 点歌 / 转移按发送顺序执行；只重试仍然是最新意图的请求。
  /// HTTP 成功后等待设备状态，推送遗漏时拉取快照，最多补发一次。
  Future<void> _runPlaybackCommand(
    Future<void> Function() send,
    bool Function(ConnectCluster) matches, {
    required bool confirm,
  }) async {
    final generation = ++_commandGeneration;
    bool current() => !_disposed && generation == _commandGeneration;
    var revision = _snapshotRevision;
    for (var attempt = 0; attempt < (confirm ? 2 : 1); attempt++) {
      if (!current()) return;
      final sent = _commandTail.then((_) async {
        if (!current()) return;
        revision = _snapshotRevision;
        await send();
      });
      _commandTail = sent.catchError((Object _) {});
      try {
        await sent;
      } on ConnectException catch (e) {
        if (!current()) return;
        final retryable =
            e.statusCode == null ||
            e.statusCode == 404 ||
            (e.statusCode ?? 0) >= 500;
        if (!confirm || !retryable || attempt == 1) rethrow;
      }
      if (!confirm || !current()) return;
      bool applied() => _snapshotRevision > revision && matches(_current);
      if (applied()) return;
      await _waitForState(() => !current() || applied());
      if (!current() || applied()) return;
      try {
        await refresh();
      } on ConnectException catch (_) {
        // 下面的重试仍由连接状态检查约束。
      }
      if (!current() || applied()) return;
    }
    throw const ConnectException(null, '设备尚未确认播放指令，请检查连接后重试');
  }

  Future<void> _waitForState(bool Function() done) async {
    if (done()) return;
    final ready = Completer<void>();
    final subscription = clusters.listen((_) {
      if (done() && !ready.isCompleted) ready.complete();
    });
    final timer = Timer(confirmationTimeout, () {
      if (!ready.isCompleted) ready.complete();
    });
    try {
      await ready.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  Future<void> _transport(String deviceId, String endpoint) {
    ++_commandGeneration;
    final sent = _commandTail.then((_) => _command(deviceId, endpoint));
    _commandTail = sent.catchError((Object _) {});
    return sent;
  }

  Future<void> pause(String deviceId) => _transport(deviceId, 'pause');

  Future<void> resume(String deviceId) => _transport(deviceId, 'resume');

  Future<void> skipNext(String deviceId) => _transport(deviceId, 'skip_next');

  Future<void> skipPrevious(String deviceId) =>
      _transport(deviceId, 'skip_prev');

  Future<void> seekTo(String deviceId, int positionMs) =>
      _command(deviceId, 'seek_to', {'value': max(0, positionMs)});

  Future<void> setShuffle(String deviceId, bool value) =>
      _command(deviceId, 'set_shuffling_context', {'value': value});

  Future<void> setRepeat(
    String deviceId, {
    required bool context,
    required bool track,
  }) => _command(deviceId, 'set_options', {
    'repeating_context': context,
    'repeating_track': track,
  });

  /// [volume] 为 0 – 1，换算成服务端的 0 – 65535。
  Future<void> setVolume(String deviceId, double volume) async {
    _requireOnline();
    await _state.setVolume(
      observerId,
      deviceId,
      (volume.clamp(0.0, 1.0) * 65535).round(),
    );
  }

  /// 释放全部资源；之后不可再用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final id = _dealer.connectionId;
    final wasRegistered = _registered;
    _running = false;
    _resetRegistration();
    for (final sub in _subscriptions) {
      sub.cancel().ignore();
    }
    // 注销是尽力而为，不等结果
    if (wasRegistered && id != null)
      _state.unregister(observerId, id).catchError((Object _) {}).ignore();
    unawaited(
      _dealer.dispose().whenComplete(() {
        _clusters.close();
        _statusChanges.close();
      }),
    );
  }

  Future<void> _command(
    String deviceId,
    String endpoint, [
    Map<String, Object?> extra = const {},
  ]) async {
    _requireOnline();
    await _state.command(observerId, deviceId, endpoint, extra: extra);
  }

  /// 在线才能发命令；返回当前连接 id。
  String _requireOnline() {
    final id = _dealer.connectionId;
    if (_status != ConnectStatus.online || id == null) {
      throw const ConnectException(null, '尚未连接到 Spotify Connect');
    }
    return id;
  }

  // ---- dealer 事件 ----

  void _onDealerMessage(DealerMessage message) {
    if (!_running || message.uri != _clusterUri || message.payloads.isEmpty)
      return;
    final payload = message.payloads.first;
    if (payload is! Map) return;
    try {
      _applyCluster(ConnectCluster.fromJson(payload.cast<String, dynamic>()));
    } catch (e) {
      // 解析失败：忽略这条推送
      debugPrint('[Connect] 集群推送解析失败：$e');
    }
  }

  void _onConnectionId(String id) {
    if (_running) _register(id).ignore();
  }

  void _onDealerStatus(DealerStatus status) {
    debugPrint('[Connect] 遥控 dealer：${status.name}');
    // 掉线 / 重连中：旧连接 id 上的注册作废，等新 id 到了再注册
    if (status != DealerStatus.online) _resetRegistration();
    _refreshStatus();
  }

  // ---- 注册 ----

  /// 在连接 [id] 上注册观察者；同一个 id 只注册一次（失败后再次调用会重试）。
  Future<void> _register(String id) {
    final pending = _registration;
    if (pending != null && _registrationId == id) return pending;
    _registerRetryTimer?.cancel();
    _registrationId = id;
    return _registration = _doRegister(id);
  }

  Future<void> _doRegister(String id) async {
    _registerFailed = false;
    _refreshStatus();
    try {
      final cluster = await _state.registerObserver(observerId, id);
      // 期间已停止或连接换了 id：这次结果作废
      if (!_running || _dealer.connectionId != id) return;
      _registered = true;
      _registerAttempts = 0;
      _applyCluster(cluster);
      _refreshStatus();
    } catch (e) {
      debugPrint('[Connect] 观察者注册失败：$e');
      if (_running && _dealer.connectionId == id) {
        _registration = null;
        _registerFailed = true;
        _refreshStatus();
        _scheduleRegisterRetry(id);
      }
      rethrow;
    }
  }

  void _scheduleRegisterRetry(String id) {
    var delay = _registerRetryDelay * (1 << min(_registerAttempts, 10));
    if (delay > const Duration(seconds: 60))
      delay = const Duration(seconds: 60);
    _registerAttempts++;
    _registerRetryTimer = Timer(delay, () {
      if (_running && !_registered && _dealer.connectionId == id)
        _register(id).ignore();
    });
  }

  void _resetRegistration() {
    _registerRetryTimer?.cancel();
    _registerRetryTimer = null;
    _registrationId = null;
    _registration = null;
    _registered = false;
    _registerFailed = false;
    _registerAttempts = 0;
  }

  // ---- 状态与快照 ----

  String? _lastClusterSummary;

  void _applyCluster(ConnectCluster cluster) {
    if (cluster != ConnectCluster.empty &&
        cluster.serverTimestampMs > 0 &&
        cluster.serverTimestampMs < _current.serverTimestampMs)
      return;
    ++_snapshotRevision;
    // 只在活动设备 / 设备列表变化时记一行，排查「列表里没有某设备」「交接不过去」
    final summary =
        'active=${cluster.activeDeviceId} '
        'devices=${cluster.devices.map((d) => '${d.name}(${d.id})').join(', ')}';
    if (summary != _lastClusterSummary) {
      _lastClusterSummary = summary;
      debugPrint('[Connect] 集群：$summary');
    }
    _current = cluster;
    _sinceSnapshot
      ..reset()
      ..start();
    if (!_clusters.isClosed) _clusters.add(cluster);
  }

  void _refreshStatus() {
    final next = !_running
        ? ConnectStatus.idle
        : switch (_dealer.status) {
            DealerStatus.idle ||
            DealerStatus.connecting => ConnectStatus.connecting,
            DealerStatus.offline => ConnectStatus.offline,
            DealerStatus.online =>
              _registered
                  ? ConnectStatus.online
                  : _registerFailed
                  ? ConnectStatus.offline
                  : ConnectStatus.connecting,
          };
    if (next == _status) return;
    _status = next;
    if (!_statusChanges.isClosed) _statusChanges.add(next);
  }

  String _deriveObserverId() {
    final deviceId = _deviceId();
    if (_hex40.hasMatch(deviceId)) return 'hobs_${deviceId.toLowerCase()}';
    final random = Random.secure();
    return 'hobs_${List.generate(20, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }
}
