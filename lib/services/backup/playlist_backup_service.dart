import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../l10n/app_locale.dart';
import '../../models/app_preferences.dart';
import '../../models/image.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../providers/library_provider.dart';
import '../../providers/preferences_provider.dart';
import '../auth/client_profile.dart';
import '../auth/web_token_service.dart';
import '../library/collection_codec.dart';
import '../library/rootlist_parser.dart';
import '../pathfinder/pathfinder_parsers.dart';
import '../protocol/access_point.dart';
import '../spotify_api_service.dart';
import '../storage_service.dart';

/// 从独立 WebView 会话拿到的账号凭据与收藏快照。
class BackupAccountSnapshot {
  /// Spotify 唯一用户名 ID（canonical username）。
  final String id;

  /// 账户唯一邮箱（若接口返回则优先作为唯一识别符展示）。
  final String email;

  /// 账号昵称（可能与其他账号重名，仅作辅助展示，不作主键）。
  final String displayName;
  final String avatarUrl;
  final List<SpotifyTrack> likedTracks;
  final List<SpotifyPlaylist> playlists;

  const BackupAccountSnapshot({
    required this.id,
    required this.displayName,
    this.email = '',
    this.avatarUrl = '',
    this.likedTracks = const [],
    this.playlists = const [],
  });

  /// 账户唯一识别符：优先使用邮箱，无邮箱时使用 Spotify 唯一用户名 ID。
  String get uniqueId {
    final mail = email.trim();
    if (mail.isNotEmpty) return mail;
    return id.trim();
  }
}

/// 独立 WebView 登录捕获到的会话信息。
class BackupSessionCredentials {
  final String spDc;
  final String accessToken;
  final String clientToken;
  final String userId;
  final String email;
  final String displayName;
  final String avatarUrl;
  final String profileDir;

  const BackupSessionCredentials({
    required this.spDc,
    this.accessToken = '',
    this.clientToken = '',
    this.userId = '',
    this.email = '',
    this.displayName = '',
    this.avatarUrl = '',
    this.profileDir = '',
  });
}

typedef BackupRemoteFetcher =
    Future<BackupAccountSnapshot> Function(String spDc);

/// 单个已备份账号的落盘快照。
///
/// - 主键与展示均采用账户唯一识别符（[uniqueId]：优先邮箱 [email]，其次 Spotify 唯一用户名 [id]），
///   即使多个账号昵称（[displayName]）完全相同也不会冲突或覆盖；
/// - 每个账号提供独立的 [likedSongsPlaylist]（`id: 'backup_liked_<uniqueId>'`），点击可查看该账号自己的
///   已点赞歌曲（不会跳去当前登录账号的已点赞歌曲），并支持勾选其中部分歌曲一键合并导入到本账号；
/// - 歌单保留真实的 Spotify 歌单 ID（与分享歌单链接 `https://open.spotify.com/playlist/{id}` 一致）。
@immutable
class BackupAccount {
  static const String localAccountFallbackId = 'local_current_account';
  static const String backupLikedPrefix = 'backup_liked_';

  /// Spotify 唯一用户名 ID（canonical username）。
  final String id;

  /// 账户唯一邮箱（如 `user@example.com`）。
  final String email;

  /// 账户昵称（可重复，不作唯一键）。
  final String displayName;
  final String avatarUrl;

  /// 独立 WebView 登录捕获的 `sp_dc`（本机当前账号为空，直接读 [LibraryProvider]）。
  final String spDc;

  /// 独立 WebView 页面自身的会话 `accessToken`。
  final String accessToken;

  /// 独立 WebView 页面自身的 `client-token`。
  final String clientToken;

  /// 独立 WebView 资料目录名（多账号隔离 Cookie / Storage）。
  final String profileDir;

  /// 是否为本机当前已登录的账号。
  final bool isCurrentAccount;

  /// 一键同步到本账号时是否包含该账号的备份歌单与收藏歌曲。
  final bool syncToLocal;

  final DateTime? lastBackupAt;
  final List<SpotifyTrack> likedTracks;
  final List<SpotifyPlaylist> playlists;

  const BackupAccount({
    required this.id,
    required this.displayName,
    this.email = '',
    this.avatarUrl = '',
    this.spDc = '',
    this.accessToken = '',
    this.clientToken = '',
    this.profileDir = '',
    this.isCurrentAccount = false,
    this.syncToLocal = true,
    this.lastBackupAt,
    this.likedTracks = const [],
    this.playlists = const [],
  });

  /// 账户唯一识别符：优先使用邮箱 [email]，无邮箱时使用 Spotify 唯一用户名 [id]。
  String get uniqueId {
    final mail = email.trim();
    if (mail.isNotEmpty) return mail;
    return id.trim();
  }

  /// 展示标题：以唯一识别符为主（若昵称与唯一识别符不同，则显示「唯一识别符（昵称）」），
  /// 确保同名账号在界面与同步歌单中绝不混淆。
  String get title {
    final uid = uniqueId;
    final name = displayName.trim();
    if (uid.isNotEmpty && name.isNotEmpty && name != uid) {
      return '$uid（$name）';
    }
    return uid.isNotEmpty ? uid : name;
  }

  /// 该账号自己的「已点赞的歌曲」歌单：
  /// 使用专属 `backup_liked_<uniqueId>` 作为 ID，使 [PlaylistDetailScreen] 直接展示该账号的
  /// [likedTracks]（而不会被 `LibraryProvider.likedSongsId` 替换成当前本机账号的已点赞歌曲）。
  SpotifyPlaylist get likedSongsPlaylist => SpotifyPlaylist(
    id: '$backupLikedPrefix$uniqueId',
    name: '$title · 已点赞的歌曲',
    uri: 'spotify:playlist:$backupLikedPrefix$uniqueId',
    ownerName: title,
    images: const [
      SpotifyImage(
        url: 'https://misc.scdn.co/liked-songs/liked-songs-640.png',
      ),
    ],
    tracks: likedTracks,
    totalTracks: likedTracks.length,
    primaryColor: '#450af5',
  );

  /// 该账号下的全部备份条目（该账号自己的「已点赞的歌曲」+ 该账号的收藏歌单）。
  List<SpotifyPlaylist> get backedUpPlaylists => [
    if (likedTracks.isNotEmpty) likedSongsPlaylist,
    for (final p in playlists)
      p.copyWith(
        ownerName: p.ownerName.isNotEmpty && p.ownerName != 'Spotify'
            ? p.ownerName
            : title,
        totalTracks: p.tracks.isNotEmpty ? p.tracks.length : p.totalTracks,
      ),
  ];

  /// 判断两个账号记录是否属于同一个 Spotify 账户（按唯一 ID 或唯一邮箱比对，绝不按昵称比对）。
  bool matchesIdentity({required String otherId, required String otherEmail}) {
    final aId = id.trim();
    final bId = otherId.trim();
    if (aId.isNotEmpty && bId.isNotEmpty && aId == bId) return true;
    final aMail = email.trim().toLowerCase();
    final bMail = otherEmail.trim().toLowerCase();
    if (aMail.isNotEmpty && bMail.isNotEmpty && aMail == bMail) return true;
    return false;
  }

  BackupAccount copyWith({
    String? id,
    String? email,
    String? displayName,
    String? avatarUrl,
    String? spDc,
    String? accessToken,
    String? clientToken,
    String? profileDir,
    bool? isCurrentAccount,
    bool? syncToLocal,
    DateTime? lastBackupAt,
    List<SpotifyTrack>? likedTracks,
    List<SpotifyPlaylist>? playlists,
  }) {
    return BackupAccount(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      spDc: spDc ?? this.spDc,
      accessToken: accessToken ?? this.accessToken,
      clientToken: clientToken ?? this.clientToken,
      profileDir: profileDir ?? this.profileDir,
      isCurrentAccount: isCurrentAccount ?? this.isCurrentAccount,
      syncToLocal: syncToLocal ?? this.syncToLocal,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
      likedTracks: likedTracks ?? this.likedTracks,
      playlists: playlists ?? this.playlists,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'spDc': spDc,
    'accessToken': accessToken,
    'clientToken': clientToken,
    'profileDir': profileDir,
    'isCurrentAccount': isCurrentAccount,
    'syncToLocal': syncToLocal,
    'lastBackupAt': lastBackupAt?.toIso8601String(),
    'likedTracks': [for (final t in likedTracks) t.toJson()],
    'playlists': [for (final p in playlists) p.toJson()],
  };

  static String _normalizePlaylistId(String rawId) {
    if (!rawId.startsWith('backup_')) return rawId;
    final rest = rawId.substring('backup_'.length);
    final lastUnderscore = rest.lastIndexOf('_');
    if (lastUnderscore <= 0 || lastUnderscore + 1 >= rest.length) return rawId;
    return rest.substring(lastUnderscore + 1);
  }

  factory BackupAccount.fromJson(Map<String, dynamic> json) {
    final rawLiked = json['likedTracks'];
    final rawPlaylists = json['playlists'];
    final lastBackupRaw = json['lastBackupAt'];
    final playlists = rawPlaylists is List
        ? rawPlaylists
              .whereType<Map<String, dynamic>>()
              .map(SpotifyPlaylist.fromJson)
              .where(
                (p) =>
                    !p.id.endsWith('_liked') &&
                    !p.id.startsWith(backupLikedPrefix),
              )
              .map((p) {
                final cleanId = _normalizePlaylistId(p.id);
                return cleanId == p.id
                    ? p
                    : p.copyWith(
                        id: cleanId,
                        uri: 'spotify:playlist:$cleanId',
                      );
              })
              .toList()
        : const <SpotifyPlaylist>[];
    return BackupAccount(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      avatarUrl: json['avatarUrl'] as String? ?? '',
      spDc: json['spDc'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      clientToken: json['clientToken'] as String? ?? '',
      profileDir: json['profileDir'] as String? ?? '',
      isCurrentAccount: json['isCurrentAccount'] as bool? ?? false,
      syncToLocal: json['syncToLocal'] as bool? ?? true,
      lastBackupAt: lastBackupRaw is String
          ? DateTime.tryParse(lastBackupRaw)
          : null,
      likedTracks: rawLiked is List
          ? rawLiked
                .whereType<Map<String, dynamic>>()
                .map(SpotifyTrack.fromJson)
                .toList()
          : const [],
      playlists: playlists,
    );
  }
}

/// 一键同步 / 导入备份到当前账号的结果统计。
@immutable
class BackupSyncResult {
  final int addedLikedTracks;
  final int syncedPlaylists;

  const BackupSyncResult({
    required this.addedLikedTracks,
    required this.syncedPlaylists,
  });
}

/// 读取备份账号唯一识别符（邮箱 / 用户名 ID）、已点赞歌曲与歌单曲目。
class SpDcBackupFetcher {
  static const String _spclient = SpotifyEndpoints.defaultSpClientBase;
  static const int _pageSize = 300;
  static const int _maxPages = 10;
  static const int _trackLimit = 500;
  static const int _playlistLimit = 300;
  static const int _maxPlaylistsWithTracks = 30;

  final http.Client _client;
  final String _baseUrl;
  final SpotifyApiService? _apiService;

  SpDcBackupFetcher({
    http.Client? client,
    String baseUrl = SpotifyEndpoints.defaultWebApiBase,
    SpotifyApiService? apiService,
  }) : _client = client ?? http.Client(),
       _baseUrl = baseUrl,
       _apiService = apiService;

  Future<BackupAccountSnapshot> fetchWithSession(
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

    // 1. 读取唯一识别符（邮箱 email + 唯一用户名 id）：优先 /v1/me，若被限流则走 APWelcome 取 canonicalUsername
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
      throw StateError('无法读取备份账号的唯一识别符，请确认已在 WebView 中完成登录');
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
      final kept = all.take(_trackLimit).toList();
      final uris = [for (final e in kept) e.uri];
      final addedAt = <String, DateTime?>{
        for (final e in kept)
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

/// 歌单备份服务：
/// - 支持展示各个备份账号各自的「已点赞的歌曲」（`backup_liked_<uniqueId>`）与收藏歌单；
/// - 导入 / 同步「已点赞的歌曲」时，将歌曲**合并**进当前账号的 Liked Songs；
/// - 无论是备份的歌曲还是歌单，均支持勾选其中一部分一键导入到当前账号。
class PlaylistBackupService extends ChangeNotifier {
  static const int minIntervalMinutes = AppPreferences.minBackupIntervalMinutes;
  static const int defaultIntervalMinutes =
      AppPreferences.defaultBackupIntervalMinutes;
  static const List<int> intervalOptionsMinutes =
      AppPreferences.backupIntervalOptions;

  final StorageService _storage;
  final LibraryProvider? _library;
  final PreferencesProvider? _preferences;
  final SpotifyApiService? _apiService;
  final BackupRemoteFetcher? _customRemoteFetcher;
  final SpDcBackupFetcher _sessionFetcher;
  final File? _diskFile;

  /// 生产环境的备份文件（应用数据目录，由 main 在启动时设置）；测试不设置时只用 SharedPreferences。
  static File? defaultDiskFile;
  final DateTime Function() _now;
  final bool _enablePeriodicTimer;

  List<BackupAccount> _accounts = const [];
  bool _enabled = false;
  bool _autoCurrentAccount = true;
  int _intervalMinutes = defaultIntervalMinutes;
  bool _isBackingUp = false;
  String? _lastError;
  Timer? _timer;
  bool _disposed = false;

  /// 记录上次已落盘的本机收藏引用，仅在真正变化时立即重写落盘。
  List<SpotifyTrack>? _lastLocalLiked;
  List<SpotifyPlaylist>? _lastLocalPlaylists;

  PlaylistBackupService(
    this._storage, {
    LibraryProvider? library,
    PreferencesProvider? preferences,
    SpotifyApiService? apiService,
    BackupRemoteFetcher? remoteFetcher,
    SpDcBackupFetcher? sessionFetcher,
    File? diskFile,
    DateTime Function()? now,
    bool? enablePeriodicTimer,
  }) : _library = library,
       _preferences = preferences,
       _apiService = apiService,
       _customRemoteFetcher = remoteFetcher,
       _sessionFetcher =
           sessionFetcher ?? SpDcBackupFetcher(apiService: apiService),
       _diskFile = diskFile ?? defaultDiskFile,
       _now = now ?? DateTime.now,
       _enablePeriodicTimer =
           enablePeriodicTimer ??
           !Platform.environment.containsKey('FLUTTER_TEST') {
    _loadFromDisk();
    final prefs =
        _preferences?.prefs ?? AppPreferences.decode(_storage.preferencesJson);
    _enabled = prefs.backupEnabled;
    _autoCurrentAccount = prefs.backupAutoCurrentAccount;
    _intervalMinutes = max(minIntervalMinutes, prefs.backupIntervalMinutes);

    _library?.addListener(_onLibraryChanged);
    _preferences?.addListener(_onPreferencesChanged);
    _rescheduleTimer();
    if (_enabled && _autoCurrentAccount) {
      _backupCurrentAccountImmediate();
    }
    if (_enabled && _apiService != null) {
      unawaited(_hydrateIncompleteAccounts());
    }
  }

  List<BackupAccount> get accounts => _accounts;
  bool get enabled => _enabled;
  bool get autoCurrentAccount => _autoCurrentAccount;
  int get intervalMinutes => _intervalMinutes;
  Duration get effectiveInterval =>
      Duration(minutes: max(minIntervalMinutes, _intervalMinutes));
  bool get isBackingUp => _isBackingUp;
  String? get lastError => _lastError;

  /// 所有备份账号合并后的「已点赞的歌曲」（按曲目 ID 去重）。
  List<SpotifyTrack> get mergedLikedTracks {
    final seen = <String>{};
    final merged = <SpotifyTrack>[];
    for (final account in _accounts) {
      for (final track in account.likedTracks) {
        final key = track.id.isNotEmpty ? track.id : track.uri;
        if (key.isEmpty || seen.add(key)) {
          merged.add(track);
        }
      }
    }
    return merged;
  }

  /// 判断指定歌单 ID 是否为「外部备份账号的已点赞歌曲」虚拟歌单（排除本机当前账号）。
  bool isExternalBackupLikedPlaylist(String playlistId) {
    if (!playlistId.startsWith(BackupAccount.backupLikedPrefix)) return false;
    final uid = playlistId.substring(BackupAccount.backupLikedPrefix.length);
    return _accounts.any((a) => !a.isCurrentAccount && a.uniqueId == uid);
  }

  /// 已落盘的备份歌单汇总：
  /// - 包含每个账号各自的「已点赞的歌曲」（`backup_liked_<uniqueId>`，点击可查看该账号自己的已点赞歌曲）；
  /// - 包含各账号的收藏歌单（不同账号间若有同 ID 或同名重合歌单，自动合并其曲目）。
  List<SpotifyPlaylist> get allBackedUpPlaylists {
    final likedPlaylists = <SpotifyPlaylist>[];
    final seenLikedIds = <String>{};
    final mergedPlaylists = <SpotifyPlaylist>[];

    // 当前登录账号自己的歌单本来就在媒体库里，导入给自己没有意义
    for (final account in visibleAccounts) {
      if (account.likedTracks.isNotEmpty) {
        final likedPl = account.likedSongsPlaylist;
        if (seenLikedIds.add(likedPl.id)) {
          likedPlaylists.add(likedPl);
        }
      }
      for (final p in account.playlists) {
        if (p.id.isEmpty) continue;
        final normalized = p.copyWith(
          ownerName: p.ownerName.isNotEmpty && p.ownerName != 'Spotify'
              ? p.ownerName
              : account.title,
          totalTracks: p.tracks.isNotEmpty ? p.tracks.length : p.totalTracks,
        );
        final existingIdx = mergedPlaylists.indexWhere(
          (existing) =>
              existing.id == normalized.id ||
              (normalized.name.trim().isNotEmpty &&
                  existing.name.trim().toLowerCase() ==
                      normalized.name.trim().toLowerCase()),
        );
        if (existingIdx >= 0) {
          mergedPlaylists[existingIdx] = LibraryProvider.mergePlaylists(
            mergedPlaylists[existingIdx],
            normalized,
          );
        } else {
          mergedPlaylists.add(normalized);
        }
      }
    }
    return [...likedPlaylists, ...mergedPlaylists];
  }

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  /// 更新备份开关与频率配置（测试或未挂 PreferencesProvider 时也可直接调用）。
  void configure({
    bool? enabled,
    bool? autoCurrentAccount,
    int? intervalMinutes,
  }) {
    final prevEnabled = _enabled;
    final prevAuto = _autoCurrentAccount;
    final prevInterval = _intervalMinutes;

    if (enabled != null) _enabled = enabled;
    if (autoCurrentAccount != null) _autoCurrentAccount = autoCurrentAccount;
    if (intervalMinutes != null) {
      _intervalMinutes = max(minIntervalMinutes, intervalMinutes);
    }

    if (prevEnabled != _enabled || prevInterval != _intervalMinutes) {
      _rescheduleTimer();
    }
    if (_enabled && _autoCurrentAccount && (!prevEnabled || !prevAuto)) {
      _backupCurrentAccountImmediate();
    } else {
      _notify();
    }
  }

  void _onPreferencesChanged() {
    final prefs = _preferences?.prefs;
    if (prefs == null) return;
    configure(
      enabled: prefs.backupEnabled,
      autoCurrentAccount: prefs.backupAutoCurrentAccount,
      intervalMinutes: prefs.backupIntervalMinutes,
    );
  }

  /// 本机账号的收藏歌曲或歌单发生任何增删改时，立即落盘，不等定时轮询。
  void _onLibraryChanged() {
    if (!_enabled || !_autoCurrentAccount) return;
    final library = _library;
    if (library == null) return;
    if (identical(library.likedTracks, _lastLocalLiked) &&
        identical(library.playlists, _lastLocalPlaylists)) {
      return;
    }
    _backupCurrentAccountImmediate();
  }

  void _backupCurrentAccountImmediate() {
    final library = _library;
    if (library == null) return;
    // 只在「确实是这个账号、且媒体库已加载完」时落盘：
    // - 未登录 / 刚退出：媒体库被清空，不能拿空数据覆盖备份；
    // - 加载中 / 用户名还没解析出来：可能是上一个账号的残留或半截数据。
    if (!_storage.isLoggedIn || library.isLoading) return;
    final id = _storage.username.trim();
    if (id.isEmpty) return;
    // 媒体库数据必须属于这个账号：换号时媒体库先清空、拉完新数据才标记归属，
    // 中间任何时刻（定时器、设置变化）触发都不能把空数据或上一个账号的数据写成本账号的备份
    if (_storage.libraryAccount != id) return;
    // 读取失败时媒体库可能是空的或残缺的：等下次读取成功再备份，不覆盖已有的完整备份
    if (library.loadError != null) return;

    final liked = library.likedTracks;
    final playlists = library.playlists
        .where(
          (p) =>
              !p.id.endsWith('_liked') &&
              !p.id.startsWith(BackupAccount.backupLikedPrefix),
        )
        .toList();
    _lastLocalLiked = liked;
    _lastLocalPlaylists = library.playlists;

    final email = _storage.email.trim();
    final displayName = _storage.displayName.trim().isNotEmpty
        ? _storage.displayName.trim()
        : (email.isNotEmpty ? email : id);

    bool isSelf(BackupAccount a) =>
        a.id == id || (email.isNotEmpty && a.email.trim() == email);

    // 换了账号：之前登录账号的备份降级为「以前登录的账号」保留，并在设置里显示出来
    var accounts = [
      for (final a in _accounts)
        if (a.isCurrentAccount && !isSelf(a))
          a.copyWith(isCurrentAccount: false)
        else
          a,
    ];
    // 同一账号以前作为外部账号 / 以前登录过：并入当前账号这一条，不留重复
    final existingIndex = accounts.indexWhere(isSelf);
    final existing = existingIndex >= 0 ? accounts[existingIndex] : null;
    final updated = BackupAccount(
      id: id,
      email: email,
      displayName: displayName,
      avatarUrl: _storage.avatarUrl,
      isCurrentAccount: true,
      syncToLocal: existing?.syncToLocal ?? true,
      lastBackupAt: _now(),
      likedTracks: List.unmodifiable(liked),
      playlists: List.unmodifiable(playlists),
    );
    accounts = [
      for (var i = 0; i < accounts.length; i++)
        if (i != existingIndex) accounts[i],
    ];
    _accounts = List.unmodifiable([updated, ...accounts]);
    _persistToDisk();
    _notify();
  }

  /// 当前登录账号的备份记录（设置页不显示它；切换到别的账号后它才作为「以前登录的账号」出现）。
  /// 只认「标记为当前账号且就是现在登录的这个号」：换号后即使还没来得及备份新账号
  /// （例如关闭了自动备份），旧账号的记录也会立即作为「以前登录的账号」显示出来。
  bool isLiveCurrentAccount(BackupAccount account) {
    if (!account.isCurrentAccount || !_storage.isLoggedIn) return false;
    final id = _storage.username.trim();
    final email = _storage.email.trim();
    return (id.isNotEmpty && account.id == id) ||
        (email.isNotEmpty && account.email.trim() == email);
  }

  /// 设置页「歌单备份」里显示的账号：隐藏当前登录账号自己的备份。
  List<BackupAccount> get visibleAccounts => [
    for (final a in _accounts)
      if (!isLiveCurrentAccount(a)) a,
  ];

  /// 若磁盘上已有外部账号的已点赞歌曲或歌单曲目为空（如旧版本留下的 0 首记录），自动拉取补齐落盘。
  Future<void> _hydrateIncompleteAccounts() async {
    var changed = false;
    final nextAccounts = <BackupAccount>[];
    for (final account in _accounts) {
      if (account.isCurrentAccount) {
        nextAccounts.add(account);
        continue;
      }
      final needsHydrate =
          account.likedTracks.isEmpty ||
          account.playlists.any((p) => p.tracks.isEmpty);
      if (needsHydrate &&
          (account.accessToken.isNotEmpty || account.spDc.isNotEmpty)) {
        try {
          final snap = await _fetchSnapshot(
            BackupSessionCredentials(
              spDc: account.spDc,
              accessToken: account.accessToken,
              clientToken: account.clientToken,
              userId: account.id,
              email: account.email,
              displayName: account.displayName,
              avatarUrl: account.avatarUrl,
              profileDir: account.profileDir,
            ),
          );
          if (snap.likedTracks.isNotEmpty ||
              snap.playlists.any((p) => p.tracks.isNotEmpty)) {
            nextAccounts.add(
              account.copyWith(
                likedTracks: snap.likedTracks.isNotEmpty
                    ? List.unmodifiable(snap.likedTracks)
                    : account.likedTracks,
                playlists: snap.playlists.isNotEmpty
                    ? List.unmodifiable(snap.playlists)
                    : account.playlists,
                lastBackupAt: _now(),
              ),
            );
            changed = true;
            continue;
          }
        } catch (_) {}
      }
      nextAccounts.add(account);
    }
    if (changed && !_disposed) {
      _accounts = List.unmodifiable(nextAccounts);
      _persistToDisk();
      _notify();
    }
  }

  Future<BackupAccountSnapshot> _fetchSnapshot(
    BackupSessionCredentials credentials,
  ) {
    final custom = _customRemoteFetcher;
    if (custom != null) {
      return custom(credentials.spDc);
    }
    return _sessionFetcher.fetchWithSession(credentials);
  }

  /// 通过独立 WebView 拿到的会话凭据添加（或更新）外部备份账号，按唯一识别符（邮箱 / 唯一 ID）去重并落盘。
  Future<BackupAccount> addAccountWithSession(
    BackupSessionCredentials credentials,
  ) async {
    final cleanSpDc = credentials.spDc.trim();
    if (cleanSpDc.isEmpty && credentials.accessToken.trim().isEmpty) {
      throw ArgumentError('WebView 会话凭据不能为空');
    }
    _isBackingUp = true;
    _lastError = null;
    _notify();
    try {
      final snapshot = await _fetchSnapshot(credentials);
      final resolvedEmail = snapshot.email.trim().isNotEmpty
          ? snapshot.email.trim()
          : credentials.email.trim();
      final resolvedId = snapshot.id.trim().isNotEmpty
          ? snapshot.id.trim()
          : credentials.userId.trim();
      final existingIndex = _accounts.indexWhere(
        (a) =>
            !a.isCurrentAccount &&
            a.matchesIdentity(otherId: resolvedId, otherEmail: resolvedEmail),
      );
      final account = BackupAccount(
        id: resolvedId,
        email: resolvedEmail,
        displayName: snapshot.displayName,
        avatarUrl: snapshot.avatarUrl,
        spDc: cleanSpDc,
        accessToken: credentials.accessToken.trim(),
        clientToken: credentials.clientToken.trim(),
        profileDir: credentials.profileDir.isNotEmpty
            ? credentials.profileDir
            : (existingIndex >= 0 ? _accounts[existingIndex].profileDir : ''),
        isCurrentAccount: false,
        syncToLocal: existingIndex >= 0
            ? _accounts[existingIndex].syncToLocal
            : true,
        lastBackupAt: _now(),
        likedTracks: List.unmodifiable(snapshot.likedTracks),
        playlists: List.unmodifiable(snapshot.playlists),
      );
      if (existingIndex >= 0) {
        _accounts = [..._accounts]..[existingIndex] = account;
      } else {
        _accounts = [..._accounts, account];
      }
      _persistToDisk();
      return account;
    } catch (e) {
      _lastError = '备份账号失败：$e';
      rethrow;
    } finally {
      _isBackingUp = false;
      _notify();
    }
  }

  /// 兼容仅传 `spDc` 的添加方式。
  Future<BackupAccount> addAccountWithSpDc(
    String spDc, {
    String accessToken = '',
    String clientToken = '',
    String userId = '',
    String email = '',
    String displayName = '',
    String avatarUrl = '',
    String profileDir = '',
  }) => addAccountWithSession(
    BackupSessionCredentials(
      spDc: spDc,
      accessToken: accessToken,
      clientToken: clientToken,
      userId: userId,
      email: email,
      displayName: displayName,
      avatarUrl: avatarUrl,
      profileDir: profileDir,
    ),
  );

  /// 立即执行一次全量备份（本机账号 + 所有已添加的外部账号）并落盘。
  Future<void> backupAllAccounts() async {
    if (_isBackingUp) return;
    _isBackingUp = true;
    _lastError = null;
    _notify();
    try {
      if (_autoCurrentAccount) {
        _backupCurrentAccountImmediate();
      }
      final updated = <BackupAccount>[];
      for (final account in _accounts) {
        if (account.isCurrentAccount) {
          updated.add(account);
          continue;
        }
        if (account.spDc.isEmpty && account.accessToken.isEmpty) {
          updated.add(account);
          continue;
        }
        try {
          final snapshot = await _fetchSnapshot(
            BackupSessionCredentials(
              spDc: account.spDc,
              accessToken: account.accessToken,
              clientToken: account.clientToken,
              userId: account.id,
              email: account.email,
              displayName: account.displayName,
              avatarUrl: account.avatarUrl,
              profileDir: account.profileDir,
            ),
          );
          updated.add(
            account.copyWith(
              id: snapshot.id.isNotEmpty ? snapshot.id : account.id,
              email: snapshot.email.isNotEmpty ? snapshot.email : account.email,
              displayName: snapshot.displayName,
              avatarUrl: snapshot.avatarUrl,
              lastBackupAt: _now(),
              likedTracks: List.unmodifiable(snapshot.likedTracks),
              playlists: List.unmodifiable(snapshot.playlists),
            ),
          );
        } catch (e) {
          _lastError ??= '账号 ${account.title} 备份失败：$e';
          updated.add(account);
        }
      }
      _accounts = List.unmodifiable(updated);
      _persistToDisk();
    } finally {
      _isBackingUp = false;
      _notify();
    }
  }

  /// 正在后台导入（设置页据此禁用导入按钮、显示进度）。
  bool get isImporting => _isImporting;
  bool _isImporting = false;

  /// 将所选的备份歌曲列表一键**合并**导入到当前账号的「已点赞的歌曲」（Liked Songs）。
  /// 本地一次合并，同步到 Spotify 在后台逐首进行，不阻塞界面。
  Future<int> importSelectedTracksToLiked(List<SpotifyTrack> tracks) async {
    final library = _library;
    if (library == null || tracks.isEmpty) return 0;
    return _runImport(() => library.likeTracks(tracks));
  }

  /// 将所选的备份歌单列表一键导入到当前账号（在后台进行，不阻塞界面）：
  /// - 若选中的包含某账号的「已点赞的歌曲」（`backup_liked_*`），将其歌曲合并进当前账号的 Liked Songs；
  /// - 普通歌单保留真实歌单 ID 导入到当前账号歌单列表。
  Future<BackupSyncResult> importSelectedPlaylists(
    List<SpotifyPlaylist> playlists,
  ) async {
    final library = _library;
    if (library == null || playlists.isEmpty) {
      return const BackupSyncResult(addedLikedTracks: 0, syncedPlaylists: 0);
    }
    final likedTracks = <SpotifyTrack>[];
    final synced = <SpotifyPlaylist>[];
    for (final playlist in playlists) {
      if (playlist.id.startsWith(BackupAccount.backupLikedPrefix) ||
          playlist.id == LibraryProvider.likedSongsId) {
        likedTracks.addAll(playlist.tracks);
        continue;
      }
      if (playlist.id.isEmpty) continue;
      synced.add(
        playlist.copyWith(
          uri: playlist.uri.isNotEmpty
              ? playlist.uri
              : 'spotify:playlist:${playlist.id}',
          totalTracks: playlist.tracks.isNotEmpty
              ? playlist.tracks.length
              : playlist.totalTracks,
        ),
      );
    }
    var addedTracks = 0;
    await _runImport(() {
      addedTracks = library.likeTracks(likedTracks);
      library.upsertLocalPlaylists(synced);
      return 0;
    });
    return BackupSyncResult(
      addedLikedTracks: addedTracks,
      syncedPlaylists: synced.length,
    );
  }

  /// 导入期间暂停「媒体库一变就备份」，结束后只备份一次。
  /// 先让出一帧，界面能立刻显示「后台导入中」再开始合并。
  Future<int> _runImport(int Function() work) async {
    _isImporting = true;
    _notify();
    await Future<void>.delayed(Duration.zero);
    final wasAuto = _autoCurrentAccount;
    _autoCurrentAccount = false;
    try {
      return work();
    } finally {
      _autoCurrentAccount = wasAuto;
      _isImporting = false;
      if (_enabled && _autoCurrentAccount) {
        _backupCurrentAccountImmediate();
      } else {
        _notify();
      }
    }
  }

  /// 一键将已勾选备份账号的全部歌单与已点赞歌曲同步到本机当前账号。
  Future<BackupSyncResult> syncToCurrentAccount() async {
    final selected = <SpotifyPlaylist>[];
    // 不含当前登录账号自己：把自己的歌单「导入」给自己只会在本机歌单里多出一份重复副本
    for (final account in visibleAccounts) {
      if (!account.syncToLocal) continue;
      selected.addAll(account.backedUpPlaylists);
    }
    return importSelectedPlaylists(selected);
  }

  void setAccountSyncEnabled(String accountKey, bool syncToLocal) {
    final index = _accounts.indexWhere(
      (a) => a.uniqueId == accountKey || a.id == accountKey,
    );
    if (index < 0) return;
    _accounts = [..._accounts]
      ..[index] = _accounts[index].copyWith(syncToLocal: syncToLocal);
    _persistToDisk();
    _notify();
  }

  void removeAccount(String accountKey) {
    final before = _accounts.length;
    _accounts = _accounts
        .where((a) => a.uniqueId != accountKey && a.id != accountKey)
        .toList();
    if (_accounts.length == before) return;
    _persistToDisk();
    _notify();
  }

  void _rescheduleTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_enabled || !_enablePeriodicTimer) return;
    _timer = Timer.periodic(effectiveInterval, (_) {
      unawaited(backupAllAccounts());
    });
  }

  void _loadFromDisk() {
    final file = _diskFile;
    if (file != null) {
      final fromFile = _readBackupFile(file);
      if (fromFile != null) {
        _accounts = fromFile;
        return;
      }
      if (file.existsSync()) {
        // 主文件损坏：留一份原样副本，免得之后的落盘把它覆盖掉
        try {
          file.copySync('${file.path}.corrupt');
        } catch (_) {}
      }
      // 上次写到一半（主文件缺失 / 损坏）：用完整写好的临时文件恢复
      final fromTmp = _readBackupFile(File('${file.path}.tmp'));
      if (fromTmp != null) {
        _accounts = fromTmp;
        _persistToDisk();
        return;
      }
    }
    final list = _storage.readJsonList(StorageService.keyPlaylistBackups);
    _accounts = List.unmodifiable(list.map(BackupAccount.fromJson));
    // 旧版本存在 SharedPreferences 里：迁移到独立文件后清掉，偏好文件不再背着整份备份
    if (file != null && list.isNotEmpty) {
      _persistToDisk();
      unawaited(_storage.writeJsonList(StorageService.keyPlaylistBackups, const []));
    }
  }

  /// 落盘排队：备份可能很大（多个账号的全部歌单曲目），编码放到后台 Isolate、文件异步写，
  /// 不卡界面；连续多次触发时串行执行，最后一次的内容最终落盘。
  Future<void> _persistQueue = Future.value();

  /// 等待排队中的落盘写完（测试用）。
  @visibleForTesting
  Future<void> get pendingPersist => _persistQueue;

  static List<BackupAccount>? _readBackupFile(File file) {
    try {
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return null;
      return List.unmodifiable(
        decoded.whereType<Map<String, dynamic>>().map(BackupAccount.fromJson),
      );
    } catch (_) {
      return null;
    }
  }

  void _persistToDisk() {
    final serialized = [for (final a in _accounts) a.toJson()];
    final file = _diskFile;
    if (file == null) {
      unawaited(
        _storage.writeJsonList(StorageService.keyPlaylistBackups, serialized),
      );
      return;
    }
    // 有独立文件时不再写进 SharedPreferences：备份可能很大，偏好文件每次保存都会整份重写
    _persistQueue = _persistQueue.then((_) async {
      try {
        final text = await Isolate.run(() => jsonEncode(serialized));
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        try {
          // 原子替换：任何时刻磁盘上都有一份完整的备份（旧的或新的）
          await tmp.rename(file.path);
        } on FileSystemException {
          // 目标被其他程序短暂占用（杀毒 / 同步盘）：退回直接覆盖写入
          await file.writeAsString(text, flush: true);
        }
      } catch (_) {}
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _library?.removeListener(_onLibraryChanged);
    _preferences?.removeListener(_onPreferencesChanged);
    super.dispose();
  }
}
