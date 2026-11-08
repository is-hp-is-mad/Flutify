import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/connect_cluster.dart';
import '../models/image.dart';
import '../models/track.dart';
import '../services/connect/connect_play_request.dart';
import '../services/connect/connect_service.dart';

/// Spotify Connect 遥控：同账号其他设备的列表、播放状态与远程控制。
///
/// 本机以隐藏观察者身份接入（不会出现在别人的设备列表里），因此 cluster 里的活动设备一定是「别的设备」。
/// - 只有桌面版会话可用（[available]）；其他会话所有操作都是空操作；
/// - 远程曲目的艺人名等信息由 [resolveTrack] 补全（按 URI 缓存）；
/// - 命令失败时抛出 [ConnectException]，由 UI 决定如何提示（免费账号部分操作会被服务端拒绝）。
class ConnectProvider extends ChangeNotifier {
  final ConnectService? _service;
  final bool Function() _available;
  final Future<SpotifyTrack?> Function(String uri) _resolveTrack;

  StreamSubscription<ConnectCluster>? _clusterSub;
  StreamSubscription<ConnectStatus>? _statusSub;
  ConnectCluster _cluster = ConnectCluster.empty;
  ConnectStatus _status = ConnectStatus.idle;

  /// 远程曲目补全缓存：URI → 曲目（null 表示补全失败，不重复请求）。
  final Map<String, SpotifyTrack?> _tracks = {};
  final Set<String> _resolving = {};

  /// 拖动音量时的本地值，避免推送回来前滑块跳回旧值。
  double? _pendingVolume;
  Timer? _volumeTimer;

  bool _disposed = false;

  ConnectProvider(
    this._service, {
    required this._available,
    required this._resolveTrack,
  }) {
    final service = _service;
    if (service == null) return;
    // 广播流不会重放：先取服务当前快照，再订阅后续变化
    _cluster = service.current;
    _status = service.status;
    _remoteInControl = hasRemoteSession && player.isAudible;
    _resolveRemoteTrack(_cluster.player.trackUri);
    _updateDisplayTrack();
    _syncPositionTicker();
    _clusterSub = service.clusters.listen(_onCluster);
    _statusSub = service.statusChanges.listen((s) {
      _status = s;
      _notify();
    });
    sessionChanged();
  }

  /// 当前会话能否使用 Connect（桌面版登录）。
  bool get available => _service != null && _available();

  ConnectStatus get status => _status;
  ConnectCluster get cluster => _cluster;

  /// 其他设备（不含本机注册的播放端，它在界面上就是「此设备」）。
  List<ConnectDevice> get devices => [
    for (final d in _cluster.devices)
      if (d.id != receiverDeviceId) d,
  ];

  /// 本机作为 Connect 播放端注册的设备 id：它被选中时声音就在本机，不算「远程」设备。
  String? receiverDeviceId;
  String? _pendingTarget;
  int _targetRevision = 0;
  Future<void>? _receiverTransfer;

  /// 切换设备期间立即按用户选中的目标路由后续点歌，不再使用旧 PC 快照。
  Future<void> _withTarget(
    String target,
    Future<void> Function() action,
  ) async {
    final revision = ++_targetRevision;
    _pendingTarget = target;
    _notify();
    try {
      await action();
    } finally {
      if (revision == _targetRevision) {
        _pendingTarget = null;
        _notify();
      }
    }
  }

  /// 本机播放端已出现在账号的设备列表里：本机点歌改为经 Connect 下发给自己，其他设备才能同步。
  bool get receiverOnline =>
      receiverDeviceId != null &&
      _cluster.devices.any((d) => d.id == receiverDeviceId);

  /// 在本机播放端上播放（服务端随后推 replace_state 给本机）。
  Future<void> playOnReceiver(
    ConnectPlayRequest request, {
    int? seekToMs,
    bool paused = false,
    bool? repeatingContext,
    bool? repeatingTrack,
  }) => _withTarget(
    receiverDeviceId!,
    () => _service!.play(
      receiverDeviceId!,
      contextUri: request.contextUri,
      trackUris: request.trackUris,
      trackUri: request.trackUri,
      trackIndex: request.trackIndex,
      seekToMs: seekToMs,
      paused: paused,
      repeatingContext: repeatingContext,
      repeatingTrack: repeatingTrack,
      confirm: true,
    ),
  );

  /// 本机播放端上改随机 / 循环：发给服务端，其他设备随之更新。
  Future<bool> setReceiverOptions({
    bool? shuffle,
    bool? repeatContext,
    bool? repeatTrack,
  }) async {
    final id = receiverDeviceId;
    if (id == null) return false;
    try {
      if (shuffle != null) {
        await _service!.setShuffle(id, shuffle);
      }
      if (repeatContext != null || repeatTrack != null) {
        await _service!.setRepeat(
          id,
          context: repeatContext ?? false,
          track: repeatTrack ?? false,
        );
      }
      return true;
    } catch (e) {
      debugPrint('[Connect] 同步接收端选项失败: $e');
      return false;
    }
  }

  /// 把远程设备上的播放转到本机播放端（同一首、同一进度）。
  Future<void> transferToReceiver() => _receiverTransfer ??= _withTarget(
    receiverDeviceId!,
    () => _service!.transfer(receiverDeviceId!, confirm: true),
  ).whenComplete(() => _receiverTransfer = null);

  /// 正在使用的（远程）设备；没有活动设备时为 null。

  ConnectDevice? get activeDevice {
    final pending = _pendingTarget;
    if (pending == receiverDeviceId && pending != null) return null;
    if (pending != null) {
      for (final device in _cluster.devices) {
        if (device.id == pending) return device;
      }
    }
    final device = _cluster.activeDevice;
    return device != null && device.id == receiverDeviceId ? null : device;
  }

  ConnectPlayerState get player => _cluster.player;

  /// 有远程设备且它上面有曲目（播放中或已暂停）。
  bool get hasRemoteSession => activeDevice != null && player.hasTrack;

  /// 播放控制（播放栏、快捷键、媒体键）是否应发给远程设备，即播放栏是否为远程模式：
  /// 以集群状态为准 —— 只要集群里有活动设备且带曲目（播放中或已暂停）就归远程；
  /// 仅当本机正在出声（[localPlaying]）时才归本机。不再推断「最后出声方」。
  bool controlsRemote({
    required bool localPlaying,
    required bool localHasTrack,
  }) =>
      // 以集群状态为准：本 App 只是观察者、自己不是 Connect 设备，只要集群里有活动设备且带曲目，
      // 播放的就是那台设备；仅当本机正在出声（本地文件等）才归本机。不再推断“最后出声方”。
      hasRemoteSession && !localPlaying;

  /// 最后出声的一方是否为远程设备：远程开始出声时置为 true，本机开始播放时（[localPlaybackStarted]）置为 false。
  bool get remoteInControl => _remoteInControl;
  bool _remoteInControl = false;

  /// 本机开始播放时调用（由 main.dart 监听播放 Provider 接上）：控制权回到本机。
  void localPlaybackStarted() {
    if (!_remoteInControl) return;
    _remoteInControl = false;
    _notify();
  }

  /// 远程曲目的完整信息（含艺人）；补全中或失败时为 null，UI 回退到 [player] 里的标题 / 专辑。
  SpotifyTrack? get remoteTrack => _tracks[player.trackUri];

  /// 供歌词、右栏等「按曲目展示」的界面使用：补全后为完整曲目，补全前由 [player] 的标题 / 专辑 / 封面拼出；
  /// 不是曲目（播客单集等）时为 null。按曲目缓存，同一首歌返回同一个对象，`select` 不会无谓重建。
  SpotifyTrack? get displayTrack => _displayTrack;
  SpotifyTrack? _displayTrack;

  /// 远程播放进度（按服务端快照推算）：远程出声时每 250ms 更新，歌词按它切行。
  ValueListenable<Duration> get position => _position;
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  Timer? _positionTimer;

  /// 服务端当前时间，用于推算远程播放进度。
  int get serverNowMs =>
      _service?.serverNowMs ?? DateTime.now().millisecondsSinceEpoch;

  /// 远程设备当前音量（拖动中优先返回本地值）。
  double get volume => _pendingVolume ?? activeDevice?.volume ?? 1;

  /// 登录态变化后调用：桌面版会话启动连接，否则断开并清空。
  Future<void> sessionChanged() async {
    final service = _service;
    if (service == null) return;
    if (available) {
      try {
        await service.start();
      } catch (_) {
        // 连接失败由 status 体现（offline），服务内部会自动重连
      }
    } else {
      await service.stop();
      _cluster = ConnectCluster.empty;
      _remoteInControl = false;
      _tracks.clear();
      _updateDisplayTrack();
      _syncPositionTicker();
      _notify();
    }
  }

  /// 打开设备面板时调用：主动拉一次全量状态，避免推送遗漏。
  Future<void> refresh() async {
    if (!available || _status != ConnectStatus.online) return;
    try {
      await _service!.refresh();
    } catch (_) {}
  }

  void _onCluster(ConnectCluster cluster) {
    // 只在远程「开始出声」时接管：本机播放期间远程一直在响的快照不应抢走控制权
    final wasAudible = hasRemoteSession && player.isAudible;
    _cluster = cluster;
    if (!wasAudible && hasRemoteSession && player.isAudible)
      _remoteInControl = true;
    if (_pendingVolume != null && _volumeTimer == null) _pendingVolume = null;
    _resolveRemoteTrack(cluster.player.trackUri);
    _updateDisplayTrack();
    _syncPositionTicker();
    _notify();
  }

  void _resolveRemoteTrack(String uri) {
    if (uri.isEmpty || _tracks.containsKey(uri) || _resolving.contains(uri))
      return;
    _resolving.add(uri);
    _resolveTrack(uri)
        .then(
          (track) => _tracks[uri] = track,
          onError: (_) => _tracks[uri] = null,
        )
        .whenComplete(() {
          _resolving.remove(uri);
          _updateDisplayTrack();
          _notify();
        });
  }

  void _updateDisplayTrack() {
    final p = player;
    final resolved = remoteTrack;
    if (resolved != null) {
      _displayTrack = resolved;
    } else if (p.trackId.isEmpty) {
      _displayTrack = null;
    } else if (_displayTrack?.uri != p.trackUri) {
      _displayTrack = SpotifyTrack(
        id: p.trackId,
        name: p.title,
        uri: p.trackUri,
        durationMs: p.durationMs,
        album: SpotifyAlbum(
          id: p.albumUri.startsWith('spotify:album:')
              ? p.albumUri.substring(14)
              : '',
          name: p.albumTitle,
          uri: p.albumUri,
          images: [if (p.imageUrl.isNotEmpty) SpotifyImage(url: p.imageUrl)],
        ),
      );
    }
  }

  /// 远程出声时定时推算进度；暂停 / 无会话时停表，只在收到快照时更新一次。
  void _syncPositionTicker() {
    if (_disposed) return;
    _tickPosition();
    final ticking = hasRemoteSession && player.isAudible;
    if (ticking && _positionTimer == null) {
      _positionTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _tickPosition(),
      );
    } else if (!ticking) {
      _positionTimer?.cancel();
      _positionTimer = null;
    }
  }

  void _tickPosition() =>
      _position.value = Duration(milliseconds: player.positionAt(serverNowMs));

  // ---------------------------------------------------------------------------
  // 远程控制：全部作用于当前活动设备
  // ---------------------------------------------------------------------------

  String? get _target => activeDevice?.id;

  /// 把播放转移到 [device]（保持原播放 / 暂停状态之外，默认继续播放）。
  Future<void> transferTo(ConnectDevice device) => _withTarget(
    device.id,
    () => _service!.transfer(device.id, confirm: true),
  );

  /// 在活动设备上播放新内容（本机点歌时由 PlaybackProvider 的远程接管钩子调用）。
  /// 发出后视为远程掌握控制权，播放栏保持远程模式。
  Future<void> play(ConnectPlayRequest request) async {
    final target = _target;
    if (target == null) return;
    await _service!.play(
      target,
      contextUri: request.contextUri,
      trackUris: request.trackUris,
      trackUri: request.trackUri,
      trackIndex: request.trackIndex,
      confirm: true,
    );
    _remoteInControl = true;
    _notify();
  }

  Future<void> togglePlayPause() async {
    final target = _target;
    if (target == null) return;
    player.isAudible
        ? await _service!.pause(target)
        : await _service!.resume(target);
  }

  Future<void> pause() async {
    final target = _target;
    if (target != null && player.isAudible) await _service!.pause(target);
  }

  Future<void> skipNext() async {
    final target = _target;
    if (target != null) await _service!.skipNext(target);
  }

  Future<void> skipPrevious() async {
    final target = _target;
    if (target != null) await _service!.skipPrevious(target);
  }

  Future<void> seekTo(int positionMs) async {
    final target = _target;
    if (target != null) await _service!.seekTo(target, positionMs);
  }

  Future<void> toggleShuffle() async {
    final target = _target;
    if (target != null) await _service!.setShuffle(target, !player.shuffle);
  }

  /// 循环：关 → 列表循环 → 单曲循环 → 关（与本地播放器一致）。
  Future<void> cycleRepeat() async {
    final target = _target;
    if (target == null) return;
    final (context, track) = switch ((
      player.repeatContext,
      player.repeatTrack,
    )) {
      (false, false) => (true, false),
      (true, false) => (true, true),
      _ => (false, false),
    };
    await _service!.setRepeat(target, context: context, track: track);
  }

  /// 拖动音量：本地立即生效，请求节流到每 150ms 一次。
  void setVolume(double value) {
    final target = _target;
    if (target == null) return;
    _pendingVolume = value.clamp(0.0, 1.0);
    _notify();
    _volumeTimer ??= Timer(const Duration(milliseconds: 150), () {
      _volumeTimer = null;
      final v = _pendingVolume;
      if (v != null) _service!.setVolume(target, v).catchError((_) {});
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _volumeTimer?.cancel();
    _positionTimer?.cancel();
    _position.dispose();
    _clusterSub?.cancel();
    _statusSub?.cancel();
    _service?.stop();
    super.dispose();
  }
}
