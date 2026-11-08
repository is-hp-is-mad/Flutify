import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import 'library_source.dart';

/// 非桌面会话（Login5 / 开发者应用 OAuth）的媒体库：公开 Web API（`/me/tracks`、`/me/albums`、
/// `/me/following`、`/me/playlists`），使用 `next` 游标分页，各类型有条数上限。
class WebApiLibrarySource implements LibrarySource {
  static const int _pageSize = 50;

  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;
  final String Function() _baseUrl;
  final String Function() _username;
  final bool Function() _signedIn;

  /// 每类数据最多读取的页数（50 条/页）。
  final int maxPages;

  WebApiLibrarySource({
    required this._client,
    required this._headers,
    required this._baseUrl,
    required this._username,
    required this._signedIn,
    this.maxPages = 10,
  });

  @override
  bool get isSignedIn => _signedIn();

  @override
  String get accountId => _username();

  // ---------------------------------------------------------------------------
  // 读取
  // ---------------------------------------------------------------------------

  @override
  Future<List<SpotifyTrack>> fetchLikedTracks() async {
    final items = await _pages('/me/tracks?limit=$_pageSize', (json) => json['items']);
    return [
      for (final item in items)
        if (item is Map<String, dynamic> && item['track'] is Map<String, dynamic>)
          SpotifyTrack.fromJson(
            item['track'] as Map<String, dynamic>,
          ).copyWith(addedAt: SpotifyTrack.parseAddedAt(item['added_at'])),
    ];
  }

  @override
  Future<List<SpotifyAlbum>> fetchAlbums() async {
    final items = await _pages('/me/albums?limit=$_pageSize', (json) => json['items']);
    return [
      for (final item in items)
        if (item is Map<String, dynamic> && item['album'] is Map<String, dynamic>)
          SpotifyAlbum.fromJson(item['album'] as Map<String, dynamic>),
    ];
  }

  @override
  Future<List<SpotifyArtist>> fetchArtists() async {
    // 关注艺人响应嵌在 artists 字段下，next 也在其中
    final items = await _pages(
      '/me/following?type=artist&limit=$_pageSize',
      (json) => (json['artists'] as Map<String, dynamic>?)?['items'],
      nextOf: (json) => (json['artists'] as Map<String, dynamic>?)?['next'] as String?,
    );
    return [
      for (final item in items)
        if (item is Map<String, dynamic>) SpotifyArtist.fromJson(item),
    ];
  }

  @override
  Future<List<SpotifyPlaylist>> fetchPlaylists() async {
    final items = await _pages('/me/playlists?limit=$_pageSize', (json) => json['items']);
    return [
      for (final item in items)
        if (item is Map<String, dynamic>) SpotifyPlaylist.fromJson(item),
    ];
  }

  /// 按 `next` 链接顺序读取最多 [maxPages] 页，返回合并后的条目。
  Future<List<Object?>> _pages(
    String firstPath,
    Object? Function(Map<String, dynamic> json) itemsOf, {
    String? Function(Map<String, dynamic> json)? nextOf,
  }) async {
    if (!isSignedIn) return const [];
    final result = <Object?>[];
    String? url = '${_baseUrl()}$firstPath';
    for (var page = 0; url != null && page < maxPages; page++) {
      final res = await _client.get(Uri.parse(url), headers: await _headers());
      if (res.statusCode != 200) throw LibrarySourceException('读取媒体库失败', res.statusCode);
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map<String, dynamic>) break;
      final items = itemsOf(json);
      if (items is List) result.addAll(items);
      url = nextOf != null ? nextOf(json) : json['next'] as String?;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  @override
  Future<void> setTrackLiked(SpotifyTrack track, bool liked) =>
      _send(liked ? 'PUT' : 'DELETE', '/me/tracks', body: {'ids': [track.id]});

  @override
  Future<void> setAlbumSaved(SpotifyAlbum album, bool saved) =>
      _send(saved ? 'PUT' : 'DELETE', '/me/albums', body: {'ids': [album.id]});

  @override
  Future<void> setArtistFollowed(SpotifyArtist artist, bool followed) =>
      _send(followed ? 'PUT' : 'DELETE', '/me/following?type=artist&ids=${artist.id}');

  Future<void> _send(String method, String path, {Map<String, Object?>? body}) async {
    if (!isSignedIn) throw const LibrarySourceException('未登录，无法同步到 Spotify 账号');
    final request = http.Request(method, Uri.parse('${_baseUrl()}$path'))
      ..headers.addAll(await _headers());
    if (body != null) request.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _client.send(request));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw LibrarySourceException('同步收藏失败', res.statusCode);
    }
  }
}
