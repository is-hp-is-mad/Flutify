import 'playback_context.dart';
import 'playback_state.dart';
import 'track.dart';

/// 上次播放会话（重启后还原迷你播放器 / 播放栏、队列与进度）。
///
/// 只保存播放顺序中当前曲目附近的一段（[maxBefore] 首之前 + [maxAfter] 首之后），
/// 超长歌单不会把几千首曲目写进文件；还原后按保存时的播放顺序继续。
class PlaybackSession {
  /// 当前曲目之前最多保留几首（「上一首」可用）。
  static const int maxBefore = 20;

  /// 当前曲目之后最多保留几首。
  static const int maxAfter = 200;

  /// 用户手动添加的队列最多保留几首。
  static const int maxUserQueue = 100;

  /// 按播放顺序排列的上下文曲目（已按 [maxBefore] / [maxAfter] 截取）。
  final List<SpotifyTrack> tracks;

  /// 上下文播放位置在 [tracks] 中的下标（「接下来播放」从它之后开始）。
  /// 当前曲目来自用户队列时，这里是最后播放过的上下文曲目，与 [current] 不同。
  final int index;

  /// 当前曲目。
  final SpotifyTrack current;

  final List<SpotifyTrack> userQueue;
  final PlaybackContext context;
  final Duration position;
  final bool shuffle;
  final SpotifyRepeatMode repeatMode;

  const PlaybackSession({
    required this.tracks,
    required this.index,
    required this.current,
    this.userQueue = const [],
    this.context = PlaybackContext.none,
    this.position = Duration.zero,
    this.shuffle = false,
    this.repeatMode = SpotifyRepeatMode.off,
  });

  Map<String, dynamic> toJson() => {
    'v': 1,
    'tracks': [for (final t in tracks) t.toJson()],
    'index': index,
    'current': current.toJson(),
    'queue': [for (final t in userQueue) t.toJson()],
    'context': {'type': context.type, 'name': context.name, 'uri': context.uri},
    'position_ms': position.inMilliseconds,
    'shuffle': shuffle,
    'repeat': repeatMode.name,
  };

  /// 解析失败（旧格式 / 文件损坏）时返回 null，调用方按「没有上次会话」处理。
  static PlaybackSession? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      List<SpotifyTrack> trackList(Object? raw) => [
        for (final item in (raw as List?) ?? const [])
          if (item is Map) SpotifyTrack.fromJson(item.cast<String, dynamic>()),
      ];
      final current = json['current'];
      if (current is! Map) return null;
      final track = SpotifyTrack.fromJson(current.cast<String, dynamic>());
      if (track.id.isEmpty) return null;
      final tracks = trackList(json['tracks']);
      final rawIndex = (json['index'] as num?)?.toInt() ?? 0;
      final index = tracks.isEmpty ? 0 : rawIndex.clamp(0, tracks.length - 1);
      final ctx = json['context'];
      return PlaybackSession(
        tracks: tracks,
        index: index,
        current: track,
        userQueue: trackList(json['queue']),
        context: ctx is Map
            ? PlaybackContext(
                type: ctx['type'] as String? ?? 'none',
                name: ctx['name'] as String? ?? '',
                uri: ctx['uri'] as String? ?? '',
              )
            : PlaybackContext.none,
        position: Duration(milliseconds: ((json['position_ms'] as num?)?.toInt() ?? 0).clamp(0, 1 << 31)),
        shuffle: json['shuffle'] == true,
        repeatMode: SpotifyRepeatMode.values.firstWhere(
          (m) => m.name == json['repeat'],
          orElse: () => SpotifyRepeatMode.off,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
