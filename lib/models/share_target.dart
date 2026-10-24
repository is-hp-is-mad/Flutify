import '../core/rust_core.dart';
import '../services/protocol/spotify_id.dart';
import '../src/rust/api/protocol.dart' as rust;
import 'album.dart';
import 'artist.dart';
import 'playlist.dart';
import 'track.dart';

/// 可分享的 Spotify 内容类型；[path] 同时用于网页链接、URI 与嵌入地址。
enum ShareKind {
  track('track'),
  album('album'),
  playlist('playlist'),
  artist('artist');

  final String path;

  const ShareKind(this.path);
}

/// 嵌入播放器尺寸：与 Spotify 官方嵌入生成器的两档高度一致。
enum EmbedSize {
  standard(352),
  compact(152);

  final int height;

  const EmbedSize(this.height);
}

/// 一次分享的对象：标题、副标题、封面供分享面板展示，链接与嵌入代码由 id 推导。
class ShareTarget {
  final ShareKind kind;
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;

  const ShareTarget({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.imageUrl = '',
  });

  factory ShareTarget.track(SpotifyTrack track) => ShareTarget(
    kind: ShareKind.track,
    id: track.id,
    title: track.name,
    subtitle: track.artistNames,
    imageUrl: track.coverUrl,
  );

  factory ShareTarget.album(SpotifyAlbum album) => ShareTarget(
    kind: ShareKind.album,
    id: album.id,
    title: album.name,
    subtitle: album.artistNames,
    imageUrl: album.coverUrl,
  );

  factory ShareTarget.playlist(SpotifyPlaylist playlist) => ShareTarget(
    kind: ShareKind.playlist,
    id: playlist.id,
    title: playlist.name,
    subtitle: playlist.ownerName,
    imageUrl: playlist.coverUrl,
  );

  factory ShareTarget.artist(SpotifyArtist artist) =>
      ShareTarget(kind: ShareKind.artist, id: artist.id, title: artist.name, imageUrl: artist.avatarUrl);

  /// Spotify 的 base62 id（22 位字母数字）；本地歌单（local_…）、「已点赞的歌曲」等没有公开链接。
  static final RegExp _spotifyId = RegExp(r'^[0-9A-Za-z]{22}$');

  /// 是否存在可公开访问的链接；为 false 时不应展示分享入口。
  bool get isShareable => _spotifyId.hasMatch(id);

  /// 网页链接（open.spotify.com），未安装客户端的人也能打开。
  String get webUrl => 'https://open.spotify.com/${kind.path}/$id';

  /// Spotify URI，可粘贴到客户端搜索框直接跳转。
  String get uri => 'spotify:${kind.path}:$id';

  /// 嵌入播放器地址；[dark] 为 true 时强制深色（theme=0），否则跟随封面取色。
  String embedUrl({bool dark = false}) =>
      'https://open.spotify.com/embed/${kind.path}/$id?utm_source=generator${dark ? '&theme=0' : ''}';

  /// 完整的 iframe 嵌入代码，属性与官方生成器一致，另加 title 便于读屏软件识别。
  String embedCode({EmbedSize size = EmbedSize.standard, bool dark = false}) {
    final label = _escapeAttribute('Spotify: $title');
    return '<iframe title="$label" style="border-radius:12px" src="${embedUrl(dark: dark)}" '
        'width="100%" height="${size.height}" frameBorder="0" allowfullscreen="" '
        'allow="autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture" loading="lazy"></iframe>';
  }

  /// HTML 属性值转义：标题里可能有引号、尖括号、&。
  static String _escapeAttribute(String value) =>
      value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

/// 解析出的 Spotify 分享链接 / URI（如 `spotify:track:xxx` 或 `https://open.spotify.com/track/xxx`）。
class SpotifyLink {
  final ShareKind kind;
  final String id;

  const SpotifyLink(this.kind, this.id);

  String get uri => 'spotify:${kind.path}:$id';

  static ShareKind? _kindOf(String raw) => switch (raw.toLowerCase()) {
    'track' => ShareKind.track,
    'album' => ShareKind.album,
    'playlist' => ShareKind.playlist,
    'artist' => ShareKind.artist,
    _ => null,
  };

  static SpotifyLink? _build(String rawKind, String rawId) {
    final kind = _kindOf(rawKind);
    if (kind == null) return null;
    final match = RegExp(r'^[0-9A-Za-z]+').firstMatch(rawId);
    final id = match?.group(0) ?? '';
    try {
      SpotifyId.fromBase62(id);
    } on FormatException {
      return null;
    }
    return SpotifyLink(kind, id);
  }

  /// 从任意输入文本（搜索框输入、分享文案、`spotify:track:xxx`、`open.spotify.com` 链接）解析目标。
  static SpotifyLink? parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    if (RustCore.ready) {
      final res = rust.parseSpotifyLink(input: trimmed);
      if (res == null) return null;
      final kind = _kindOf(res.kind);
      return kind == null ? null : SpotifyLink(kind, res.id);
    }

    final uriMatch = RegExp(
      r'spotify:(?:user:[^:\s]+:)?(track|album|playlist|artist):([0-9A-Za-z]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (uriMatch != null) {
      final link = _build(uriMatch.group(1)!, uriMatch.group(2)!);
      if (link != null) return link;
    }

    final urlMatch = RegExp(
      r'(?:open|play)\.spotify\.com/(?:intl-[a-zA-Z-]+/|embed/)?(track|album|playlist|artist)/([0-9A-Za-z]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (urlMatch != null) {
      return _build(urlMatch.group(1)!, urlMatch.group(2)!);
    }
    return null;
  }
}
