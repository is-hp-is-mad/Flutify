import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../../models/audio_playback_info.dart';
import 'listening_progress.dart';

import '../dealer_client.dart';
import 'track_playback_api.dart';
import 'track_playback_state.dart';

/// 播放端要驱动的本机播放器（由 [PlaybackReceiverHost] 接到 PlaybackProvider）。
abstract class ReceiverHost {
  /// 播放 [order]（状态下标，按播放顺序，第一个为当前）对应的曲目，从 [positionMs] 起，[paused] 时停在该处。
  Future<void> load(
    TpStateMachine machine,
    List<int> order, {
    required int positionMs,
    required bool paused,
  });

  /// 当前曲目不变时只同步暂停 / 进度；[positionMs] 为 null（只改了循环 / 随机等）时不动进度。
  Future<void> sync({required int? positionMs, required bool paused});

  /// 服务端扩展了当前曲目的前后窗口；不重新加载当前音频。
  void updateQueue(TpStateMachine machine, List<int> order);

  /// 随机 / 循环方式。
  void applyOptions(TpOptions options);

  /// 0–1。
  void setVolume(double volume);

  /// 本机当前进度（毫秒）。
  int get positionMs;
  bool get isAudible;
  AudioPlaybackInfo get audioPlaybackInfo;

  /// 远程把播放转走 / 登出：本机停止。
  Future<void> stop();
}

/// Spotify Connect 播放端：让 Flutify 出现在其他设备的「设备列表」里，被选中后在本机出声。
///
/// 协议为 track-playback（Web 播放器同款，免费账号可用）：
/// 1. 用 Web token 建立**独立的** dealer 连接（与遥控用的 dealer 身份不同），拿到 connection_id；
/// 2. `POST track-playback/v1/devices` 注册；每次 dealer 重连拿到新 id 都重新注册；
/// 3. dealer 推 `hm://track-playback/v1/command`：`replace_state`（播放 / 暂停 / 切歌 / 拖动全靠它）、
///    `set_volume`、`log_out`、`ping`；
/// 4. 本机状态变化（开始播放、暂停、恢复、切到下一状态、播满 30 秒）用 `PUT …/state` 汇报，
///    服务端据此更新其他设备上的显示；
/// 5. [stop] 时 `DELETE` 注销。
class ConnectReceiver {
  static const String defaultDeviceName = 'Web Player';

  final ReceiverHost host;

  /// 设备名：每次注册时读取，改名后 [stop] 再 [start] 即生效。
  final String Function() deviceName;
  late final TrackPlaybackApi _api;
  final DealerClient _dealer;

  StreamSubscription<String>? _idSub;
  StreamSubscription<DealerMessage>? _msgSub;
  StreamSubscription<DealerStatus>? _statusSub;
  final Duration registerRetryDelay;
  Timer? _registerRetry;
  String? _registrationId;
  Future<void>? _registration;
  int _registrationEpoch = 0;
  int _registerAttempts = 0;
  bool _started = false;
  bool _registered = false;

  TpStateMachine? _machine;
  int _stateIndex = -1;
  bool _paused = true;
  int _revision = 0;

  /// 本状态是否已汇报过「播满 30 秒」。
  final _listening = ListeningProgress();
  final _clock = Stopwatch()..start();

  ConnectReceiver({
    required this.host,
    required this.deviceName,
    required http.Client client,
    required Future<String> Function() webToken,
    required String deviceId,
    DealerClient? dealer,
    this.registerRetryDelay = const Duration(seconds: 2),
  }) : _dealer =
           dealer ??
           DealerClient(
             client: client,
             headers: () async => {
               'Authorization': 'Bearer ${await webToken()}',
               'User-Agent': TrackPlaybackApi.userAgent,
             },
           ) {
    _api = TrackPlaybackApi(
      client: client,
      webToken: webToken,
      deviceId: deviceId,
      spclientHostProvider: () => _dealer.spclientHost,
    );
  }

  String get deviceId => _api.deviceId;

  /// 每次注册成功（含 dealer 重连后的重新注册）时调用。
  VoidCallback? onRegistered;

  /// 是否正被远程选中、由本机出声（有当前状态）。
  bool get isActive => _machine != null && _stateIndex >= 0;

  void invalidateSession() => _api.invalidate();

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _idSub = _dealer.connectionIds.listen(_register);
    _msgSub = _dealer.messages.listen(_onMessage);
    _statusSub = _dealer.statusChanges.listen((status) {
      if (status != DealerStatus.online) _resetRegistration();
    });
    try {
      await _dealer.connect();
    } catch (e) {
      debugPrint('[Receiver] dealer 连接失败（后台重试）：$e');
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    final wasRegistered = _registered;
    _resetRegistration();
    await _idSub?.cancel();
    await _msgSub?.cancel();
    await _statusSub?.cancel();
    _clear();
    if (wasRegistered) {
      try {
        await _api.deregister().timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('[Receiver] 注销失败：$e');
      }
    }
    await _dealer.close();
  }

  void _resetRegistration() {
    ++_registrationEpoch;
    ++_revision;
    _registerRetry?.cancel();
    _registerRetry = null;
    _registrationId = null;
    _registration = null;
    _registered = false;
    _registerAttempts = 0;
  }

  Future<void> _register(String connectionId) {
    if (!_started) return Future.value();
    if (_registrationId == connectionId && _registration != null)
      return _registration!;
    _registerRetry?.cancel();
    _registrationId = connectionId;
    final epoch = ++_registrationEpoch;
    return _registration = _doRegister(connectionId, epoch);
  }

  Future<void> _doRegister(String connectionId, int epoch) async {
    bool current() =>
        _started &&
        epoch == _registrationEpoch &&
        _dealer.connectionId == connectionId;
    try {
      final name = deviceName();
      await _api.register(
        connectionId: connectionId,
        name: name,
        volume: 65535,
        isCurrent: current,
      );
      if (!current()) return;
      _registered = true;
      _registerAttempts = 0;
      debugPrint('[Receiver] 已注册为 Connect 设备「$name」');
      onRegistered?.call();
    } catch (e) {
      if (!current()) return;
      _registration = null;
      _registered = false;
      debugPrint('[Receiver] 注册失败：$e');
      final delay = registerRetryDelay * (1 << min(_registerAttempts++, 4));
      _registerRetry = Timer(delay, () {
        if (current()) unawaited(_register(connectionId));
      });
    }
  }

  void _onMessage(DealerMessage message) {
    if (!_started || message.uri != 'hm://track-playback/v1/command') return;
    for (final raw in message.payloads) {
      if (raw is! Map) continue;
      _performCommand(raw.cast<String, dynamic>());
    }
  }

  void _performCommand(Map<String, dynamic> payload) {
    final type = payload['type'];
    debugPrint('[Receiver] 命令 $type');
    switch (type) {
      case 'replace_state':
        // 与官方 Web Player 一致：命令基于的前一状态（prev_state_ref）必须是本机当前状态，
        // 否则这条命令是针对过期状态发的（例如服务端发命令时本机刚汇报了别的变化），
        // 拒绝并经 state_conflict 让服务端给出正确的命令，而不是照着过期命令执行。
        // 不带该字段的命令（旧格式）照旧执行，只有明确对不上才拒绝。
        if (payload.containsKey('prev_state_ref') &&
            !_isCurrentStateRef(payload['prev_state_ref'])) {
          debugPrint(
            '[Receiver] replace_state 基于过期状态 '
            '${payload['prev_state_ref']}，本机为 $_currentStateRef，拒绝',
          );
          _rejectState(_stateRefOf(payload));
          return;
        }
        // track-playback uses an absent/null state_ref to revoke ownership.
        // This is a stop command, not an invalid state machine to ignore.
        if (payload['state_ref'] == null) {
          _clear();
          unawaited(host.stop());
          _report('state_clear', clear: true);
          return;
        }
        final cmd = TpReplaceState.fromJson(payload);
        if (cmd != null) unawaited(_replaceState(cmd));
      case 'set_volume':
        final v = (payload['volume'] as num?)?.toDouble();
        if (v != null) host.setVolume((v / 65535).clamp(0.0, 1.0));
      case 'log_out':
        _clear();
        unawaited(host.stop());
      case 'ping':
        _report('ping');
    }
  }

  /// 本机当前状态引用（state_machine_id / state_id / paused）；没有状态时为 null。
  Map<String, Object>? get _currentStateRef {
    final m = _machine;
    final s = m?.state(_stateIndex);
    if (m == null || s == null) return null;
    return {'state_machine_id': m.id, 'state_id': s.stateId, 'paused': _paused};
  }

  /// [prev] 是否就是本机当前状态（都没有状态也算一致）。
  bool _isCurrentStateRef(Object? prev) {
    final cur = _currentStateRef;
    if (prev is! Map) return cur == null;
    return cur != null &&
        prev['state_machine_id'] == cur['state_machine_id'] &&
        prev['state_id'] == cur['state_id'] &&
        (prev['paused'] == true) == cur['paused'];
  }

  /// replace_state 命令要切到的状态引用（用于 state_conflict 上报被拒的状态）。
  static Map<String, Object>? _stateRefOf(Map<String, dynamic> payload) {
    final machine = payload['state_machine'];
    final ref = payload['state_ref'];
    if (machine is! Map || ref is! Map) return null;
    final states = machine['states'];
    final index = ref['state_index'];
    if (states is! List ||
        index is! int ||
        index < 0 ||
        index >= states.length) {
      return null;
    }
    final state = states[index];
    return {
      'state_machine_id': machine['state_machine_id'] ?? '',
      'state_id': state is Map ? state['state_id'] ?? '' : '',
      'paused': ref['paused'] == true,
    };
  }

  final List<Map<String, Object>?> _rejectedStates = [];
  bool _sendingConflict = false;

  /// 上报被拒的状态，执行服务端在响应里给出的命令（与官方 Web Player 的 `_rejectState` 一致：
  /// 同一时间只发一个请求，每次最多 5 条，发完再处理排队的）。
  void _rejectState(Map<String, Object>? rejected) {
    _rejectedStates.add(rejected);
    _sendNextConflict();
  }

  void _sendNextConflict() {
    if (!_registered || _sendingConflict || _rejectedStates.isEmpty) return;
    _sendingConflict = true;
    final batch = _rejectedStates.take(5).toList();
    _rejectedStates.removeRange(0, batch.length);
    _sending = _sending.then((_) async {
      try {
        final cur = _currentStateRef;
        final m = _machine;
        final s = m?.state(_stateIndex);
        final commands = await _api.postStateConflict(
          stateMachineId: cur?['state_machine_id'] as String?,
          stateId: cur?['state_id'] as String?,
          paused: _paused,
          positionMs: host.positionMs,
          durationMs: s == null ? 0 : m!.trackOf(s)?.durationMs ?? 0,
          rejected: [for (final r in batch) ?r],
        );
        debugPrint('[Receiver] 状态冲突 → ${commands.length} 条命令');
        for (final c in commands) {
          _performCommand(c);
        }
      } catch (e) {
        debugPrint('[Receiver] $e');
      } finally {
        _sendingConflict = false;
        _sendNextConflict();
      }
    });
  }

  Future<void> _replaceState(TpReplaceState cmd) async {
    final revision = ++_revision;
    final prev = _currentTrackUri;
    final playable = cmd.machine.playableState(cmd.ref.stateIndex);
    if (playable == null) {
      // 全广告 / 广告环没有可播放后继：取消旧加载，不展示或播放广告。
      _clear();
      _report('state_clear', clear: true);
      await host.stop();
      return;
    }
    final skippedAd = playable != cmd.ref.stateIndex;
    if (skippedAd) debugPrint('[Receiver] 跳过广告，加载后续曲目');
    _machine = cmd.machine;
    _stateIndex = playable;
    _paused = cmd.ref.paused;
    // 广告进度不能成为后续歌曲的起播位置。
    final seekTo = skippedAd ? 0 : cmd.seekTo;
    final position = seekTo ?? 0;
    _listening.anchor(
      seekTo ?? host.positionMs,
      _clock.elapsedMilliseconds,
      reset: prev != _currentTrackUri,
    );
    host.applyOptions(cmd.machine.options);
    try {
      if (prev != null && prev == _currentTrackUri) {
        host.updateQueue(cmd.machine, cmd.machine.playableChain(_stateIndex));
        await host.sync(positionMs: seekTo, paused: _paused);
      } else {
        _report('before_track_load', positionMs: position);
        await host.load(
          cmd.machine,
          cmd.machine.playableChain(_stateIndex),
          positionMs: position,
          paused: _paused,
        );
      }
      if (revision != _revision) return;
      _listening.anchor(seekTo ?? host.positionMs, _clock.elapsedMilliseconds);
      _report(
        _paused ? 'pause' : 'started_playing',
        positionMs: seekTo ?? host.positionMs,
      );
    } catch (e) {
      debugPrint('[Receiver] 执行 replace_state 失败：$e');
    }
  }

  String? get _currentTrackUri {
    final m = _machine;
    final s = m?.state(_stateIndex);
    return s == null ? null : m!.trackOf(s)?.uri;
  }

  // ---------------------------------------------------------------------------
  // 本机播放器 → 服务端
  // ---------------------------------------------------------------------------

  /// 本机切到了曲目 [trackUri]（播完自动进入 / 本机点了上下一首）：按跳转表找到目标状态并汇报；
  /// 找不到（本机改播了别的歌）时清空状态，Flutify 不再是活动播放端。
  void onLocalTrackChanged(String trackUri, {required int durationMs}) {
    final m = _machine;
    final cur = m?.state(_stateIndex);
    if (m == null || cur == null) return;
    if (_currentTrackUri == trackUri) return;
    int? target;
    for (final (ref, backwards) in [
      (cur.advance, false),
      (cur.skipNext, false),
      (cur.skipPrev, true),
    ]) {
      final index = ref == null
          ? null
          : m.playableState(ref.stateIndex, backwards: backwards);
      final s = index == null ? null : m.state(index);
      if (s != null && m.trackOf(s)?.uri == trackUri) {
        target = index;
        break;
      }
    }
    if (target == null) {
      debugPrint('[Receiver] 本机改播状态机外的曲目，退出 Connect 播放');
      _clear();
      _report('state_clear', clear: true);
      return;
    }
    _stateIndex = target;
    _revision++;
    _listening.anchor(0, _clock.elapsedMilliseconds, reset: true);
    _report('started_playing', positionMs: 0, durationMs: durationMs);
  }

  void onLocalPausedChanged(
    bool paused, {
    required int positionMs,
    required int durationMs,
  }) {
    if (!isActive || paused == _paused) return;
    _paused = paused;
    _listening.anchor(positionMs, _clock.elapsedMilliseconds);
    _report(
      paused ? 'pause' : 'resume',
      positionMs: positionMs,
      durationMs: durationMs,
    );
  }

  void onLocalSeek(int fromMs, int toMs, {required int durationMs}) {
    if (!isActive) return;
    _listening.anchor(toMs, _clock.elapsedMilliseconds);
    _report(
      'seek',
      positionMs: toMs,
      durationMs: durationMs,
      previousPositionMs: fromMs,
    );
  }

  void onLocalProgress(int positionMs, {required int durationMs}) {
    if (!isActive ||
        !_listening.sample(
          positionMs,
          _clock.elapsedMilliseconds,
          playing: !_paused && host.isAudible,
        ))
      return;
    _report(
      'played_threshold_reached',
      positionMs: positionMs,
      durationMs: durationMs,
    );
  }

  void onLocalVolume(double volume) {
    if (!isActive) return;
    unawaited(
      _api
          .putVolume((volume * 65535).round())
          .catchError((Object e) => debugPrint('[Receiver] $e')),
    );
  }

  void _clear() {
    _revision++;
    _machine = null;
    _stateIndex = -1;
    _paused = true;
    _listening.anchor(0, _clock.elapsedMilliseconds, reset: true);
  }

  void _report(
    String debugSource, {
    int positionMs = 0,
    int? durationMs,
    int? previousPositionMs,
    bool clear = false,
  }) {
    if (!_registered) return;
    final revision = _revision;
    // 串行发送：每条都要引用上一条响应换回来的新状态机，并发会引用已失效的 state_id
    _sending = _sending.then((_) async {
      if (revision != _revision || !_registered) return;
      final m = _machine;
      final s = m?.state(_stateIndex);
      final duration =
          durationMs ?? (s == null ? 0 : m!.trackOf(s)?.durationMs ?? 0);
      try {
        final res = await _api.putState(
          debugSource: debugSource,
          stateMachineId: clear ? null : m?.id,
          stateId: clear ? null : s?.stateId,
          paused: _paused,
          positionMs: positionMs,
          durationMs: duration,
          previousPositionMs: previousPositionMs,
          audio: clear || debugSource == 'before_track_load'
              ? const AudioPlaybackInfo()
              : host.audioPlaybackInfo,
        );
        debugPrint(
          '[Receiver] 汇报 $debugSource（${s?.stateId}, paused=$_paused, ${positionMs}ms）'
          '→ ${res == null ? '空响应' : res.keys.join(',')}',
        );
        if (revision == _revision && !clear) _adoptMachine(res);
      } catch (e) {
        debugPrint('[Receiver] $e');
      }
    });
  }

  Future<void> _sending = Future.value();

  /// 汇报响应里的新状态机（服务端扩展了前后曲目）：替换状态机，按 state_id 对回当前状态，不重新加载。
  void _adoptMachine(Map<String, dynamic>? res) {
    if (res == null) return;
    final next = TpStateMachine.fromJson(res['state_machine']);
    if (next == null) return;
    final ref = TpStateRef.fromJson(res['updated_state_ref']);
    final curId = _machine?.state(_stateIndex)?.stateId;
    final index =
        ref?.stateIndex ?? next.states.indexWhere((s) => s.stateId == curId);
    final state = next.state(index);
    if (state == null || next.trackOf(state)?.uri != _currentTrackUri) return;
    _machine = next;
    _stateIndex = index;
    host.updateQueue(next, next.playableChain(index));
  }
}
