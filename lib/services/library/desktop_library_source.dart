import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../pathfinder/desktop_data_source.dart';
import 'collection_codec.dart';
import 'library_source.dart';
import 'rootlist_parser.dart';

/// 桌面版会话的媒体库：与官方桌面客户端相同的内部接口。
///
/// - 已点赞歌曲 / 收藏专辑 / 关注艺人：spclient `collection/v2/paging`（protobuf 分页，只含 URI 与时间），
///   再用 Pathfinder `decorateContextTracks`（曲目）/ `getAlbum`（专辑）/ `queryArtistOverview`（艺人）补全详情，
///   补全请求限并发，且只取最新的 N 条（见各 `*Limit`），避免媒体库很大时一次性打出数百请求；
/// - 歌单：spclient `playlist/v2/user/{username}/rootlist`（JSON），缺名称 / 封面的条目再查一次歌单概要；
/// - 写入（点赞 / 收藏 / 关注）：`collection/v2/write`。
class DesktopLibrarySource implements LibrarySource {
  static const String _spclient = SpotifyEndpoints.defaultSpClientBase;

  /// 分页单页条数与最大页数（300 × 10 = 3000 条封顶）。
  static const int _pageSize = 300;
  static const int _maxPages = 10;

  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;
  final DesktopDataSource _data;
  final String Function() _username;
  final bool Function() _signedIn;

  /// 补全详情的条数上限（取最新的 N 条）。
  final int trackLimit;
  final int albumLimit;
  final int artistLimit;
  final int playlistLimit;

  DesktopLibrarySource({
    required this._client,
    required this._headers,
    required this._data,
    required this._username,
    required this._signedIn,
    this.trackLimit = 500,
    this.albumLimit = 100,
    this.artistLimit = 60,
    this.playlistLimit = 300,
  });

  @override
  bool get isSignedIn => _signedIn() && _username().isNotEmpty;

  @override
  String get accountId => _username();

  // ---------------------------------------------------------------------------
  // 读取
  // ---------------------------------------------------------------------------

  @override
  Future<List<SpotifyTrack>> fetchLikedTracks() async {
    if (!isSignedIn) return const [];
    final entries = await _collection(CollectionCodec.setCollection, 'track');
    final kept = entries.take(trackLimit).toList();
    // 必须完整：缺批次的列表会覆盖缓存，播放时到这一截末尾就回绕到歌单开头。
    // 失败时抛出，媒体库保留上次的缓存并记下错误。
    final tracks = await _data.tracksByUris([for (final e in kept) e.uri], complete: true);
    // 收藏条目的 added_at 是秒；补全后的曲目按 id 对回去
    final addedAt = {
      for (final e in kept)
        if (e.addedAt > 0) e.id: DateTime.fromMillisecondsSinceEpoch(e.addedAt * 1000),
    };
    return [for (final t in tracks) t.copyWith(addedAt: addedAt[t.id])];
  }

  @override
  Future<List<SpotifyAlbum>> fetchAlbums() async {
    if (!isSignedIn) return const [];
    final entries = (await _collection(CollectionCodec.setCollection, 'album')).take(albumLimit).toList();
    final albums = await _pooled(entries, 4, (e) async => (await _data.albumPage(e.id))?.album);
    return albums.whereType<SpotifyAlbum>().toList();
  }

  @override
  Future<List<SpotifyArtist>> fetchArtists() async {
    if (!isSignedIn) return const [];
    final entries = (await _collection(CollectionCodec.setArtist, 'artist')).take(artistLimit).toList();
    final artists = await _pooled(entries, 3, (e) async => (await _data.artistPage(e.id))?.artist);
    return artists.whereType<SpotifyArtist>().toList();
  }

  @override
  Future<List<SpotifyPlaylist>> fetchPlaylists() async {
    if (!isSignedIn) return const [];
    final user = _username();
    final res = await _client.get(
      Uri.parse('$_spclient/playlist/v2/user/${Uri.encodeComponent(user)}/rootlist'
          '?decorate=revision,attributes,length,owner&from=0&length=$playlistLimit'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) throw LibrarySourceException('读取歌单失败', res.statusCode);

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      throw LibrarySourceException('歌单数据格式异常：$e');
    }
    final playlists = RootlistParser.parse(json);

    // rootlist 未带元数据（名称为空）的条目补查概要；仍无封面（未设置封面的自建歌单）
    // 用前几首曲目的专辑封面拼四宫格。任一步失败都保留原条目，UI 显示「未命名」/ 占位图标
    return _pooled(playlists, 4, (p) async {
      var result = p;
      try {
        if (result.name.isEmpty) result = await _data.playlistSummary(p.id) ?? result;
        if (result.images.isEmpty) {
          final cover = await _data.playlistMosaic(p.id);
          if (cover.isNotEmpty) result = result.copyWith(images: cover);
        }
      } catch (_) {
        // 封面 / 名称只是装饰，失败不影响歌单列表
      }
      return result;
    });
  }

  /// 分页读取集合 [set]，只保留 [kind] 类型条目，按加入时间从新到旧排序。
  Future<List<CollectionEntry>> _collection(String set, String kind) async {
    final user = _username();
    final all = <CollectionEntry>[];
    var token = '';
    for (var page = 0; page < _maxPages; page++) {
      final res = await _client.post(
        Uri.parse('$_spclient/collection/v2/paging'),
        headers: {
          ...await _headers(),
          'Content-Type': CollectionCodec.contentType,
          'Accept': CollectionCodec.contentType,
        },
        body: CollectionCodec.encodePageRequest(username: user, set: set, token: token, limit: _pageSize),
      );
      if (res.statusCode != 200) throw LibrarySourceException('读取收藏失败', res.statusCode);
      final parsed = CollectionCodec.decodePage(res.bodyBytes);
      all.addAll(parsed.items.where((e) => e.kind == kind));
      if (parsed.nextToken.isEmpty || parsed.items.isEmpty) break;
      token = parsed.nextToken;
    }
    // Dart 的 sort 不稳定：用原始下标兜底，加入时间相同（或缺失）时保持服务端顺序
    final indexed = [for (var i = 0; i < all.length; i++) (i, all[i])];
    indexed.sort((a, b) {
      final byTime = b.$2.addedAt.compareTo(a.$2.addedAt);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  @override
  Future<void> setTrackLiked(SpotifyTrack track, bool liked) =>
      _write(CollectionCodec.setCollection, _uri(track.uri, 'track', track.id), liked);

  @override
  Future<void> setAlbumSaved(SpotifyAlbum album, bool saved) =>
      _write(CollectionCodec.setCollection, _uri(album.uri, 'album', album.id), saved);

  @override
  Future<void> setArtistFollowed(SpotifyArtist artist, bool followed) =>
      _write(CollectionCodec.setArtist, _uri(artist.uri, 'artist', artist.id), followed);

  Future<void> _write(String set, String uri, bool added) async {
    if (!isSignedIn) throw const LibrarySourceException('未登录，无法同步到 Spotify 账号');
    final res = await _client.post(
      Uri.parse('$_spclient/collection/v2/write'),
      headers: {
        ...await _headers(),
        'Content-Type': CollectionCodec.contentType,
        'Accept': CollectionCodec.contentType,
      },
      body: CollectionCodec.encodeWriteRequest(
        username: _username(),
        set: set,
        uri: uri,
        added: added,
        now: DateTime.now(),
        clientUpdateId: _clientUpdateId(),
      ),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw LibrarySourceException('同步收藏失败', res.statusCode);
    }
  }

  /// 实体缺 uri 时由 id 拼出。
  static String _uri(String uri, String kind, String id) => uri.isNotEmpty ? uri : 'spotify:$kind:$id';

  static String _clientUpdateId() {
    final rnd = Random.secure();
    return [for (var i = 0; i < 8; i++) rnd.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// 限并发地对 [items] 逐项执行 [fn]，保持输入顺序；抛错的单项被丢弃（其余照常返回）。
  ///
  /// [fn] 返回可空类型时，返回 null 的项会保留为 null，调用方自行 `whereType` 过滤。
  static Future<List<R>> _pooled<T, R>(List<T> items, int concurrency, Future<R> Function(T item) fn) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        final index = next++;
        try {
          results[index] = await fn(items[index]);
        } catch (_) {
          // 单项失败不影响其他项
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency && i < items.length; i++) worker()]);
    return results.whereType<R>().toList();
  }
}
