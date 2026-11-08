import 'package:flutter/material.dart';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/category.dart';
import '../../models/catalog_page.dart';
import '../../models/image.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../library/playlist_cover.dart';

/// 把桌面端内部接口（Pathfinder GraphQL / spclient playlist v2）的响应转换为 App 数据模型。
///
/// 响应结构由服务端查询文档决定、可能随版本变化，因此所有字段都按"可缺失"宽松读取，
/// 单个条目解析失败只跳过该条目。
class PathfinderParsers {
  PathfinderParsers._();

  // ---------------------------------------------------------------------------
  // 通用
  // ---------------------------------------------------------------------------

  /// `spotify:track:xxx` → `xxx`。
  static String idFromUri(String uri) => uri.isEmpty ? '' : uri.substring(uri.lastIndexOf(':') + 1);

  /// 图片 sources：[{url, width|maxWidth, height|maxHeight}]，按宽度从大到小排列（模型取第一张作封面）。
  static List<SpotifyImage> images(Object? sources) {
    final list = <SpotifyImage>[];
    for (final s in _list(sources)) {
      final m = _map(s);
      final url = m?['url'];
      if (url is! String || url.isEmpty) continue;
      list.add(SpotifyImage(
        url: url,
        width: _int(m!['width']) ?? _int(m['maxWidth']),
        height: _int(m['height']) ?? _int(m['maxHeight']),
      ));
    }
    list.sort((a, b) => (b.width ?? 0).compareTo(a.width ?? 0));
    return list;
  }

  /// 解开 `{__typename: XxxResponseWrapper | XxxWrapper, data: {...}}` 包装；非包装对象原样返回。
  static Map<String, dynamic>? unwrap(Object? value) {
    final m = _map(value);
    if (m == null) return null;
    final typename = m['__typename'];
    if (typename is String && typename.endsWith('Wrapper')) return _map(m['data']);
    return m;
  }

  // ---------------------------------------------------------------------------
  // 实体
  // ---------------------------------------------------------------------------

  /// Artist（精简：profile.name + uri，可带 visuals.avatarImage 与 stats）。
  static SpotifyArtist? artist(Object? value) {
    final m = unwrap(value);
    final uri = m?['uri'];
    if (m == null || uri is! String) return null;
    final profile = _map(m['profile']);
    return SpotifyArtist(
      id: m['id'] as String? ?? idFromUri(uri),
      name: profile?['name'] as String? ?? '',
      uri: uri,
      images: images(_map(_map(m['visuals'])?['avatarImage'])?['sources']),
      followers: _int(_map(m['stats'])?['followers']),
    );
  }

  static List<SpotifyArtist> _artists(Object? page) =>
      _list(_map(page)?['items']).map(artist).whereType<SpotifyArtist>().toList();

  /// Track（decorateContextTracks / 搜索 / 专辑曲目 / 艺人热门曲目共用）。
  /// [album] 用于专辑页：专辑曲目响应不带 albumOfTrack，由调用方回填。
  static SpotifyTrack? track(Object? value, {SpotifyAlbum? album}) {
    final m = unwrap(value);
    final uri = m?['uri'];
    if (m == null || uri is! String || !uri.startsWith('spotify:track:')) return null;
    final albumOfTrack = _map(m['albumOfTrack']);
    return SpotifyTrack(
      id: m['id'] as String? ?? idFromUri(uri),
      name: m['name'] as String? ?? '',
      uri: uri,
      artists: _artists(m['artists']),
      album: album ?? (albumOfTrack == null ? null : _albumRef(albumOfTrack)),
      durationMs: _int(_map(m['duration'])?['totalMilliseconds']) ?? 0,
      explicit: _map(m['contentRating'])?['label'] == 'EXPLICIT',
      isPlayable: _map(m['playability'])?['playable'] as bool? ?? true,
    );
  }

  /// 曲目列表中的 `{track: {...}}` / `{item: {...}}` / 直接的 Track。
  static SpotifyTrack? trackItem(Object? item, {SpotifyAlbum? album}) {
    final m = _map(item);
    if (m == null) return null;
    return track(m['track'] ?? m['item'] ?? m, album: album);
  }

  /// 曲目所属专辑的引用（只有名称、封面）。
  static SpotifyAlbum _albumRef(Map<String, dynamic> m) {
    final uri = m['uri'] as String? ?? '';
    return SpotifyAlbum(
      id: m['id'] as String? ?? idFromUri(uri),
      name: m['name'] as String? ?? '',
      uri: uri,
      images: images(_map(m['coverArt'])?['sources']),
      artists: _artists(m['artists']),
    );
  }

  /// Album（getAlbum 的 albumUnion、搜索结果、唱片目录的 release 共用）。
  static SpotifyAlbum? album(Object? value, {List<SpotifyArtist>? fallbackArtists}) {
    final m = unwrap(value);
    final uri = m?['uri'];
    if (m == null || uri is! String || !uri.startsWith('spotify:album:')) return null;
    final date = _map(m['date']);
    final iso = date?['isoString'] as String?;
    final artists = _artists(m['artists']);
    return SpotifyAlbum(
      id: m['id'] as String? ?? idFromUri(uri),
      name: m['name'] as String? ?? '',
      uri: uri,
      albumType: (m['type'] as String? ?? 'album').toLowerCase(),
      releaseDate: iso != null && iso.length >= 10 ? iso.substring(0, 10) : '${date?['year'] ?? ''}',
      totalTracks: _int(_map(m['tracksV2'])?['totalCount']) ?? _int(_map(m['tracks'])?['totalCount']) ?? 0,
      images: images(_map(m['coverArt'])?['sources']),
      artists: artists.isEmpty ? (fallbackArtists ?? const []) : artists,
    );
  }

  /// Playlist（home 卡片、搜索结果）。
  static SpotifyPlaylist? playlist(Object? value) {
    final m = unwrap(value);
    final uri = m?['uri'];
    if (m == null || uri is! String || !uri.startsWith('spotify:playlist:')) return null;
    final imageItems = _list(_map(m['images'])?['items']);
    final owner = unwrap(m['ownerV2']);
    return SpotifyPlaylist(
      id: idFromUri(uri),
      name: m['name'] as String? ?? '',
      uri: uri,
      description: stripHtml(m['description'] as String? ?? ''),
      ownerName: owner?['name'] as String? ?? 'Spotify',
      images: imageItems.isEmpty ? const [] : images(_map(imageItems.first)?['sources']),
      totalTracks: _int(_map(m['content'])?['totalCount']) ?? 0,
    );
  }

  // ---------------------------------------------------------------------------
  // 页面
  // ---------------------------------------------------------------------------

  /// browseAll：分类卡片（标题、封面、底色）。id 为 `spotify:page:*`。
  static List<SpotifyCategory> categories(Map<String, dynamic> data) {
    final result = <SpotifyCategory>[];
    for (final section in _list(_map(_map(data['browseStart'])?['sections'])?['items'])) {
      for (final item in _list(_map(_map(section)?['sectionItems'])?['items'])) {
        final m = _map(item);
        final card = _map(_map(unwrap(m?['content']))?['data'])?['cardRepresentation'];
        final cardMap = _map(card);
        if (m == null || cardMap == null) continue;
        final artwork = images(_map(cardMap['artwork'])?['sources']);
        result.add(SpotifyCategory(
          id: m['uri'] as String? ?? '',
          name: _map(cardMap['title'])?['transformedLabel'] as String? ?? '',
          iconUrl: artwork.isEmpty ? '' : artwork.first.url,
          color: hexColor(_map(cardMap['backgroundColor'])?['hex'] as String?) ?? const Color(0xFF1DB954),
        ));
      }
    }
    return result;
  }

  /// searchDesktop：曲目、艺人、歌单。
  static ({List<SpotifyTrack> tracks, List<SpotifyArtist> artists, List<SpotifyPlaylist> playlists}) search(
    Map<String, dynamic> data,
  ) {
    final s = _map(data['searchV2']);
    return (
      tracks: _list(_map(s?['tracksV2'])?['items']).map((i) => trackItem(i)).whereType<SpotifyTrack>().toList(),
      artists: _list(_map(s?['artists'])?['items']).map(artist).whereType<SpotifyArtist>().toList(),
      playlists: _list(_map(s?['playlists'])?['items']).map(playlist).whereType<SpotifyPlaylist>().toList(),
    );
  }

  /// Paginated counterpart to the legacy preview parser. A missing collection
  /// is a protocol error, not a successful empty/end-of-list response.
  static SearchPage searchPage(
    Map<String, dynamic> data, {
    int offset = 0,
    int limit = 20,
  }) {
    final search = _map(data['searchV2']);
    if (search == null) throw const FormatException('Missing search results');
    return SearchPage(
      tracks: _catalogPage(
        search['tracksV2'], (item) => trackItem(item), offset: offset, limit: limit,
      ),
      artists: _catalogPage(
        search['artists'], artist, offset: offset, limit: limit,
      ),
      playlists: _catalogPage(
        search['playlists'], playlist, offset: offset, limit: limit,
      ),
    );
  }

  static CatalogPage<T> _catalogPage<T>(
    Object? value,
    T? Function(Object?) parse, {
    required int offset,
    required int limit,
  }) {
    final page = _map(value);
    if (page == null || page['items'] is! List) {
      throw const FormatException('Missing catalog items');
    }
    final rawItems = _list(page['items']);
    final paging = _map(page['pagingInfo']) ?? _map(page['pageInfo']);
    final total = _int(page['totalCount']);
    final next = _int(paging?['nextOffset']);
    if (total != null && total < 0 || next != null && next < 0) {
      throw const FormatException('Invalid catalog pagination');
    }
    return CatalogPage<T>.fromSlice(
      items: rawItems.map(parse).whereType<T>().toList(),
      offset: offset,
      limit: limit,
      rawCount: rawItems.length,
      total: total,
      nextOffset: next,
      hasNextPage: paging?['hasNextPage'] is bool
          ? paging!['hasNextPage'] as bool
          : null,
    );
  }

  /// getAlbum：专辑信息与曲目（曲目回填专辑，保证封面可用）。
  static ({SpotifyAlbum album, List<SpotifyTrack> tracks})? albumPage(Map<String, dynamic> data) {
    final union = _map(data['albumUnion']);
    final parsed = album(union);
    if (parsed == null) return null;
    final tracks = _list(_map(union!['tracksV2'])?['items'])
        .map((i) => trackItem(i, album: parsed))
        .whereType<SpotifyTrack>()
        .toList();
    return (album: parsed, tracks: tracks);
  }

  static CatalogPage<SpotifyTrack> albumTracksPage(
    Map<String, dynamic> data, {
    int offset = 0,
    int limit = 50,
  }) {
    final union = _map(data['albumUnion']);
    final parsedAlbum = album(union);
    if (parsedAlbum == null) throw const FormatException('Missing album');
    return _catalogPage(
      union!['tracksV2'],
      (item) => trackItem(item, album: parsedAlbum),
      offset: offset,
      limit: limit,
    );
  }

  /// queryArtistOverview：艺人信息与热门曲目。
  static ({SpotifyArtist artist, List<SpotifyTrack> topTracks})? artistPage(Map<String, dynamic> data) {
    final union = _map(data['artistUnion']);
    final parsed = artist(union);
    if (parsed == null) return null;
    final topTracks = _list(_map(_map(union!['discography'])?['topTracks'])?['items'])
        .map((i) => trackItem(i))
        .whereType<SpotifyTrack>()
        .toList();
    return (artist: parsed, topTracks: topTracks);
  }

  /// queryArtistDiscographyAll：每个条目的 releases 取第一个版本。
  static List<SpotifyAlbum> discography(Map<String, dynamic> data, {SpotifyArtist? artist}) {
    final all = _map(_map(_map(data['artistUnion'])?['discography'])?['all']);
    return _list(all?['items'])
        .map((i) {
          final releases = _list(_map(_map(i)?['releases'])?['items']);
          return releases.isEmpty ? null : album(releases.first, fallbackArtists: artist == null ? null : [artist]);
        })
        .whereType<SpotifyAlbum>()
        .toList();
  }

  static CatalogPage<SpotifyAlbum> discographyPage(
    Map<String, dynamic> data, {
    SpotifyArtist? artist,
    int offset = 0,
    int limit = 20,
  }) {
    final all = _map(_map(_map(data['artistUnion'])?['discography'])?['all']);
    return _catalogPage(
      all,
      (item) {
        final releases = _list(_map(_map(item)?['releases'])?['items']);
        return releases.isEmpty
            ? null
            : album(releases.first, fallbackArtists: artist == null ? null : [artist]);
      },
      offset: offset,
      limit: limit,
    );
  }

  /// spclient `playlist/v2/playlist/{id}`（JSON）：元数据、曲目 URI 列表与各曲目的加入时间。
  ///
  /// 条目 `attributes.timestamp` 为加入时间（毫秒，字符串或数字）；自动生成的歌单（daylist 等）没有。
  static ({SpotifyPlaylist playlist, List<String> trackUris, Map<String, DateTime> addedAt})? playlistV2(
    String id,
    Map<String, dynamic> json,
  ) {
    final attributes = _map(json['attributes']);
    if (attributes == null) return null;
    final owner = json['ownerUsername'] as String? ?? '';
    final uris = <String>[];
    final addedAt = <String, DateTime>{};
    for (final raw in _list(_map(json['contents'])?['items'])) {
      final item = _map(raw);
      final uri = item?['uri'];
      if (uri is! String || !uri.startsWith('spotify:track:')) continue;
      uris.add(uri);
      final time = _timestampMs(_map(item?['attributes'])?['timestamp']);
      // 同一首歌重复出现时保留最早的一次
      if (time != null) addedAt.putIfAbsent(uri, () => time);
    }
    return (
      playlist: SpotifyPlaylist(
        id: id,
        name: attributes['name'] as String? ?? '',
        uri: 'spotify:playlist:$id',
        description: stripHtml(attributes['description'] as String? ?? ''),
        ownerName: owner.isEmpty || owner == 'spotify' ? 'Spotify' : owner,
        images: PlaylistCover.fromAttributes(attributes),
        totalTracks: _int(json['length']) ?? uris.length,
      ),
      trackUris: uris,
      addedAt: addedAt,
    );
  }

  /// 毫秒时间戳（字符串或数字）；不合理的值（≤ 0）视为缺失。
  static DateTime? _timestampMs(Object? value) {
    final ms = switch (value) {
      final int v => v,
      final String v => int.tryParse(v),
      _ => null,
    };
    return ms == null || ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// decorateContextTracks：按 URI 批量补全的曲目。
  static List<SpotifyTrack> decoratedTracks(Map<String, dynamic> data) =>
      _list(data['tracks']).map((t) => track(t)).whereType<SpotifyTrack>().toList();

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// 歌单描述中常带 `<a href=...>` 链接，展示前去掉标签并还原常见实体。
  static String stripHtml(String text) => text
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&#39;', "'")
      .trim();

  /// `#dc148c` → Color。
  static Color? hexColor(String? hex) {
    if (hex == null) return null;
    final clean = hex.replaceFirst('#', '');
    final value = int.tryParse(clean.length == 6 ? 'FF$clean' : clean, radix: 16);
    return value == null ? null : Color(value);
  }

  static Map<String, dynamic>? _map(Object? v) => v is Map<String, dynamic> ? v : null;
  static List<Object?> _list(Object? v) => v is List ? v : const [];
  static int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
}
