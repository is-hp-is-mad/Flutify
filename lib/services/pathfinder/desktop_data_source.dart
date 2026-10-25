import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../core/utils/json_bytes.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/category.dart';
import '../../models/catalog_page.dart';
import '../../models/home_feed.dart';
import '../../models/image.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../models/track_credits.dart';
import '../library/playlist_cover.dart';
import 'credits_parser.dart';
import 'home_parser.dart';
import 'pathfinder_client.dart';
import 'pathfinder_operations.dart';
import 'pathfinder_parsers.dart';

/// 桌面版会话的数据来源：与官方桌面客户端相同的内部接口。
///
/// 桌面版 client_id 被众多第三方客户端共用，公开 Web API（api.spotify.com）长期处于 429 限流；
/// 这里改走 Pathfinder GraphQL 与 spclient，与官方桌面版的请求路径一致。
/// 专辑页 / 艺人页会先后请求"信息"与"曲目"，同一实体的查询在 [_cacheTtl] 内复用，避免重复请求。
class DesktopDataSource {
  static const Duration _cacheTtl = Duration(minutes: 5);

  /// decorateContextTracks 单次补全的曲目数。
  static const int _decorateBatch = 50;

  /// 歌单详情每页请求的条目数。
  static const int _playlistLimit = 100;

  /// 拼四宫格封面时抽取的曲目数。
  static const int _mosaicSampleSize = 12;

  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;
  /// 将服务端本地化响应按当前请求语言隔离缓存。
  final String Function()? language;
  final PathfinderClient _pathfinder;
  final Map<String, _CacheEntry> _cache = {};

  /// 曲目补全批次失败后的重试间隔（第 n 次重试等 n 倍）。
  final Duration retryDelay;

  DesktopDataSource(
    this._client, {
    required Future<Map<String, String>> Function() headers,
    this.language,
    this.retryDelay = const Duration(milliseconds: 600),
  }) : _headers = headers,
       _pathfinder = PathfinderClient(_client, headers: headers);

  /// 相同查询在有效期内合并为一次请求（含进行中的请求）。
  Future<Map<String, dynamic>> _query(
    PathfinderOperation op,
    Map<String, Object?> variables,
  ) {
    final key = _queryKey(op, variables);
    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt))
      return cached.future;
    final future = _pathfinder.query(op, variables);
    _cache[key] = _CacheEntry(future, DateTime.now().add(_cacheTtl));
    // 失败的请求不缓存
    future.catchError((Object _) {
      _cache.remove(key);
      return const <String, dynamic>{};
    });
    if (_cache.length > 64) _cache.remove(_cache.keys.first);
    return future;
  }

  String _queryKey(PathfinderOperation op, Map<String, Object?> variables) =>
      '${language?.call() ?? ''}:${op.name}:${jsonEncode(variables)}';

  /// A transport-successful but malformed page must not poison retries for the
  /// cache TTL. Only parsed catalog pages are reusable as successful results.
  Future<T> _catalogQuery<T>(
    PathfinderOperation op,
    Map<String, Object?> variables,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final key = _queryKey(op, variables);
    try {
      return parse(await _query(op, variables));
    } catch (_) {
      _cache.remove(key);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // 主页 / 浏览
  // ---------------------------------------------------------------------------

  /// 主页每个分区默认带回的条目数（与官方桌面端一致）。
  static const int homeItemsLimit = 10;

  /// 「显示全部」时每个分区带回的条目数。
  static const int homeSectionItemsLimit = 50;

  /// 主页（与官方桌面端同一查询）。[facet] 为筛选标签 id（空 = 全部）。
  Future<HomeFeed> home({String facet = ''}) async =>
      HomeParser.parse(await _homeQuery(facet, homeItemsLimit));

  /// 「显示全部」：同一查询放大每分区条目数，再按 URI 找回该分区。
  Future<HomeSection?> homeSection(String uri, {String facet = ''}) async =>
      HomeParser.section(await _homeQuery(facet, homeSectionItemsLimit), uri);

  Future<Map<String, dynamic>> _homeQuery(String facet, int itemsLimit) =>
      // 主页刷新必须重新联网；并发刷新由 SpotifyProvider 合并。
      _pathfinder.query(PathfinderOperation.home, {
        'homeEndUserIntegration': kDesktopEndUserIntegration,
        'timeZone': _ianaTimeZone(),
        'sp_t': '',
        'facet': facet,
        'sectionItemsLimit': itemsLimit,
        'includeEpisodeContentRatingsV2': false,
      });

  Future<List<SpotifyCategory>> categories() async {
    final data = await _query(PathfinderOperation.browseAll, {
      'pagePagination': {'offset': 0, 'limit': 10},
      'sectionPagination': {'offset': 0, 'limit': 99},
      'browseEndUserIntegration': kDesktopEndUserIntegration,
    });
    return PathfinderParsers.categories(data);
  }

  /// 分类页（browsePage）：[uri] 为 browseAll 返回的分类 URI（`spotify:page:…`）。
  /// 返回全部分区与分区条目（条目与 home 同构，界面复用同一套卡片）。
  Future<List<HomeSection>> browsePage(String uri) async {
    final data = await _query(PathfinderOperation.browsePage, {
      'uri': uri,
      'pagePagination': {'offset': 0, 'limit': 20},
      'sectionPagination': {'offset': 0, 'limit': 20},
      'browseEndUserIntegration': kDesktopEndUserIntegration,
    });
    return HomeParser.browseSections(data);
  }

  // ---------------------------------------------------------------------------
  // 专辑 / 艺人
  // ---------------------------------------------------------------------------

  Future<({SpotifyAlbum album, List<SpotifyTrack> tracks})?> albumPage(
    String id,
  ) async {
    final data = await _query(PathfinderOperation.getAlbum, {
      'uri': 'spotify:album:$id',
      'locale': '',
      'offset': 0,
      'limit': 50,
    });
    return PathfinderParsers.albumPage(data);
  }

  Future<CatalogPage<SpotifyTrack>> albumTracksPage(
    String id, {
    int offset = 0,
    int limit = 50,
  }) async {
    _validatePage(offset, limit);
    return _catalogQuery(
      PathfinderOperation.getAlbum,
      {
        'uri': 'spotify:album:$id',
        'locale': '',
        'offset': offset,
        'limit': limit,
      },
      (data) => PathfinderParsers.albumTracksPage(data, offset: offset, limit: limit),
    );
  }

  Future<({SpotifyArtist artist, List<SpotifyTrack> topTracks})?> artistPage(
    String id,
  ) async {
    final data = await _query(PathfinderOperation.queryArtistOverview, {
      'uri': 'spotify:artist:$id',
      'locale': '',
      'preReleaseV2': false,
    });
    return PathfinderParsers.artistPage(data);
  }

  Future<List<SpotifyAlbum>> artistAlbums(String id) async {
    return (await artistAlbumsPage(id)).items;
  }

  Future<CatalogPage<SpotifyAlbum>> artistAlbumsPage(
    String id, {
    int offset = 0,
    int limit = 20,
  }) async {
    _validatePage(offset, limit);
    // 唱片目录条目不带艺人信息：复用艺人页查询（通常已缓存）回填艺人名
    SpotifyArtist? artist;
    try {
      artist = (await artistPage(id))?.artist;
    } catch (_) {}
    return _catalogQuery(
      PathfinderOperation.queryArtistDiscographyAll,
      {
        'uri': 'spotify:artist:$id',
        'offset': offset,
        'limit': limit,
        'order': 'DATE_DESC',
      },
      (data) => PathfinderParsers.discographyPage(
        data,
        artist: artist,
        offset: offset,
        limit: limit,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 搜索
  // ---------------------------------------------------------------------------

  Future<
    ({
      List<SpotifyTrack> tracks,
      List<SpotifyArtist> artists,
      List<SpotifyPlaylist> playlists,
    })
  >
  search(String term) async {
    final page = await searchPage(term, limit: 10);
    return (
      tracks: page.tracks.items,
      artists: page.artists.items,
      playlists: page.playlists.items,
    );
  }

  Future<SearchPage> searchPage(
    String term, {
    int offset = 0,
    int limit = 20,
  }) async {
    _validatePage(offset, limit);
    final data = await _pathfinder.query(PathfinderOperation.searchDesktop, {
      'searchTerm': term,
      'offset': offset,
      'limit': limit,
      'numberOfTopResults': 5,
      'includeAudiobooks': false,
      'includeArtistHasConcertsField': false,
      'includePreReleases': false,
      'includeLocalConcertsField': false,
      'includeAuthors': false,
    });
    return PathfinderParsers.searchPage(data, offset: offset, limit: limit);
  }

  static void _validatePage(int offset, int limit) {
    if (offset < 0 || limit < 1 || limit > 50) {
      throw ArgumentError('Catalog offset must be non-negative and limit 1–50');
    }
  }

  // ---------------------------------------------------------------------------
  // 歌单：spclient playlist/v2 取元数据与曲目 URI → decorateContextTracks 批量补全
  // ---------------------------------------------------------------------------

  Future<SpotifyPlaylist?> playlist(String id) async {
    final res = await _client.get(
      Uri.parse(
        '${SpotifyEndpoints.defaultSpClientBase}/playlist/v2/playlist/$id'
        '?decorate=attributes,length,owner&from=0&length=$_playlistLimit',
      ),
      headers: await _headers(),
    );
    if (res.statusCode != 200) return null;
    // 大歌单每页可达数百 KB：解码放到后台 Isolate（见 decodeJsonBytes）
    final data = await decodeJsonBytes(res.bodyBytes) as Map<String, dynamic>;
    final parsed = PathfinderParsers.playlistV2(id, data);
    if (parsed == null) return null;

    final allUris = [...parsed.trackUris];
    final addedAt = {...parsed.addedAt};
    // 用原始条目数推进 offset：下架歌曲/播客可能被解析器过滤，不能用 trackUris.length。
    var offset = ((data['contents'] as Map?)?['items'] as List?)?.length ?? 0;
    while (offset < parsed.playlist.totalTracks) {
      if (offset == 0)
        throw StateError('Playlist returned an empty page before its end');
      final pageResponse = await _client.get(
        Uri.parse(
          '${SpotifyEndpoints.defaultSpClientBase}/playlist/v2/playlist/$id'
          '?decorate=attributes,length,owner&from=$offset&length=$_playlistLimit',
        ),
        headers: await _headers(),
      );
      if (pageResponse.statusCode != 200)
        throw StateError('Playlist page failed: ${pageResponse.statusCode}');
      final page =
          await decodeJsonBytes(pageResponse.bodyBytes)
              as Map<String, dynamic>;
      final items = ((page['contents'] as Map?)?['items'] as List?) ?? const [];
      if (items.isEmpty)
        throw StateError('Playlist returned an empty page before its end');
      // 后续页可能不重复元数据，仍沿用第一页的歌单属性。
      final next = PathfinderParsers.playlistV2(id, {
        ...data,
        ...page,
        'attributes': data['attributes'],
      });
      if (next == null) throw StateError('Invalid playlist page');
      allUris.addAll(next.trackUris);
      for (final entry in next.addedAt.entries) {
        addedAt.putIfAbsent(entry.key, () => entry.value);
      }
      offset += items.length;
    }

    final batches = <Future<List<SpotifyTrack>>>[];
    for (var i = 0; i < allUris.length; i += _decorateBatch) {
      final uris = allUris.sublist(
        i,
        (i + _decorateBatch).clamp(0, allUris.length),
      );
      batches.add(
        _pathfinder
            .query(PathfinderOperation.decorateContextTracks, {'uris': uris})
            .then(PathfinderParsers.decoratedTracks),
      );
    }
    final byUri = {
      for (final t in (await Future.wait(batches)).expand((t) => t)) t.uri: t,
    };
    final tracks = [
      for (final uri in allUris)
        if (byUri[uri] case final track?) track.copyWith(addedAt: addedAt[uri]),
    ];

    // 歌单无自定义封面时，与官方客户端一样用前几首曲目的专辑封面拼四宫格
    final playlist = parsed.playlist;
    final images = playlist.images.isEmpty
        ? PlaylistCover.fromAlbumCovers(_albumCovers(tracks))
        : null;
    return playlist.copyWith(tracks: tracks, images: images);
  }

  /// 无封面歌单（媒体库列表用）：只取前几首曲目的专辑封面拼四宫格，不加载整张歌单。
  ///
  /// 多取几首：前几首可能来自同一张专辑，凑不满 4 张不同封面。
  Future<List<SpotifyImage>> playlistMosaic(String id) async {
    final res = await _client.get(
      Uri.parse(
        '${SpotifyEndpoints.defaultSpClientBase}/playlist/v2/playlist/$id'
        '?decorate=attributes&from=0&length=$_mosaicSampleSize',
      ),
      headers: await _headers(),
    );
    if (res.statusCode != 200) return const [];
    final parsed = PathfinderParsers.playlistV2(
      id,
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
    );
    if (parsed == null || parsed.trackUris.isEmpty)
      return parsed?.playlist.images ?? const [];
    if (parsed.playlist.images.isNotEmpty) return parsed.playlist.images;
    final data = await _pathfinder.query(
      PathfinderOperation.decorateContextTracks,
      {'uris': parsed.trackUris},
    );
    return PlaylistCover.fromAlbumCovers(
      _albumCovers(PathfinderParsers.decoratedTracks(data)),
    );
  }

  static Iterable<List<SpotifyImage>> _albumCovers(List<SpotifyTrack> tracks) =>
      tracks.map((t) => t.album?.images ?? const <SpotifyImage>[]);

  /// 按 URI 批量补全曲目（decorateContextTracks，每批 [_decorateBatch] 首、最多 [concurrency] 批并行）。
  ///
  /// 返回顺序与 [uris] 一致；服务端未返回（下架 / 无权限）的曲目被略过。
  ///
  /// 失败的批次会退避重试 [retries] 次；[complete] 为 true 时仍有批次失败就抛出，
  /// 不返回缺了一截的列表（媒体库会把结果写进缓存并当作完整歌单播放）。
  Future<List<SpotifyTrack>> tracksByUris(
    List<String> uris, {
    int concurrency = 3,
    int retries = 2,
    bool complete = false,
  }) async {
    final batches = <List<String>>[
      for (var i = 0; i < uris.length; i += _decorateBatch)
        uris.sublist(i, (i + _decorateBatch).clamp(0, uris.length)),
    ];
    final results = List<List<SpotifyTrack>>.filled(batches.length, const []);
    var next = 0;
    Object? lastError;
    var failed = 0;
    Future<void> worker() async {
      while (next < batches.length) {
        final index = next++;
        for (var attempt = 0; ; attempt++) {
          try {
            final data = await _pathfinder.query(
              PathfinderOperation.decorateContextTracks,
              {'uris': batches[index]},
            );
            results[index] = PathfinderParsers.decoratedTracks(data);
            break;
          } catch (e) {
            if (attempt < retries) {
              await Future<void>.delayed(retryDelay * (attempt + 1));
              continue;
            }
            // 单批失败不拖垮整个列表
            debugPrint('[tracks] 第 ${index + 1}/${batches.length} 批曲目补全失败：$e');
            lastError = e;
            failed++;
            break;
          }
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < batches.length; i++) worker(),
    ]);
    // 全部批次都失败说明是网络 / 鉴权问题而非个别曲目缺失：抛出，避免调用方把它当成「空列表」
    if (batches.isNotEmpty && (failed == batches.length || (complete && failed > 0))) {
      throw lastError!;
    }
    final byId = {for (final t in results.expand((r) => r)) t.id: t};
    return [for (final uri in uris) ?byId[PathfinderParsers.idFromUri(uri)]];
  }

  /// 歌单概要（名称、封面、曲目数，不含曲目）：rootlist 缺元数据时补全。
  Future<SpotifyPlaylist?> playlistSummary(String id) async {
    final res = await _client.get(
      Uri.parse(
        '${SpotifyEndpoints.defaultSpClientBase}/playlist/v2/playlist/$id'
        '?decorate=attributes,length,owner&from=0&length=0',
      ),
      headers: await _headers(),
    );
    if (res.statusCode != 200) return null;
    return PathfinderParsers.playlistV2(
      id,
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
    )?.playlist;
  }

  // ---------------------------------------------------------------------------
  // 曲目：制作人员 / 歌曲电台
  // ---------------------------------------------------------------------------

  /// 「查看制作人员」（与官方桌面端同一查询）；曲目不存在时返回 null。
  Future<TrackCredits?> trackCredits(String trackId) async {
    final data =
        await _query(PathfinderOperation.queryTrackCreditsGroupedModal, {
          'trackUri': 'spotify:track:$trackId',
          'contributorsLimit': 100,
          'contributorsOffset': 0,
        });
    return CreditsParser.parse(data);
  }

  /// 「转至歌曲电台」：以曲目为种子取电台歌单 id（spclient inspiredby-mix，官方桌面端同一接口）。
  /// 服务端没有为该曲目生成电台时返回 null。
  Future<String?> songRadioPlaylistId(String trackId) async {
    final res = await _client.get(
      Uri.parse(
        '${SpotifyEndpoints.defaultSpClientBase}/inspiredby-mix/v2/seed_to_playlist/'
        'spotify:track:$trackId?response-format=json',
      ),
      headers: await _headers(),
    );
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200)
      throw http.ClientException(
        'seed_to_playlist HTTP ${res.statusCode}',
        res.request?.url,
      );
    final items =
        (jsonDecode(utf8.decode(res.bodyBytes))
            as Map<String, dynamic>)['mediaItems'];
    if (items is! List) return null;
    for (final item in items.whereType<Map>()) {
      final uri = item['uri'] as String? ?? '';
      if (uri.startsWith('spotify:playlist:'))
        return uri.substring('spotify:playlist:'.length);
    }
    return null;
  }

  /// home 查询需要 IANA 时区名；Dart 只能拿到 UTC 偏移，整点偏移用 `Etc/GMT∓N` 表示（符号与习惯相反）。
  static String _ianaTimeZone() {
    final offset = DateTime.now().timeZoneOffset;
    if (offset.inMinutes % 60 != 0 || offset == Duration.zero) return 'UTC';
    final hours = offset.inHours;
    return 'Etc/GMT${hours > 0 ? '-' : '+'}${hours.abs()}';
  }
}

class _CacheEntry {
  final Future<Map<String, dynamic>> future;
  final DateTime expiresAt;
  const _CacheEntry(this.future, this.expiresAt);
}
