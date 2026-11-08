import '../../models/playlist.dart';
import '../pathfinder/pathfinder_parsers.dart';
import 'playlist_cover.dart';

/// 把 spclient `playlist/v2/user/{username}/rootlist`（JSON）解析成歌单列表。
///
/// 响应结构（字段缺失一律宽松处理）：
/// ```
/// contents.items[]     { uri, attributes.timestamp }          // 与 metaItems 按下标一一对应
/// contents.metaItems[] { attributes{name,pictureSize[] | picture}, length, ownerUsername }
/// ```
/// - `spotify:playlist:*` 才是歌单；`spotify:start-group:` / `end-group:` 是文件夹标记，
///   文件夹内的歌单按出现顺序平铺（App 暂无文件夹层级）；
/// - 「已点赞的歌曲」不在 rootlist 内，由收藏集合单独提供。
class RootlistParser {
  RootlistParser._();

  static List<SpotifyPlaylist> parse(Map<String, dynamic> json) {
    final contents = _map(json['contents']);
    final items = _list(contents?['items']);
    final metas = _list(contents?['metaItems']);

    final result = <SpotifyPlaylist>[];
    for (var i = 0; i < items.length; i++) {
      final uri = _map(items[i])?['uri'];
      if (uri is! String || !uri.startsWith('spotify:playlist:')) continue;

      final meta = i < metas.length ? _map(metas[i]) : null;
      final attributes = _map(meta?['attributes']);
      final owner = meta?['ownerUsername'] as String? ?? '';

      result.add(SpotifyPlaylist(
        id: PathfinderParsers.idFromUri(uri),
        name: attributes?['name'] as String? ?? '',
        uri: uri,
        description: PathfinderParsers.stripHtml(attributes?['description'] as String? ?? ''),
        ownerName: owner,
        // pictureSize / 上传封面 picture；都没有时由数据源按曲目拼四宫格
        images: PlaylistCover.fromAttributes(attributes),
        totalTracks: _int(meta?['length']) ?? 0,
      ));
    }
    return result;
  }

  static Map<String, dynamic>? _map(Object? v) => v is Map<String, dynamic> ? v : null;
  static List<Object?> _list(Object? v) => v is List ? v : const [];
  static int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
}
