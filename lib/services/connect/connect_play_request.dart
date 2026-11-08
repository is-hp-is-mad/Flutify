import '../../models/playback_context.dart';
import '../../models/track.dart';

/// 发给 Connect 远程设备的一次「播放」请求（对应 [ConnectService.play] 的参数）。
///
/// 两种形态：
/// - [contextUri] 非空：远程设备自己展开上下文（歌单 / 专辑 / 艺人 / 已点赞的歌曲），从 [trackUri] 开始；
/// - [contextUri] 为空：以 [trackUris] 临时列表播放（搜索结果、单曲等没有 Spotify 上下文的场景），从 [trackIndex] 开始。
class ConnectPlayRequest {
  final String contextUri;
  final List<String> trackUris;
  final String? trackUri;
  final int? trackIndex;

  const ConnectPlayRequest({this.contextUri = '', this.trackUris = const [], this.trackUri, this.trackIndex});

  /// 临时列表最多带多少首：请求体过大会被服务端拒绝，超出时以起始曲目为首截取。
  static const maxTrackUris = 500;

  /// 本机的「已点赞的歌曲」URI（见 LibraryProvider.likedSongsUri），远程设备只认按用户名的形式。
  static const _likedSongsUri = 'spotify:collection:tracks';

  /// 远程设备能直接展开的上下文前缀。
  static const _contextPrefixes = ['spotify:playlist:', 'spotify:album:', 'spotify:artist:'];

  /// 由本机的播放参数生成远程请求：[start] 为 null 表示从头播放整个上下文（详情页大播放按钮）。
  ///
  /// 返回 null 表示这次播放无法交给远程设备（起始曲目没有 Spotify URI，如本地文件），应在本机播放。
  static ConnectPlayRequest? from({
    required PlaybackContext context,
    required List<SpotifyTrack> tracks,
    SpotifyTrack? start,
    required String username,
  }) {
    final startUri = start == null ? null : _uriOf(start);
    if (start != null && startUri == null) return null;

    var contextUri = context.uri;
    if (contextUri == _likedSongsUri) contextUri = username.isEmpty ? '' : 'spotify:user:$username:collection';
    if (_contextPrefixes.any(contextUri.startsWith) || contextUri.endsWith(':collection')) {
      return ConnectPlayRequest(contextUri: contextUri, trackUri: startUri);
    }

    // 没有可用上下文：带上整个列表（跳过本地文件等没有 URI 的曲目）
    var uris = [for (final t in tracks) ?_uriOf(t)];
    if (startUri != null && !uris.contains(startUri)) uris = [startUri, ...uris];
    if (uris.isEmpty) return null;
    var index = startUri == null ? 0 : uris.indexOf(startUri);
    if (uris.length > maxTrackUris) {
      uris = uris.sublist(index, (index + maxTrackUris).clamp(0, uris.length));
      index = 0;
    }
    return ConnectPlayRequest(trackUris: uris, trackUri: startUri, trackIndex: startUri == null ? null : index);
  }

  /// 曲目 / 单集的 Spotify URI；本地文件等无法远程播放的返回 null。
  static String? _uriOf(SpotifyTrack track) {
    final uri = track.uri.isNotEmpty ? track.uri : (track.id.isEmpty ? '' : 'spotify:track:${track.id}');
    return uri.startsWith('spotify:track:') || uri.startsWith('spotify:episode:') ? uri : null;
  }
}
