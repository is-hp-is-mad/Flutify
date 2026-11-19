import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../core/rust_core.dart';
import '../../l10n/app_locale.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../auth/account_profile_service.dart';
import '../auth/client_profile.dart';
import '../auth/web_token_service.dart';
import '../library/collection_codec.dart';
import '../library/rootlist_parser.dart';
import '../pathfinder/pathfinder_client.dart';
import '../pathfinder/pathfinder_operations.dart';
import '../pathfinder/pathfinder_parsers.dart';
import '../protocol/access_point.dart';
import '../../src/rust/api/backup.dart' as rust;
import '../rust_backend_bridge.dart';
import '../spotify_api_service.dart';
import 'backup_models.dart';

/// 读取备份账号唯一识别符（邮箱 / 用户名 ID）、已点赞歌曲与歌单曲目。
///
/// 生产环境由 Rust（`backup_backend`）用备份账号自己的会话完成整个拉取；
/// 注入自定义 http.Client（测试）或需要走自建网关时用下面的 Dart 实现。
class SpDcBackupFetcher {
  static const String _spclient = SpotifyEndpoints.defaultSpClientBase;
  static const int _pageSize = 300;
  static const int _maxPages = 50;
  static const int _playlistLimit = 300;
  static const int _maxPlaylistsWithTracks = 30;

  final http.Client _client;
  final String _baseUrl;
  final SpotifyApiService? _apiService;
  final bool _useRustBackend;

  SpDcBackupFetcher({
    http.Client? client,
    String baseUrl = SpotifyEndpoints.defaultWebApiBase,
    SpotifyApiService? apiService,
    bool? useRustBackend,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl,
       _apiService = apiService,
       _useRustBackend = useRustBackend ?? client == null;

  static const String _missingIdMessage = '无法读取备份账号的唯一识别符，请确认已在 WebView 中完成登录';

  Future<BackupAccountSnapshot> fetchWithSession(
    BackupSessionCredentials session,
  ) async {
    if (_useRustBackend && RustCore.ready) {
      final proxy = await RustBackendBridge.proxyForUrl('$_spclient/');
      if (proxy != null) return _fetchWithRust(session, proxy);
    }
    return _fetchWithDart(session);
  }

  Future<BackupAccountSnapshot> _fetchWithRust(
    BackupSessionCredentials session,
    String proxy,
  ) async {
    final rust.RustBackupSnapshotDto dto;
    try {
      dto = await rust.rustBackupFetchSnapshot(
        request: rust.RustBackupFetchRequest(
          spDc: session.spDc.trim(),
          accessToken: session.accessToken.trim(),
          clientToken: session.clientToken.trim(),
          userId: session.userId.trim(),
          email: session.email.trim(),
          displayName: session.displayName.trim(),
          avatarUrl: session.avatarUrl.trim(),
          spclientBase: _spclient,
          webApiBase: _baseUrl,
          profileAttributesHash: PathfinderOperation.profileAttributes.sha256Hash,
          decorateHash: PathfinderOperation.decorateContextTracks.sha256Hash,
          libraryTracksHash: PathfinderOperation.fetchLibraryTracks.sha256Hash,
          useMainSession: _apiService?.isConfigured ?? false,
          proxy: proxy,
        ),
      );
    } catch (_) {
      // Rust 只在拿不到令牌 / 唯一识别符时失败，与 Dart 实现的报错一致
      throw StateError(_missingIdMessage);
    }
    return BackupAccountSnapshot(
      id: dto.id,
      email: dto.email,
      displayName: dto.displayName,
      avatarUrl: dto.avatarUrl,
      likedTracks: [
        for (final t in dto.likedTracks) RustBackendBridge.trackFromDto(t),
      ],
      playlists: [
        for (final p in dto.playlists) RustBackendBridge.playlistFromDto(p),
      ],
    );
  }

  Future<BackupAccountSnapshot> _fetchWithDart(
    BackupSessionCredentials session,
  ) async {
    var token = session.accessToken.trim();
    final clientToken = session.clientToken.trim();
    var id = session.userId.trim();
    var email = session.email.trim();
    var displayName = session.displayName.trim();
    var avatarUrl = session.avatarUrl.trim();

    // 若后台刷新或旧落盘记录尚未附带页面 token，用已保存的 sp_dc 换取会话 token
    if (token.isEmpty && session.spDc.trim().isNotEmpty) {
      try {
        final minted = await WebTokenService.mintTokenForSpDc(
          session.spDc.trim(),
          client: _client,
        );
        token = minted.token;
      } catch (_) {}
    }

    Map<String, String> buildHeaders(String bearer) => <String, String>{
      if (bearer.isNotEmpty) 'Authorization': 'Bearer $bearer',
      if (clientToken.isNotEmpty) 'client-token': clientToken,
      'Accept': 'application/json',
      'Accept-Language': AppLocale.spotifyLanguage,
      'User-Agent': SpotifyClientProfile.web.userAgent,
      ...SpotifyClientProfile.web.headers,
    };

    var headers = buildHeaders(token);

    // 1. 读取唯一识别符（邮箱 email + 唯一用户名 id）：优先 Pathfinder profileAttributes，其次 /v1/me，最后 APWelcome
    if (token.isNotEmpty &&
        (id.isEmpty || displayName.isEmpty || avatarUrl.isEmpty)) {
      final webProfile = await AccountProfileService(_client)
          .fetchProfileAttributes(accessToken: token, clientToken: clientToken);
      if (webProfile != null) {
        if (id.isEmpty && webProfile.id.isNotEmpty) id = webProfile.id;
        if (displayName.isEmpty && webProfile.displayName.isNotEmpty) {
          displayName = webProfile.displayName;
        }
        if (avatarUrl.isEmpty && webProfile.avatarUrl.isNotEmpty) {
          avatarUrl = webProfile.avatarUrl;
        }
      }
    }

    if (token.isNotEmpty && (id.isEmpty || email.isEmpty)) {
      try {
        final me = await _getJson('$_baseUrl/me', headers);
        final meId = (me['id'] as String? ?? '').trim();
        final meEmail = (me['email'] as String? ?? '').trim();
        final meName = (me['display_name'] as String? ?? '').trim();
        if (meId.isNotEmpty) id = meId;
        if (meEmail.isNotEmpty) email = meEmail;
        if (meName.isNotEmpty && displayName.isEmpty) displayName = meName;
        final images = me['images'];
        if (avatarUrl.isEmpty &&
            images is List &&
            images.isNotEmpty &&
            images.first is Map<String, dynamic>) {
          avatarUrl =
              (images.first as Map<String, dynamic>)['url'] as String? ?? '';
        }
      } catch (_) {}
    }

    if (id.isEmpty && token.isNotEmpty) {
      try {
        final ap = await SpotifyAccessPoint.connect(client: _client);
        try {
          final welcome = await ap.authenticate(
            ApCredentials.accessToken(token),
          );
          if (welcome.canonicalUsername.isNotEmpty) {
            id = welcome.canonicalUsername;
          }
        } finally {
          ap.close();
        }
      } catch (_) {}
    }

    if (id.isEmpty && email.isNotEmpty) {
      id = email;
    }
    if (id.isEmpty) {
      throw StateError(_missingIdMessage);
    }
    if (displayName.isEmpty) {
      displayName = email.isNotEmpty ? email : id;
    }

    // 2. 读取已收藏的歌曲（collection/v2/paging 取曲目 URI，再用主会话 getTracksByUris 补全详情）
    List<SpotifyTrack> likedTracks = const [];
    if (token.isNotEmpty) {
      likedTracks = await _fetchSpClientLikedTracks(id, headers);
      if (likedTracks.isEmpty && session.spDc.trim().isNotEmpty) {
        try {
          final refreshed = await WebTokenService.mintTokenForSpDc(
            session.spDc.trim(),
            client: _client,
          );
          if (refreshed.token.isNotEmpty && refreshed.token != token) {
            token = refreshed.token;
            headers = buildHeaders(token);
            likedTracks = await _fetchSpClientLikedTracks(id, headers);
          }
        } catch (_) {}
      }
      if (likedTracks.isEmpty) {
        likedTracks = await _fetchPathfinderLikedTracks(headers);
      }
      if (likedTracks.isEmpty) {
        likedTracks = await _fetchWebApiLikedTracks(headers);
      }
    }

    // 3. 读取收藏歌单（rootlist 取歌单 ID，再用该账号会话或分享歌单 API getPlaylist 拉取歌单曲目）
    List<SpotifyPlaylist> playlists = const [];
    if (token.isNotEmpty) {
      playlists = await _fetchSpClientPlaylists(id, headers);
      if (playlists.isEmpty) {
        playlists = await _fetchWebApiPlaylists(headers);
      }
    }

    return BackupAccountSnapshot(
      id: id,
      email: email,
      displayName: displayName,
      avatarUrl: avatarUrl,
      likedTracks: likedTracks,
      playlists: playlists,
    );
  }

  Future<BackupAccountSnapshot> fetch(String spDc) =>
      fetchWithSession(BackupSessionCredentials(spDc: spDc));

  Future<List<SpotifyTrack>> _resolveTrackUris(
    List<String> uris,
    Map<String, DateTime?> addedAtByIdOrUri,
    Map<String, String> headers,
  ) async {
    if (uris.isEmpty) return const [];
    final api = _apiService;
    if (api != null && api.isConfigured) {
      final tracks = await api.getTracksByUris(uris);
      if (tracks.isNotEmpty) {
        return [
          for (final t in tracks)
            t.copyWith(
              addedAt: addedAtByIdOrUri[t.id] ?? addedAtByIdOrUri[t.uri],
            ),
        ];
      }
    }
    // 回退 1：用备份账号自身的 Pathfinder decorateContextTracks 补全
    try {
      final pathfinder = PathfinderClient(_client, headers: () async => headers);
      final resolved = <SpotifyTrack>[];
      for (var i = 0; i < uris.length; i += 50) {
        final batch = uris.sublist(i, min(i + 50, uris.length));
        final data = await pathfinder.query(
          PathfinderOperation.decorateContextTracks,
          {'uris': batch},
        );
        for (final t in PathfinderParsers.decoratedTracks(data)) {
          resolved.add(
            t.copyWith(
              addedAt: addedAtByIdOrUri[t.id] ?? addedAtByIdOrUri[t.uri],
            ),
          );
        }
      }
      if (resolved.isNotEmpty) return resolved;
    } catch (_) {}

    final ids = [
      for (final u in uris)
        if (u.startsWith('spotify:track:'))
          u.substring('spotify:track:'.length),
    ];
    final resolved = <SpotifyTrack>[];
    for (var i = 0; i < ids.length; i += 50) {
      final batch = ids.sublist(i, min(i + 50, ids.length)).join(',');
      try {
        final json = await _getJson('$_baseUrl/tracks?ids=$batch', headers);
        final list = json['tracks'];
        if (list is List) {
          for (final item in list.whereType<Map<String, dynamic>>()) {
            final track = SpotifyTrack.fromJson(item);
            resolved.add(
              track.copyWith(
                addedAt:
                    addedAtByIdOrUri[track.id] ?? addedAtByIdOrUri[track.uri],
              ),
            );
          }
        }
      } catch (_) {}
    }
    return resolved;
  }

  Future<List<SpotifyTrack>> _fetchSpClientLikedTracks(
    String user,
    Map<String, String> headers,
  ) async {
    try {
      final all = <CollectionEntry>[];
      var pageToken = '';
      for (var page = 0; page < _maxPages; page++) {
        final res = await _client.post(
          Uri.parse('$_spclient/collection/v2/paging'),
          headers: {
            ...headers,
            'Content-Type': CollectionCodec.contentType,
            'Accept': CollectionCodec.contentType,
          },
          body: CollectionCodec.encodePageRequest(
            username: user,
            set: CollectionCodec.setCollection,
            token: pageToken,
            limit: _pageSize,
          ),
        );
        if (res.statusCode != 200) break;
        final parsed = CollectionCodec.decodePage(res.bodyBytes);
        all.addAll(parsed.items.where((e) => e.kind == 'track'));
        if (parsed.nextToken.isEmpty || parsed.items.isEmpty) break;
        pageToken = parsed.nextToken;
      }
      if (all.isEmpty) return const [];
      final uris = [for (final e in all) e.uri];
      final addedAt = <String, DateTime?>{
        for (final e in all)
          if (e.addedAt > 0)
            e.id: DateTime.fromMillisecondsSinceEpoch(e.addedAt * 1000),
      };
      return await _resolveTrackUris(uris, addedAt, headers);
    } catch (_) {
      return const [];
    }
  }

  Future<SpotifyPlaylist?> _fetchSingleSpClientPlaylist(
    SpotifyPlaylist base,
    Map<String, String> headers,
  ) async {
    // 1) 先用备份账号自己的 token 读 playlist/v2/playlist/{id}（支持该账号专属的 Summer Mix / 电台与私密歌单）
    try {
      final res = await _client.get(
        Uri.parse(
          '$_spclient/playlist/v2/playlist/${Uri.encodeComponent(base.id)}'
          '?decorate=attributes,length,owner&from=0&length=$_playlistLimit',
        ),
        headers: headers,
      );
      if (res.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final parsed = PathfinderParsers.playlistV2(base.id, data);
        if (parsed != null && parsed.trackUris.isNotEmpty) {
          final tracks = await _resolveTrackUris(
            parsed.trackUris,
            parsed.addedAt,
            headers,
          );
          if (tracks.isNotEmpty) {
            return parsed.playlist.copyWith(
              name: parsed.playlist.name.isNotEmpty
                  ? parsed.playlist.name
                  : base.name,
              images: parsed.playlist.images.isNotEmpty
                  ? parsed.playlist.images
                  : base.images,
              tracks: tracks,
              totalTracks: tracks.length,
            );
          }
        }
      }
    } catch (_) {}

    // 2) 回退：走分享歌单 API（SpotifyApiService.getPlaylist）按歌单 ID 拉取
    final api = _apiService;
    if (api != null && api.isConfigured) {
      try {
        final full = await api.getPlaylist(base.id);
        return full.copyWith(
          name: full.name.isNotEmpty ? full.name : base.name,
          images: full.images.isNotEmpty ? full.images : base.images,
          totalTracks: full.tracks.isNotEmpty
              ? full.tracks.length
              : full.totalTracks,
        );
      } catch (_) {}
    }
    return null;
  }

  Future<List<SpotifyPlaylist>> _fetchSpClientPlaylists(
    String user,
    Map<String, String> headers,
  ) async {
    try {
      final res = await _client.get(
        Uri.parse(
          '$_spclient/playlist/v2/user/${Uri.encodeComponent(user)}/rootlist'
          '?decorate=revision,attributes,length,owner&from=0&length=$_playlistLimit',
        ),
        headers: headers,
      );
      if (res.statusCode != 200) return const [];
      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final rawPlaylists = RootlistParser.parse(json);
      final result = <SpotifyPlaylist>[];
      for (final p in rawPlaylists.take(_maxPlaylistsWithTracks)) {
        if (p.id.isEmpty) continue;
        final full = await _fetchSingleSpClientPlaylist(p, headers);
        result.add(full ?? p);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Future<List<SpotifyTrack>> _fetchPathfinderLikedTracks(
    Map<String, String> headers,
  ) async {
    try {
      final pathfinder = PathfinderClient(_client, headers: () async => headers);
      final all = <SpotifyTrack>[];
      var offset = 0;
      const pageSize = 50;
      for (var page = 0; page < 300; page++) {
        final data = await pathfinder.query(
          PathfinderOperation.fetchLibraryTracks,
          {'offset': offset, 'limit': pageSize},
        );
        final parsed = PathfinderParsers.libraryTracksPage(data);
        if (parsed.items.isEmpty) break;
        all.addAll(parsed.items);
        offset += parsed.items.length;
        if (parsed.totalCount > 0) {
          if (offset >= parsed.totalCount) break;
        } else if (parsed.items.length < pageSize) {
          break;
        }
      }
      return all;
    } catch (_) {
      return const [];
    }
  }

  Future<List<SpotifyTrack>> _fetchWebApiLikedTracks(
    Map<String, String> headers,
  ) async {
    try {
      final likedItems = await _pages(
        '$_baseUrl/me/tracks?limit=50',
        headers,
        (json) => json['items'],
      );
      return [
        for (final item in likedItems)
          if (item is Map<String, dynamic> &&
              item['track'] is Map<String, dynamic>)
            SpotifyTrack.fromJson(
              item['track'] as Map<String, dynamic>,
            ).copyWith(addedAt: SpotifyTrack.parseAddedAt(item['added_at'])),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<List<SpotifyPlaylist>> _fetchWebApiPlaylists(
    Map<String, String> headers,
  ) async {
    try {
      final rawPlaylists = await _pages(
        '$_baseUrl/me/playlists?limit=50',
        headers,
        (json) => json['items'],
      );
      final playlists = <SpotifyPlaylist>[];
      for (final item in rawPlaylists.take(_maxPlaylistsWithTracks)) {
        if (item is! Map<String, dynamic>) continue;
        var playlist = SpotifyPlaylist.fromJson(item);
        if (playlist.id.isEmpty) continue;
        if (playlist.tracks.isEmpty) {
          final full = await _fetchSingleSpClientPlaylist(playlist, headers);
          if (full != null) playlist = full;
        }
        playlists.add(playlist);
      }
      return playlists;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Object?>> _pages(
    String firstUrl,
    Map<String, String> headers,
    Object? Function(Map<String, dynamic> json) itemsOf, {
    int maxPages = 6,
  }) async {
    final result = <Object?>[];
    String? url = firstUrl;
    for (var page = 0; url != null && page < maxPages; page++) {
      final json = await _getJson(url, headers);
      final items = itemsOf(json);
      if (items is List) result.addAll(items);
      url = json['next'] as String?;
    }
    return result;
  }

  Future<Map<String, dynamic>> _getJson(
    String url,
    Map<String, String> headers,
  ) async {
    final res = await _client
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw HttpException('备份请求失败（HTTP ${res.statusCode}）', uri: Uri.parse(url));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份响应格式异常');
    }
    return decoded;
  }
}
