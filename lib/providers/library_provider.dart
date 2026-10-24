import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/image.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/library/library_source.dart';
import '../services/storage_service.dart';

/// Your Library：已点赞歌曲、收藏歌单、关注艺人、收藏专辑与本机歌单。
///
/// 数据来源（[LibrarySource]，由 `SpotifyApiService.library` 提供）：
/// - 已登录：启动与登录 / 登出后调用 [refresh] 从 Spotify 账号读取（桌面版会话走内部接口
///   `collection/v2` + rootlist，其余会话走 Web API）；点赞 / 收藏 / 关注先在本地生效，再后台同步到账号；
/// - 未登录：媒体库为空（不再有示例数据）；
/// - 未提供 source（单元测试 / 纯本地）：只使用本机持久化的数据。
///
/// 歌单说明：账号歌单来自 rootlist；「新建歌单」「保存别人的歌单」目前只保存在本机（[ownPlaylists] /
/// 本机收藏），尚未写回账号，刷新后仍然保留。
///
/// 所有列表采用「写时复制」：每次修改都生成新的 List 实例，getter 在两次修改之间
/// 返回同一实例。这样组件可以安全地 `context.select` 整个列表，
/// 只有真正发生变化时才重建。调用方不得原地修改返回的列表。
class LibraryProvider extends ChangeNotifier {
  static const String likedSongsId = 'liked_songs_collection';
  static const String likedSongsUri = 'spotify:collection:tracks';

  /// 缓存结构版本：1 及以前含示例数据，升级时清空并仅迁移本机新建的歌单。
  static const int _schema = 2;

  final StorageService _storage;
  final LibrarySource? _source;

  /// 最新点赞在前（与 Spotify "Liked Songs" 排序一致）。
  List<SpotifyTrack> _likedTracks = const [];
  Set<String> _likedIds = const {};

  /// 账号歌单（rootlist）与本机歌单（本机新建 / 本机保存）。对外的 [playlists] = 本机在前 + 账号歌单。
  List<SpotifyPlaylist> _remotePlaylists = const [];
  List<SpotifyPlaylist> _localPlaylists = const [];
  List<SpotifyPlaylist> _playlists = const [];
  List<SpotifyArtist> _artists = const [];
  List<SpotifyAlbum> _albums = const [];

  SpotifyPlaylist? _likedSongsCache;

  bool _isLoading = false;
  bool _disposed = false;
  String? _loadError;
  String? _syncError;
  int _refreshGeneration = 0;

  LibraryProvider(this._storage, {this._source}) {
    _load();
    if (_source != null) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------
  List<SpotifyTrack> get likedTracks => _likedTracks;
  List<SpotifyPlaylist> get playlists => _playlists;
  List<SpotifyArtist> get artists => _artists;
  List<SpotifyAlbum> get albums => _albums;

  /// 用户在本机新建的（可编辑）歌单。
  List<SpotifyPlaylist> get ownPlaylists => _playlists.where((p) => isOwnPlaylist(p.id)).toList();

  /// 正在从账号读取媒体库。
  bool get isLoading => _isLoading;

  /// 最近一次读取失败的说明（简体中文）；成功后为 null。失败时仍显示上次缓存的数据。
  String? get loadError => _loadError;

  /// 最近一次「同步到账号」失败的说明（点赞 / 收藏 / 关注在本地已生效但未写入账号）；UI 可提示并调用 [clearSyncError]。
  String? get syncError => _syncError;

  bool isOwnPlaylist(String id) => id.startsWith('local_');

  bool isLiked(String trackId) => _likedIds.contains(trackId);
  bool isPlaylistSaved(String id) => _playlists.any((p) => p.id == id);
  bool isFollowing(String artistId) => _artists.any((a) => a.id == artistId);
  bool isAlbumSaved(String id) => _albums.any((a) => a.id == id);

  /// 以歌单形式呈现的 Liked Songs，供详情页复用（名称 / 简介由 UI 按界面语言显示）。
  SpotifyPlaylist get likedSongsPlaylist {
    return _likedSongsCache ??= SpotifyPlaylist(
      id: likedSongsId,
      name: 'Liked Songs',
      uri: likedSongsUri,
      ownerName: _userName,
      images: const [SpotifyImage(url: 'https://misc.scdn.co/liked-songs/liked-songs-640.png')],
      tracks: _likedTracks,
      totalTracks: _likedTracks.length,
      primaryColor: '#450af5',
    );
  }

  /// 按 id 查找媒体库中的歌单（含 Liked Songs），用于详情页实时反映修改。
  SpotifyPlaylist? findPlaylist(String id) {
    if (id == likedSongsId) return likedSongsPlaylist;
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 当前账号的显示名（歌单所有者展示用）。
  String get _userName => _storage.displayName.isNotEmpty ? _storage.displayName : _storage.username;

  // ---------------------------------------------------------------------------
  // 从账号读取
  // ---------------------------------------------------------------------------

  /// 从 Spotify 账号重新读取媒体库（启动、登录 / 登出后调用）。
  ///
  /// - 未登录：清空账号数据（保留本机歌单）；
  /// - 已登录：四类数据并行读取，各自成功后立即更新界面；某一类失败不影响其他类，
  ///   失败原因记入 [loadError]，该类继续显示缓存。
  Future<void> refresh() async {
    final source = _source;
    if (source == null) return;
    final generation = ++_refreshGeneration;

    if (!source.isSignedIn) {
      _clearRemote();
      _isLoading = false;
      _loadError = null;
      notifyListeners();
      return;
    }

    // 换了账号：上一个账号的缓存立即作废，避免短暂显示他人的媒体库
    if (_storage.libraryAccount != source.accountId) {
      _clearRemote();
      await _storage.setLibraryAccount(source.accountId);
    }

    _isLoading = true;
    _loadError = null;
    notifyListeners();

    bool current() => generation == _refreshGeneration;
    void fail(Object e) => _loadError ??= e is LibrarySourceException ? e.toString() : '读取媒体库失败：$e';

    await Future.wait([
      _run(source.fetchLikedTracks, current, fail, (tracks) {
        _likedTracks = tracks;
        _likedIds = tracks.map((t) => t.id).toSet();
        _likedSongsCache = null;
        _storage.writeJsonList(StorageService.keyLibraryLikedTracks, tracks.map((t) => t.toJson()));
      }),
      _run(source.fetchPlaylists, current, fail, (playlists) {
        _remotePlaylists = playlists.map(_withOwnerName).toList();
        _rebuildPlaylists();
        _storage.writeJsonList(StorageService.keyLibraryPlaylists, _remotePlaylists.map((p) => p.toJson()));
      }),
      _run(source.fetchAlbums, current, fail, (albums) {
        _albums = albums;
        _storage.writeJsonList(StorageService.keyLibraryAlbums, albums.map((a) => a.toJson()));
      }),
      _run(source.fetchArtists, current, fail, (artists) {
        _artists = artists;
        _storage.writeJsonList(StorageService.keyLibraryArtists, artists.map((a) => a.toJson()));
      }),
    ]);

    if (!current()) return;
    _isLoading = false;
    notifyListeners();
  }

  /// 读取一类数据：成功则 [apply] 并通知界面；失败记录原因并保留缓存。过期的读取结果被丢弃。
  Future<void> _run<T>(
    Future<T> Function() fetch,
    bool Function() current,
    void Function(Object error) fail,
    void Function(T value) apply,
  ) async {
    try {
      final value = await fetch();
      if (!current()) return;
      apply(value);
    } catch (e) {
      if (!current()) return;
      fail(e);
    }
    notifyListeners();
  }

  /// rootlist 的所有者是用户名（canonical id）：本账号的歌单显示昵称，官方歌单显示 Spotify。
  SpotifyPlaylist _withOwnerName(SpotifyPlaylist p) {
    final owner = p.ownerName;
    if (owner.isEmpty || owner == 'spotify') return p.copyWith(ownerName: 'Spotify');
    if (owner == _storage.username) return p.copyWith(ownerName: _userName);
    return p;
  }

  void _clearRemote() {
    _likedTracks = const [];
    _likedIds = const {};
    _likedSongsCache = null;
    _remotePlaylists = const [];
    _artists = const [];
    _albums = const [];
    _rebuildPlaylists();
    _storage.removeKey(StorageService.keyLibraryLikedTracks);
    _storage.removeKey(StorageService.keyLibraryPlaylists);
    _storage.removeKey(StorageService.keyLibraryArtists);
    _storage.removeKey(StorageService.keyLibraryAlbums);
    _storage.setLibraryAccount('');
  }

  void _rebuildPlaylists() {
    final localIds = _localPlaylists.map((p) => p.id).toSet();
    final localNames = _localPlaylists
        .map((p) => p.name.trim().toLowerCase())
        .where((n) => n.isNotEmpty)
        .toSet();
    _playlists = [
      ..._localPlaylists,
      ..._remotePlaylists.where(
        (p) =>
            !localIds.contains(p.id) &&
            !localNames.contains(p.name.trim().toLowerCase()),
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  void clearSyncError() {
    if (_syncError == null) return;
    _syncError = null;
    notifyListeners();
  }

  /// 后台同步到账号：失败只记录 [syncError]（本地修改保留，下次 [refresh] 以账号为准）。
  void _sync(Future<void> Function(LibrarySource source) op) {
    final source = _source;
    if (source == null || !source.isSignedIn) return;
    op(source).catchError((Object e) {
      _syncError = e is LibrarySourceException ? e.toString() : '同步失败：$e';
      notifyListeners();
    });
  }

  void toggleLike(SpotifyTrack track) {
    final liking = !_likedIds.contains(track.id);
    if (liking) {
      _likedTracks = [track.copyWith(addedAt: DateTime.now()), ..._likedTracks];
    } else {
      _likedTracks = _likedTracks.where((t) => t.id != track.id).toList();
    }
    _likedIds = _likedTracks.map((t) => t.id).toSet();
    _likedSongsCache = null;
    _storage.writeJsonList(StorageService.keyLibraryLikedTracks, _likedTracks.map((t) => t.toJson()));
    notifyListeners();
    _sync((s) => s.setTrackLiked(track, liking));
  }

  /// 保存 / 取消保存歌单。账号歌单（rootlist）取消保存仅在本机隐藏到下次刷新；
  /// 保存别人的歌单目前只保存在本机。
  void togglePlaylistSaved(SpotifyPlaylist playlist) {
    if (isPlaylistSaved(playlist.id)) {
      _localPlaylists = _localPlaylists.where((p) => p.id != playlist.id).toList();
      _remotePlaylists = _remotePlaylists.where((p) => p.id != playlist.id).toList();
    } else {
      _localPlaylists = [playlist, ..._localPlaylists];
    }
    _rebuildPlaylists();
    _persistPlaylists();
    notifyListeners();
  }

  void toggleFollowArtist(SpotifyArtist artist) {
    final following = !isFollowing(artist.id);
    _artists = following ? [artist, ..._artists] : _artists.where((a) => a.id != artist.id).toList();
    _storage.writeJsonList(StorageService.keyLibraryArtists, _artists.map((a) => a.toJson()));
    notifyListeners();
    _sync((s) => s.setArtistFollowed(artist, following));
  }

  void toggleAlbumSaved(SpotifyAlbum album) {
    final saving = !isAlbumSaved(album.id);
    _albums = saving ? [album, ..._albums] : _albums.where((a) => a.id != album.id).toList();
    _storage.writeJsonList(StorageService.keyLibraryAlbums, _albums.map((a) => a.toJson()));
    notifyListeners();
    _sync((s) => s.setAlbumSaved(album, saving));
  }

  /// 合并两张重合的歌单（同 ID 或同名）：保留主歌单的 ID 与封面元数据，曲目按 ID / URI 去重合并。
  static SpotifyPlaylist mergePlaylists(
    SpotifyPlaylist base,
    SpotifyPlaylist incoming,
  ) {
    final seen = <String>{};
    final mergedTracks = <SpotifyTrack>[];
    for (final t in [...base.tracks, ...incoming.tracks]) {
      final key = t.id.isNotEmpty ? t.id : t.uri;
      if (key.isEmpty || seen.add(key)) {
        mergedTracks.add(t);
      }
    }
    final maxTotal = [
      mergedTracks.length,
      base.totalTracks,
      incoming.totalTracks,
    ].reduce((a, b) => a > b ? a : b);
    return base.copyWith(
      name: base.name.isNotEmpty ? base.name : incoming.name,
      description: base.description.isNotEmpty
          ? base.description
          : incoming.description,
      images: base.images.isNotEmpty ? base.images : incoming.images,
      tracks: mergedTracks,
      totalTracks: mergedTracks.isNotEmpty ? mergedTracks.length : maxTotal,
    );
  }

  static bool _isSamePlaylist(SpotifyPlaylist a, SpotifyPlaylist b) {
    if (a.id.isNotEmpty && b.id.isNotEmpty && a.id == b.id) return true;
    final nameA = a.name.trim().toLowerCase();
    final nameB = b.name.trim().toLowerCase();
    return nameA.isNotEmpty && nameA == nameB;
  }

  /// 批量点赞（备份一键导入用）：本地一次合并、只写一次存储、只通知一次界面；
  /// 同步到 Spotify 在后台逐首进行，不并发轰炸接口，也不阻塞界面。返回新增数量。
  int likeTracks(List<SpotifyTrack> tracks) {
    final now = DateTime.now();
    final seen = <String>{..._likedIds};
    final added = <SpotifyTrack>[
      for (final t in tracks)
        if (t.id.isNotEmpty && seen.add(t.id)) t.copyWith(addedAt: now),
    ];
    if (added.isEmpty) return 0;
    _likedTracks = [...added, ..._likedTracks];
    _likedIds = seen;
    _likedSongsCache = null;
    _storage.writeJsonList(StorageService.keyLibraryLikedTracks, _likedTracks.map((t) => t.toJson()));
    notifyListeners();
    final source = _source;
    if (source != null && source.isSignedIn) {
      final account = source.accountId;
      unawaited(() async {
        for (final t in added) {
          // 逐首同步期间：退出 / 换号就停；用户中途取消了收藏的歌不再写回账号
          if (_disposed || !source.isSignedIn || source.accountId != account) return;
          if (!_likedIds.contains(t.id)) continue;
          try {
            await source.setTrackLiked(t, true);
          } catch (e) {
            if (_disposed) return;
            _syncError = e is LibrarySourceException ? e.toString() : '同步失败：$e';
            notifyListeners();
            return;
          }
        }
      }());
    }
    return added.length;
  }

  /// 批量合并备份歌单（一键导入用）：逐个按 [upsertLocalPlaylist] 的规则合并，只落盘、通知一次。
  void upsertLocalPlaylists(List<SpotifyPlaylist> playlists) {
    if (playlists.isEmpty) return;
    for (final p in playlists) {
      _mergeLocalPlaylist(p);
    }
    _rebuildPlaylists();
    _persistPlaylists();
    notifyListeners();
  }

  /// 将备份的歌单合并到本机歌单（同 ID 或同名歌单已存在时合并去重曲目，否则插到顶部并落盘）。
  void upsertLocalPlaylist(SpotifyPlaylist playlist) {
    _mergeLocalPlaylist(playlist);
    _rebuildPlaylists();
    _persistPlaylists();
    notifyListeners();
  }

  void _mergeLocalPlaylist(SpotifyPlaylist playlist) {
    final localIdx = _localPlaylists.indexWhere(
      (p) => _isSamePlaylist(p, playlist),
    );
    final remoteMatch = _remotePlaylists
        .where((p) => _isSamePlaylist(p, playlist))
        .firstOrNull;
    if (localIdx >= 0) {
      var merged = mergePlaylists(_localPlaylists[localIdx], playlist);
      if (remoteMatch != null) {
        merged = mergePlaylists(remoteMatch, merged);
      }
      _localPlaylists = [..._localPlaylists]..[localIdx] = merged;
    } else if (remoteMatch != null) {
      final merged = mergePlaylists(remoteMatch, playlist);
      _localPlaylists = [merged, ..._localPlaylists];
    } else {
      _localPlaylists = [playlist, ..._localPlaylists];
    }
  }

  /// 新建歌单（仅保存在本机），返回创建结果。
  SpotifyPlaylist createPlaylist(String name) {
    final id = 'local_${DateTime.now().microsecondsSinceEpoch}';
    final playlist = SpotifyPlaylist(
      id: id,
      name: name.trim().isEmpty ? 'My Playlist #${ownPlaylists.length + 1}' : name.trim(),
      uri: 'spotify:playlist:$id',
      ownerName: _userName,
    );
    _localPlaylists = [playlist, ..._localPlaylists];
    _rebuildPlaylists();
    _persistPlaylists();
    notifyListeners();
    return playlist;
  }

  /// 添加到本机歌单；已存在或歌单不存在时返回 false。
  bool addTrackToPlaylist(String playlistId, SpotifyTrack track) {
    final index = _localPlaylists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return false;
    final playlist = _localPlaylists[index];
    if (playlist.tracks.any((t) => t.id == track.id)) return false;

    final tracks = [...playlist.tracks, track.copyWith(addedAt: DateTime.now())];
    final updated = playlist.copyWith(
      tracks: tracks,
      totalTracks: tracks.length,
      // 自建歌单无封面时，使用第一首歌的专辑封面（Spotify 行为）
      images: playlist.images.isEmpty ? track.album?.images : null,
    );
    _localPlaylists = [..._localPlaylists]..[index] = updated;
    _rebuildPlaylists();
    _persistPlaylists();
    notifyListeners();
    return true;
  }

  void removeTrackFromPlaylist(String playlistId, String trackId) {
    final index = _localPlaylists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return;
    final playlist = _localPlaylists[index];
    final tracks = playlist.tracks.where((t) => t.id != trackId).toList();
    _localPlaylists = [..._localPlaylists]..[index] = playlist.copyWith(tracks: tracks, totalTracks: tracks.length);
    _rebuildPlaylists();
    _persistPlaylists();
    notifyListeners();
  }

  void deletePlaylist(String playlistId) {
    _localPlaylists = _localPlaylists.where((p) => p.id != playlistId).toList();
    _remotePlaylists = _remotePlaylists.where((p) => p.id != playlistId).toList();
    _rebuildPlaylists();
    _persistPlaylists();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------
  void _persistPlaylists() {
    _storage.writeJsonList(StorageService.keyLibraryLocalPlaylists, _localPlaylists.map((p) => p.toJson()));
  }

  void _load() {
    // 旧版缓存（含示例数据）：丢弃，只迁移用户在本机新建的歌单（local_ 前缀）
    if (_storage.librarySchema < _schema) {
      final legacy = _storage
          .readJsonList(StorageService.keyLibraryPlaylists)
          .map(SpotifyPlaylist.fromJson)
          .where((p) => isOwnPlaylist(p.id))
          .toList();
      for (final key in [
        StorageService.keyLibraryLikedTracks,
        StorageService.keyLibraryPlaylists,
        StorageService.keyLibraryArtists,
        StorageService.keyLibraryAlbums,
      ]) {
        _storage.removeKey(key);
      }
      if (legacy.isNotEmpty) {
        _storage.writeJsonList(StorageService.keyLibraryLocalPlaylists, legacy.map((p) => p.toJson()));
      }
      _storage.setLibrarySchema(_schema);
    }

    // 有 source 时，账号缓存只在「已登录且账号一致」时才可信；未登录 / 换号则丢弃
    final source = _source;
    final cacheValid = source == null || (source.isSignedIn && _storage.libraryAccount == source.accountId);
    if (!cacheValid) {
      for (final key in [
        StorageService.keyLibraryLikedTracks,
        StorageService.keyLibraryPlaylists,
        StorageService.keyLibraryArtists,
        StorageService.keyLibraryAlbums,
      ]) {
        _storage.removeKey(key);
      }
    }

    _likedTracks = cacheValid
        ? _storage.readJsonList(StorageService.keyLibraryLikedTracks).map(SpotifyTrack.fromJson).toList()
        : const [];
    _likedIds = _likedTracks.map((t) => t.id).toSet();
    _remotePlaylists = cacheValid
        ? _storage.readJsonList(StorageService.keyLibraryPlaylists).map(SpotifyPlaylist.fromJson).toList()
        : const [];
    _artists = cacheValid
        ? _storage.readJsonList(StorageService.keyLibraryArtists).map(SpotifyArtist.fromJson).toList()
        : const [];
    _albums = cacheValid
        ? _storage.readJsonList(StorageService.keyLibraryAlbums).map(SpotifyAlbum.fromJson).toList()
        : const [];
    final rawLocal = _storage
        .readJsonList(StorageService.keyLibraryLocalPlaylists)
        .map(SpotifyPlaylist.fromJson)
        .where((p) => !p.id.endsWith('_liked') && !p.id.startsWith('backup_liked_'))
        .map((p) {
          final stripped = _stripLegacyBackupPrefix(p.id);
          return stripped == p.id
              ? p
              : p.copyWith(id: stripped, uri: 'spotify:playlist:$stripped');
        });
    final dedupedLocal = <SpotifyPlaylist>[];
    for (final p in rawLocal) {
      final idx = dedupedLocal.indexWhere((e) => _isSamePlaylist(e, p));
      if (idx >= 0) {
        dedupedLocal[idx] = mergePlaylists(dedupedLocal[idx], p);
      } else {
        dedupedLocal.add(p);
      }
    }
    _localPlaylists = dedupedLocal;
    _rebuildPlaylists();
  }

  static String _stripLegacyBackupPrefix(String id) {
    if (!id.startsWith('backup_')) return id;
    final rest = id.substring('backup_'.length);
    final lastUnderscore = rest.lastIndexOf('_');
    if (lastUnderscore <= 0 || lastUnderscore + 1 >= rest.length) return id;
    return rest.substring(lastUnderscore + 1);
  }
}
