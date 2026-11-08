/// Spotify Connect 的账号级状态（cluster）：同一账号下所有在线设备 + 当前播放状态。
///
/// 来源有两处，结构相同（JSON）：
/// - 注册观察者 `PUT connect-state/v1/devices/hobs_{id}` 的响应体本身；
/// - dealer 推送 `hm://connect-state/v1/cluster` 的 `payloads[0].cluster`。
/// 64 位整数（时间戳、进度、时长）在 JSON 里是字符串，统一用 [_int] 解析。
library;

/// Connect 设备类型（服务端 `device_type` 枚举名）。
enum ConnectDeviceType {
  computer,
  smartphone,
  tablet,
  speaker,
  tv,
  castAudio,
  castVideo,
  automobile,
  gameConsole,
  smartWatch,
  unknown;

  static ConnectDeviceType parse(String? raw) => switch (raw) {
    'COMPUTER' => computer,
    'SMARTPHONE' => smartphone,
    'TABLET' => tablet,
    'SPEAKER' || 'AVR' || 'STB' || 'AUDIO_DONGLE' => speaker,
    'TV' => tv,
    'CAST_AUDIO' => castAudio,
    'CAST_VIDEO' => castVideo,
    'AUTOMOBILE' => automobile,
    'GAME_CONSOLE' => gameConsole,
    'SMARTWATCH' => smartWatch,
    _ => unknown,
  };
}

/// 一台 Connect 设备。
class ConnectDevice {
  final String id;
  final String name;
  final ConnectDeviceType type;

  /// 音量 0 – 1（服务端为 0 – 65535）。
  final double volume;

  /// 音量级数；0 表示设备不允许远程调音量。
  final int volumeSteps;

  /// 能否作为播放端（转移播放的目标）。
  final bool canPlay;

  /// 能否被远程控制（播放 / 暂停 / 切歌）。
  final bool isControllable;

  /// 与本机在同一局域网。
  final bool isSameNetwork;

  const ConnectDevice({
    required this.id,
    required this.name,
    required this.type,
    this.volume = 1,
    this.volumeSteps = 0,
    this.canPlay = true,
    this.isControllable = true,
    this.isSameNetwork = false,
  });

  bool get supportsVolume => volumeSteps > 0;

  static ConnectDevice? fromJson(String key, Map<String, dynamic> json) {
    final caps = (json['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
    // 隐藏设备（其他观察者，如网页播放器的 hobs_ 设备）不展示
    if (caps['hidden'] == true) return null;
    final id = json['device_id'] as String? ?? key;
    if (id.isEmpty) return null;
    return ConnectDevice(
      id: id,
      name: json['name'] as String? ?? '',
      type: ConnectDeviceType.parse(json['device_type'] as String?),
      volume: (_int(json['volume']) / 65535).clamp(0.0, 1.0),
      volumeSteps: _int(caps['volume_steps']),
      canPlay: json['can_play'] as bool? ?? caps['can_be_player'] as bool? ?? true,
      isControllable: caps['is_controllable'] as bool? ?? true,
      isSameNetwork: json['is_same_network'] as bool? ?? false,
    );
  }
}

/// 活动设备上的播放状态。
class ConnectPlayerState {
  final String trackUri;
  final String title;
  final String albumTitle;
  final String albumUri;
  final String artistUri;

  /// 封面（https；服务端给的是 `spotify:image:{hex}`，已转换）。
  final String imageUrl;
  final String contextUri;
  final bool isPlaying;
  final bool isPaused;

  /// [timestampMs]（服务端时钟）时刻的播放进度。
  final int positionMs;
  final int timestampMs;
  final int durationMs;
  final double playbackSpeed;
  final bool shuffle;
  final bool repeatContext;
  final bool repeatTrack;

  const ConnectPlayerState({
    this.trackUri = '',
    this.title = '',
    this.albumTitle = '',
    this.albumUri = '',
    this.artistUri = '',
    this.imageUrl = '',
    this.contextUri = '',
    this.isPlaying = false,
    this.isPaused = false,
    this.positionMs = 0,
    this.timestampMs = 0,
    this.durationMs = 0,
    this.playbackSpeed = 1,
    this.shuffle = false,
    this.repeatContext = false,
    this.repeatTrack = false,
  });

  static const ConnectPlayerState idle = ConnectPlayerState();

  bool get hasTrack => trackUri.isNotEmpty;

  /// 正在出声（播放中且未暂停）。
  bool get isAudible => isPlaying && !isPaused;

  /// 曲目 base62 id（`spotify:track:{id}`）；非曲目（播客单集等）为空。
  String get trackId => trackUri.startsWith('spotify:track:') ? trackUri.substring(14) : '';

  /// 按服务端时间 [serverNowMs] 推算的当前进度。
  int positionAt(int serverNowMs) {
    if (!isAudible || timestampMs == 0) return positionMs.clamp(0, durationMs > 0 ? durationMs : positionMs);
    final elapsed = ((serverNowMs - timestampMs) * playbackSpeed).round();
    final position = positionMs + (elapsed > 0 ? elapsed : 0);
    return durationMs > 0 ? position.clamp(0, durationMs) : position;
  }

  factory ConnectPlayerState.fromJson(Map<String, dynamic> json) {
    final track = (json['track'] as Map?)?.cast<String, dynamic>() ?? const {};
    final meta = (track['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final options = (json['options'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ConnectPlayerState(
      trackUri: track['uri'] as String? ?? '',
      title: meta['title'] as String? ?? '',
      albumTitle: meta['album_title'] as String? ?? '',
      albumUri: meta['album_uri'] as String? ?? '',
      artistUri: meta['artist_uri'] as String? ?? '',
      imageUrl: imageUrlOf(meta['image_large_url'] as String? ?? meta['image_url'] as String?),
      contextUri: json['context_uri'] as String? ?? '',
      isPlaying: json['is_playing'] as bool? ?? false,
      isPaused: json['is_paused'] as bool? ?? false,
      positionMs: _int(json['position_as_of_timestamp']),
      timestampMs: _int(json['timestamp']),
      durationMs: _int(json['duration']),
      playbackSpeed: (json['playback_speed'] as num?)?.toDouble() ?? 1,
      shuffle: options['shuffling_context'] as bool? ?? false,
      repeatContext: options['repeating_context'] as bool? ?? false,
      repeatTrack: options['repeating_track'] as bool? ?? false,
    );
  }

  /// `spotify:image:{hex}` → `https://i.scdn.co/image/{hex}`；已是 http(s) 的原样返回。
  static String imageUrlOf(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    if (raw.startsWith('http')) return raw;
    const prefix = 'spotify:image:';
    return raw.startsWith(prefix) ? 'https://i.scdn.co/image/${raw.substring(prefix.length)}' : '';
  }
}

/// 账号级 Connect 状态快照。
class ConnectCluster {
  /// 当前出声的设备；没有活动设备时为空。
  final String activeDeviceId;

  /// 可见设备：活动设备在前，其余按名称排序。
  final List<ConnectDevice> devices;
  final ConnectPlayerState player;

  /// 服务端生成该快照的时间，用于推算进度与本地时钟偏差。
  final int serverTimestampMs;

  const ConnectCluster({
    this.activeDeviceId = '',
    this.devices = const [],
    this.player = ConnectPlayerState.idle,
    this.serverTimestampMs = 0,
  });

  static const ConnectCluster empty = ConnectCluster();

  ConnectDevice? get activeDevice {
    for (final d in devices) {
      if (d.id == activeDeviceId) return d;
    }
    return null;
  }

  /// 同时接受注册响应（cluster 本身）与推送（`{cluster, update_reason, …}`）。
  factory ConnectCluster.fromJson(Map<String, dynamic> json) {
    final body = json['cluster'] is Map ? (json['cluster'] as Map).cast<String, dynamic>() : json;
    final activeId = body['active_device_id'] as String? ?? '';
    final rawDevices = (body['devices'] as Map?)?.cast<String, dynamic>() ?? const {};
    final devices =
        <ConnectDevice>[
          for (final entry in rawDevices.entries)
            if (entry.value is Map) ?ConnectDevice.fromJson(entry.key, (entry.value as Map).cast<String, dynamic>()),
        ]..sort((a, b) {
          if (a.id == activeId) return -1;
          if (b.id == activeId) return 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    final player = body['player_state'] is Map
        ? ConnectPlayerState.fromJson((body['player_state'] as Map).cast<String, dynamic>())
        : ConnectPlayerState.idle;
    return ConnectCluster(
      activeDeviceId: activeId,
      devices: devices,
      player: player,
      serverTimestampMs: _int(body['server_timestamp_ms']).nonZeroOr(_int(body['timestamp'])),
    );
  }
}

/// JSON 里的 64 位整数可能是字符串或数字。
int _int(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s) ?? 0,
  _ => 0,
};

extension on int {
  int nonZeroOr(int other) => this != 0 ? this : other;
}
