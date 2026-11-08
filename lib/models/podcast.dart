import 'album.dart';
import 'artist.dart';
import 'image.dart';
import 'track.dart';

/// 播客节目（show）。
///
/// 数据来源：open.spotify.com 节目页的服务端渲染状态（见 `PodcastService`），
/// 无需登录、不受桌面版 client_id 的 Web API 限流影响。
class PodcastShow {
  final String id;
  final String uri;
  final String name;
  final String publisher;
  final String description;
  final List<SpotifyImage> images;

  /// 最新一页单集（节目页只带最近约 12 集）。
  final List<PodcastEpisode> episodes;

  const PodcastShow({
    required this.id,
    required this.uri,
    required this.name,
    this.publisher = '',
    this.description = '',
    this.images = const [],
    this.episodes = const [],
  });

  String get coverUrl => images.isEmpty ? '' : images.first.url;
}

/// 播客单集（episode）。
class PodcastEpisode {
  final String id;
  final String uri;
  final String name;
  final String description;
  final int durationMs;
  final String releaseDate;
  final List<SpotifyImage> images;

  /// 所属节目（列表项里用于副标题与封面兜底）。
  final String showUri;
  final String showName;

  /// 30 秒试听（`p.scdn.co/mp3-preview/...`）；空串表示没有。
  final String previewUrl;

  /// 续播位置（毫秒）；0 表示未开始。
  final int resumeMs;

  /// 已播完。
  final bool played;

  const PodcastEpisode({
    required this.id,
    required this.uri,
    required this.name,
    this.description = '',
    this.durationMs = 0,
    this.releaseDate = '',
    this.images = const [],
    this.showUri = '',
    this.showName = '',
    this.previewUrl = '',
    this.resumeMs = 0,
    this.played = false,
  });

  String get coverUrl => images.isEmpty ? '' : images.first.url;

  /// 映射为播放层通用的曲目模型：uri 保留 `spotify:episode:` 前缀，
  /// 音频加载器按它走单集协议链路（mercury metadata → CDN）。
  SpotifyTrack toTrack() => SpotifyTrack(
    id: id,
    name: name,
    uri: uri,
    artists: [SpotifyArtist(id: '', name: showName)],
    album: SpotifyAlbum(id: '', name: showName, images: images),
    durationMs: durationMs,
    previewUrl: previewUrl.isEmpty ? null : previewUrl,
  );
}
