import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/catalog_page.dart';
import '../../models/category.dart';
import '../../models/connect_cluster.dart';
import '../../models/device.dart';
import '../../models/editable_playlist.dart';
import '../../models/home_feed.dart';
import '../../models/lyrics.dart';
import '../../models/playlist.dart';
import '../../models/podcast.dart';
import '../../models/track.dart';
import '../../models/track_credits.dart';
import '../../models/user_profile.dart';
import '../constants/app_info.dart';
import '../../services/audio/audio_engine.dart';
import '../../services/audio/audio_output_service.dart';
import '../../services/auth/spotify_auth_service.dart';
import '../../services/cache/artwork_cache.dart';
import '../../services/cache/cache_location.dart';
import '../../services/canvas/canvas_service.dart';
import '../../services/connect/connect_service.dart';
import '../../services/eme/eme_player.dart';
import '../../services/library/library_source.dart';
import '../../services/lyrics/lyrics_resolver.dart';
import '../../services/playback/playback_region_gate.dart';
import '../../services/playback_session_store.dart';
import '../../services/protocol/track_audio_loader.dart';
import '../../services/spotify_api_service.dart';
import '../../services/storage_service.dart';
import '../../services/updates/update_installer.dart';
import '../../services/updates/update_release.dart';
import '../../services/updates/update_service.dart';
import 'mock_audio.dart';
import 'mock_catalog.dart';
import 'mock_cover_server.dart';

/// 屏蔽一切外网访问的离线 HTTP 客户端，确保 Mock 模式绝不产生意外公网请求。
class MockOfflineHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'api.github.com' &&
        request.url.path.endsWith('/releases')) {
      final body = utf8.encode('[]');
      return http.StreamedResponse(
        Stream.value(body),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('Mock offline HTTP guard')),
      503,
    );
  }
}

/// Mock 媒体库数据源：在内存中维护点赞曲目、可编辑账号歌单、专辑与关注艺人。
class MockLibrarySource implements LibrarySource {
  final MockCatalog catalog;
  final bool Function() _isSignedIn;

  late List<SpotifyTrack> likedTracks = List.of(catalog.coreTracks.take(6));
  late List<SpotifyAlbum> albums = List.of(catalog.albums);
  late List<SpotifyArtist> artists = List.of(catalog.artists.take(3));
  late final Map<String, SpotifyPlaylist> _playlistsByUri = {
    for (final pl in catalog.playlists) pl.uri: pl,
  };
  late final Map<String, List<SpotifyTrack>> _playlistTracks = {
    for (final pl in catalog.playlists) pl.uri: List.of(pl.tracks),
  };

  MockLibrarySource(this.catalog, {required bool Function() isSignedIn})
    : _isSignedIn = isSignedIn;

  @override
  bool get isSignedIn => _isSignedIn();

  @override
  String get accountId => isSignedIn ? catalog.currentUser.id : '';

  SpotifyPlaylist? findPlaylistByIdOrUri(String idOrUri) {
    final uri = idOrUri.startsWith('spotify:playlist:')
        ? idOrUri
        : 'spotify:playlist:$idOrUri';
    final pl = _playlistsByUri[uri];
    if (pl == null) return null;
    final tracks = _playlistTracks[uri] ?? pl.tracks;
    return pl.copyWith(tracks: List.unmodifiable(tracks), totalTracks: tracks.length);
  }

  @override
  Future<List<SpotifyTrack>> fetchLikedTracks() async =>
      isSignedIn ? List.unmodifiable(likedTracks) : const [];

  @override
  Future<List<SpotifyPlaylist>> fetchPlaylists() async => isSignedIn
      ? [
          for (final pl in _playlistsByUri.values)
            pl.copyWith(
              tracks: List.unmodifiable(_playlistTracks[pl.uri] ?? pl.tracks),
              totalTracks: (_playlistTracks[pl.uri] ?? pl.tracks).length,
            ),
        ]
      : const [];

  @override
  Future<List<SpotifyAlbum>> fetchAlbums() async =>
      isSignedIn ? List.unmodifiable(albums) : const [];

  @override
  Future<List<SpotifyArtist>> fetchArtists() async =>
      isSignedIn ? List.unmodifiable(artists) : const [];

  @override
  Future<void> setTrackLiked(SpotifyTrack track, bool liked) async {
    likedTracks.removeWhere((t) => t.id == track.id);
    if (liked) likedTracks.insert(0, track);
  }

  @override
  Future<void> setAlbumSaved(SpotifyAlbum album, bool saved) async {
    albums.removeWhere((a) => a.id == album.id);
    if (saved) albums.insert(0, album);
  }

  @override
  Future<void> setArtistFollowed(SpotifyArtist artist, bool followed) async {
    artists.removeWhere((a) => a.id == artist.id);
    if (followed) artists.insert(0, artist);
  }

  @override
  Future<List<EditablePlaylist>> fetchEditablePlaylists(SpotifyTrack track) async {
    final editableIds = const {
      'spotify:playlist:mock_pl_account_1',
      'spotify:playlist:mock_pl_account_2',
      'spotify:playlist:mock_pl_account_3',
    };
    return [
      for (final uri in editableIds)
        if (_playlistsByUri[uri] case final pl?)
          EditablePlaylist(
            uri: pl.uri,
            name: pl.name,
            coverUrl: pl.coverUrl,
            containsTrack: (_playlistTracks[uri] ?? const []).any(
              (t) => t.id == track.id || (track.uri.isNotEmpty && t.uri == track.uri),
            ),
          ),
    ];
  }

  @override
  Future<void> addTrackToPlaylist(String playlistUri, SpotifyTrack track) async {
    final list = _playlistTracks[playlistUri];
    final pl = _playlistsByUri[playlistUri];
    if (list == null || pl == null) {
      throw const LibrarySourceException('歌单不存在');
    }
    list.add(track);
    _playlistsByUri[playlistUri] = pl.copyWith(
      tracks: List.unmodifiable(list),
      totalTracks: list.length,
    );
  }
}

/// 内存态 Spotify Connect 服务：零长连接，提供多设备列表与即时状态控制。
class MockConnectService implements ConnectService {
  final MockCatalog catalog;
  final _clusters = StreamController<ConnectCluster>.broadcast();
  final _statusChanges = StreamController<ConnectStatus>.broadcast();

  ConnectCluster _current;
  ConnectStatus _status = ConnectStatus.online;
  bool _disposed = false;

  MockConnectService(this.catalog)
    : _current = ConnectCluster(
        activeDeviceId: '',
        devices: catalog.connectDevices(),
        player: ConnectPlayerState.idle,
        serverTimestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  @override
  Duration get confirmationTimeout => const Duration(milliseconds: 200);

  @override
  Stream<ConnectCluster> get clusters => _clusters.stream;

  @override
  ConnectCluster get current => _current;

  @override
  Stream<ConnectStatus> get statusChanges => _statusChanges.stream;

  @override
  ConnectStatus get status => _status;

  @override
  String get observerId => 'hobs_mockobserver0000000000000000000';

  @override
  int get serverNowMs => DateTime.now().millisecondsSinceEpoch;

  void _emit(ConnectCluster cluster) {
    if (_disposed) return;
    _current = cluster;
    _clusters.add(cluster);
  }

  @override
  Future<void> start() async {
    _status = ConnectStatus.online;
    if (!_disposed) _statusChanges.add(_status);
    _emit(_current);
  }

  @override
  Future<void> stop() async {
    _status = ConnectStatus.idle;
    if (!_disposed) _statusChanges.add(_status);
    _emit(ConnectCluster.empty);
  }

  @override
  Future<void> refresh() async => _emit(_current);

  @override
  Future<void> transfer(
    String toDeviceId, {
    bool play = true,
    bool confirm = false,
  }) async {
    final track = catalog.coreTracks.first;
    _emit(
      ConnectCluster(
        activeDeviceId: toDeviceId,
        devices: _current.devices,
        player: ConnectPlayerState(
          trackUri: track.uri,
          title: track.name,
          albumTitle: track.album?.name ?? '',
          albumUri: track.album?.uri ?? '',
          artistUri: track.artists.isNotEmpty ? track.artists.first.uri : '',
          imageUrl: track.coverUrl,
          contextUri: _current.player.contextUri,
          isPlaying: play,
          isPaused: !play,
          positionMs: 12000,
          timestampMs: serverNowMs,
          durationMs: track.durationMs,
        ),
        serverTimestampMs: serverNowMs,
      ),
    );
  }

  @override
  Future<void> play(
    String deviceId, {
    String contextUri = '',
    List<String> trackUris = const [],
    String? trackUri,
    int? trackIndex,
    int? seekToMs,
    bool paused = false,
    bool? repeatingContext,
    bool? repeatingTrack,
    bool confirm = false,
  }) async {
    final targetUri =
        trackUri ??
        (trackUris.isNotEmpty ? trackUris[trackIndex ?? 0] : catalog.coreTracks.first.uri);
    final track = catalog.findTrackByIdOrUri(targetUri) ?? catalog.coreTracks.first;
    _emit(
      ConnectCluster(
        activeDeviceId: deviceId,
        devices: _current.devices,
        player: ConnectPlayerState(
          trackUri: track.uri,
          title: track.name,
          albumTitle: track.album?.name ?? '',
          albumUri: track.album?.uri ?? '',
          artistUri: track.artists.isNotEmpty ? track.artists.first.uri : '',
          imageUrl: track.coverUrl,
          contextUri: contextUri,
          isPlaying: !paused,
          isPaused: paused,
          positionMs: seekToMs ?? 0,
          timestampMs: serverNowMs,
          durationMs: track.durationMs,
          repeatContext: repeatingContext ?? _current.player.repeatContext,
          repeatTrack: repeatingTrack ?? _current.player.repeatTrack,
        ),
        serverTimestampMs: serverNowMs,
      ),
    );
  }

  @override
  Future<void> pause(String deviceId) async => _emit(
    ConnectCluster(
      activeDeviceId: _current.activeDeviceId,
      devices: _current.devices,
      player: ConnectPlayerState(
        trackUri: _current.player.trackUri,
        title: _current.player.title,
        albumTitle: _current.player.albumTitle,
        albumUri: _current.player.albumUri,
        artistUri: _current.player.artistUri,
        imageUrl: _current.player.imageUrl,
        contextUri: _current.player.contextUri,
        isPlaying: _current.player.isPlaying,
        isPaused: true,
        positionMs: _current.player.positionMs,
        timestampMs: serverNowMs,
        durationMs: _current.player.durationMs,
      ),
      serverTimestampMs: serverNowMs,
    ),
  );

  @override
  Future<void> resume(String deviceId) async => _emit(
    ConnectCluster(
      activeDeviceId: _current.activeDeviceId,
      devices: _current.devices,
      player: ConnectPlayerState(
        trackUri: _current.player.trackUri,
        title: _current.player.title,
        albumTitle: _current.player.albumTitle,
        albumUri: _current.player.albumUri,
        artistUri: _current.player.artistUri,
        imageUrl: _current.player.imageUrl,
        contextUri: _current.player.contextUri,
        isPlaying: true,
        isPaused: false,
        positionMs: _current.player.positionMs,
        timestampMs: serverNowMs,
        durationMs: _current.player.durationMs,
      ),
      serverTimestampMs: serverNowMs,
    ),
  );

  @override
  Future<void> skipNext(String deviceId) async {}

  @override
  Future<void> skipPrevious(String deviceId) async {}

  @override
  Future<void> seekTo(String deviceId, int positionMs) async {}

  @override
  Future<void> setShuffle(String deviceId, bool value) async {}

  @override
  Future<void> setRepeat(
    String deviceId, {
    required bool context,
    required bool track,
  }) async {}

  @override
  Future<void> setVolume(String deviceId, double volume) async {
    final updated = [
      for (final d in _current.devices)
        d.id == deviceId
            ? ConnectDevice(
                id: d.id,
                name: d.name,
                type: d.type,
                volume: volume.clamp(0.0, 1.0),
                volumeSteps: d.volumeSteps,
                canPlay: d.canPlay,
                isControllable: d.isControllable,
                isSameNetwork: d.isSameNetwork,
              )
            : d,
    ];
    _emit(
      ConnectCluster(
        activeDeviceId: _current.activeDeviceId,
        devices: updated,
        player: _current.player,
        serverTimestampMs: serverNowMs,
      ),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clusters.close();
    _statusChanges.close();
  }
}

class _MockCanvasService extends CanvasService {
  _MockCanvasService(super.client) : super(headers: () async => const {});

  @override
  Future<CanvasMedia?> get(String uri) async => null;
}

/// Mock 鉴权服务：无条件返回有效 Mock 令牌与个人资料，支持免登录与登出测试。
class MockSpotifyAuthService implements SpotifyAuthService {
  final StorageService _storage;

  MockSpotifyAuthService(this._storage);

  @override
  final ValueNotifier<bool> sessionExpired = ValueNotifier(false);

  @override
  bool get isLoggedIn => _storage.isLoggedIn;

  @override
  ValueListenable<int> get sessionInvalidated => _storage.sessionInvalidated;

  @override
  String get username => _storage.username;

  @override
  String get displayName => _storage.displayName.isNotEmpty
      ? _storage.displayName
      : _storage.username;

  @override
  String get avatarUrl => _storage.avatarUrl;

  @override
  Map<String, String> get clientHeaders => isLoggedIn
      ? const {'user-agent': 'Flutify-Mock/1.0'}
      : const {};

  @override
  DateTime? get accessTokenExpiry => DateTime.now().add(const Duration(days: 7));

  @override
  bool get needsProfile => false;

  @override
  Future<String> ensureClientToken() async => 'mock-client-token';

  @override
  Future<String> ensureAccessToken() async => 'mock-access-token';

  @override
  Future<String> refreshAccessToken() async => 'mock-access-token';

  @override
  Future<void> completeWebSignIn() async {
    await _storage.markDesktopSession();
    await _storage.setAccessToken('mock-access-token');
    await _storage.setRefreshToken('mock-refresh-token');
  }

  @override
  Future<void> ensureProfile() async {}

  @override
  Future<void> settle() async {}

  @override
  Future<void> logout() async {
    await _storage.clearLogin();
  }
}

/// 全功能离线 Mock API 服务。
class MockSpotifyApiService extends SpotifyApiService {
  final MockCatalog catalog;
  final StorageService _mockStorage;
  SpotifyAuthService? _mockAuth;
  late final MockLibrarySource _librarySource = MockLibrarySource(
    catalog,
    isSignedIn: () => _mockAuth?.isLoggedIn ?? _mockStorage.isLoggedIn,
  );
  late final MockConnectService _connectService = MockConnectService(catalog);
  late final _MockCanvasService _canvasService = _MockCanvasService(
    MockOfflineHttpClient(),
  );

  MockSpotifyApiService(this._mockStorage, this.catalog)
    : super(_mockStorage, MockOfflineHttpClient());

  @override
  CanvasService get canvas => _canvasService;

  @override
  ConnectService get connect => _connectService;

  @override
  LibrarySource get library => _librarySource;

  @override
  void attachAuth(SpotifyAuthService auth) {
    _mockAuth = auth;
    super.attachAuth(auth);
  }

  @override
  bool get isConfigured => _mockStorage.accessToken.isNotEmpty;

  @override
  bool get supportsConnect => isConfigured;

  @override
  Future<SpotifyUser> getCurrentUser() async => catalog.currentUser;

  @override
  Future<HomeFeed> getHome({String facet = ''}) async =>
      catalog.buildHome(facet: facet);

  @override
  Future<HomeSection> getHomeSection(String uri, {String facet = ''}) async =>
      catalog.buildHomeSection(uri);

  @override
  Future<List<SpotifyCategory>> getCategories() async => catalog.categories;

  @override
  Future<List<HomeSection>> getBrowsePage(String idOrUri) async => [
    catalog.buildHomeSection('spotify:section:browse_$idOrUri'),
  ];

  @override
  Future<SpotifyPlaylist> getPlaylist(String id) async {
    final found = _librarySource.findPlaylistByIdOrUri(id);
    if (found != null) return found;
    return catalog.playlists.first.copyWith(id: id, uri: 'spotify:playlist:$id');
  }

  @override
  Future<SpotifyAlbum> getAlbum(String id) async => catalog.albums.firstWhere(
    (a) => a.id == id || a.uri == id,
    orElse: () => catalog.jayDiscography.firstWhere(
      (a) => a.id == id,
      orElse: () => catalog.albums.first,
    ),
  );

  @override
  Future<SpotifyArtist> getArtist(String id) async => catalog.artists.firstWhere(
    (a) => a.id == id || a.uri == id,
    orElse: () => catalog.artists.first,
  );

  @override
  Future<List<SpotifyTrack>> getAlbumTracks(SpotifyAlbum album) async {
    if (album.id == catalog.albums[2].id) {
      return catalog.deluxeAlbumTracks;
    }
    return [
      for (final t in catalog.coreTracks)
        if (t.album?.id == album.id) t,
      if (album.id != catalog.albums[0].id) ...catalog.coreTracks.take(6),
    ];
  }

  @override
  Future<CatalogPage<SpotifyTrack>> getAlbumTracksPage(
    SpotifyAlbum album, {
    int offset = 0,
    int limit = 50,
  }) async {
    final all = album.id == catalog.albums[2].id
        ? catalog.deluxeAlbumTracks
        : await getAlbumTracks(album);
    final safeStart = offset.clamp(0, all.length);
    final safeEnd = min(all.length, safeStart + limit);
    final slice = all.sublist(safeStart, safeEnd);
    return CatalogPage<SpotifyTrack>.fromSlice(
      items: slice,
      offset: safeStart,
      limit: limit,
      rawCount: slice.length,
      total: all.length,
    );
  }

  @override
  Future<List<SpotifyTrack>> getArtistTopTracks(String id) async {
    final matching = [
      for (final t in catalog.coreTracks)
        if (t.artists.any((a) => a.id == id)) t,
    ];
    return matching.isNotEmpty ? matching : catalog.coreTracks.take(8).toList();
  }

  @override
  Future<TrackCredits> getTrackCredits(String trackId) async {
    final track =
        catalog.findTrackByIdOrUri(trackId) ?? catalog.coreTracks.first;
    return catalog.creditsFor(track);
  }

  @override
  Future<SpotifyPlaylist> getSongRadio(SpotifyTrack track) async =>
      SpotifyPlaylist(
        id: 'mock_radio_${track.id}',
        name: '${track.name} 歌曲电台',
        uri: 'spotify:playlist:mock_radio_${track.id}',
        description: '基于 ${track.name} 生成的 Mock 相似推荐',
        ownerName: 'Flutify Radio',
        images: catalog.playlists.last.images,
        tracks: catalog.coreTracks.take(10).toList(),
        totalTracks: 10,
      );

  @override
  Future<List<SpotifyTrack>> getTracksByUris(List<String> uris) async => [
    for (final uri in uris)
      catalog.findTrackByIdOrUri(uri) ?? catalog.coreTracks.first,
  ];

  @override
  Future<SpotifyTrack> getTrack(String id) async =>
      catalog.findTrackByIdOrUri(id) ?? catalog.coreTracks.first;

  @override
  Future<SpotifyTrack?> getTrackByUri(String uri) async =>
      catalog.findTrackByIdOrUri(uri) ?? catalog.coreTracks.first;

  @override
  Future<List<SpotifyAlbum>> getArtistAlbums(String id) async =>
      id == catalog.artists[0].id
      ? catalog.jayDiscography.take(10).toList()
      : catalog.albums;

  @override
  Future<CatalogPage<SpotifyAlbum>> getArtistAlbumsPage(
    String id, {
    int offset = 0,
    int limit = 20,
  }) async {
    final all = id == catalog.artists[0].id
        ? catalog.jayDiscography
        : catalog.albums;
    final safeStart = offset.clamp(0, all.length);
    final safeEnd = min(all.length, safeStart + limit);
    final slice = all.sublist(safeStart, safeEnd);
    return CatalogPage<SpotifyAlbum>.fromSlice(
      items: slice,
      offset: safeStart,
      limit: limit,
      rawCount: slice.length,
      total: all.length,
    );
  }

  @override
  Future<ArtistTracksPage> getArtistTracksPage(
    String artistId, {
    ArtistTracksCursor? cursor,
    int limit = 50,
  }) async {
    final all = [
      ...catalog.coreTracks,
      ...catalog.deluxeAlbumTracks.take(25),
    ];
    final offset = cursor?.trackOffset ?? 0;
    final pageLimit = min(limit, 15);
    final safeStart = offset.clamp(0, all.length);
    final safeEnd = min(all.length, safeStart + pageLimit);
    final slice = all.sublist(safeStart, safeEnd);
    return ArtistTracksPage(
      items: slice,
      nextCursor: safeEnd < all.length
          ? ArtistTracksCursor(artistId: artistId, trackOffset: safeEnd)
          : null,
    );
  }

  @override
  Future<PodcastShow> getPodcastShow(String id) async => catalog.podcastShow;

  @override
  Future<PodcastEpisode> getPodcastEpisode(String id) async =>
      catalog.episodes.firstWhere(
        (e) => e.id == id || e.uri == id,
        orElse: () => catalog.episodes.first,
      );

  @override
  Future<Map<String, List<dynamic>>> search(String query) async {
    final page = await searchPage(query, limit: 10);
    return {
      'tracks': page.tracks.items,
      'artists': page.artists.items,
      'playlists': page.playlists.items,
    };
  }

  @override
  Future<SearchPage> searchPage(
    String query, {
    int offset = 0,
    int limit = 20,
    String? type,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const SearchPage();

    final allTracks = [...catalog.coreTracks, ...catalog.deluxeAlbumTracks];
    final matchedTracks = [
      for (final t in allTracks)
        if (q == 'mock' ||
            q == '晴' ||
            t.name.toLowerCase().contains(q) ||
            t.artistNames.toLowerCase().contains(q))
          t,
    ];
    final trackSource = matchedTracks.isNotEmpty
        ? matchedTracks
        : catalog.coreTracks;
    final matchedArtists = [
      for (final a in catalog.artists)
        if (q == 'mock' || a.name.toLowerCase().contains(q)) a,
    ];
    final matchedPlaylists = [
      for (final pl in catalog.playlists)
        if (q == 'mock' || pl.name.toLowerCase().contains(q)) pl,
    ];

    CatalogPage<T> slice<T>(List<T> items) {
      final start = offset.clamp(0, items.length);
      final end = min(items.length, start + limit);
      final pageItems = items.sublist(start, end);
      return CatalogPage<T>.fromSlice(
        items: pageItems,
        offset: start,
        limit: limit,
        rawCount: pageItems.length,
        total: items.length,
      );
    }

    return SearchPage(
      tracks: (type == null || type == 'all' || type == 'tracks')
          ? slice(trackSource)
          : const CatalogPage(items: []),
      artists: (type == null || type == 'all' || type == 'artists')
          ? slice(matchedArtists)
          : const CatalogPage(items: []),
      playlists: (type == null || type == 'all' || type == 'playlists')
          ? slice(matchedPlaylists)
          : const CatalogPage(items: []),
    );
  }

  @override
  Future<List<SpotifyDevice>> getDevices() async => catalog.webDevices();

  @override
  Future<SpotifyLyrics> getLyrics(String trackId) async {
    final track =
        catalog.findTrackByIdOrUri(trackId) ?? catalog.coreTracks.first;
    return catalog.lyricsFor(track);
  }
}

class _MockUpdateInstaller implements UpdateInstaller {
  final Directory root;
  _MockUpdateInstaller(this.root);

  @override
  Future<Directory> downloadDirectory() async =>
      Directory(p.join(root.path, 'mock_updates'));

  @override
  Future<bool> install(File package, String checksum) async => false;

  @override
  Future<UpdateTarget> target() async => UpdateTarget(
    Platform.isAndroid
        ? UpdatePlatform.android
        : Platform.isWindows
        ? UpdatePlatform.windowsPortable
        : UpdatePlatform.unsupported,
    Platform.isAndroid ? 'x86_64' : 'x64',
  );
}

/// 组装 Mock 模式所需的全部离线服务与隔离存储。
class MockBootstrap {
  final MockCoverServer coverServer;
  final MockCatalog catalog;
  final Directory tempDir;
  final StorageService storageService;
  final AudioEngine audioEngine;
  final EmePlayer emePlayer;
  final MockSpotifyApiService spotifyApiService;
  final MockSpotifyAuthService authService;
  final TrackAudioSource trackAudioLoader;
  final PlaybackSessionStore playbackSessionStore;
  final CacheLocation audioCacheLocation;
  final ArtworkCache artworkCache;
  final LyricsResolver lyricsResolver;
  final PlaybackRegionGate playbackRegionGate;
  final UpdateService updateService;
  final AudioOutputBackend audioOutputBackend;

  MockBootstrap._({
    required this.coverServer,
    required this.catalog,
    required this.tempDir,
    required this.storageService,
    required this.audioEngine,
    required this.emePlayer,
    required this.spotifyApiService,
    required this.authService,
    required this.trackAudioLoader,
    required this.playbackSessionStore,
    required this.audioCacheLocation,
    required this.artworkCache,
    required this.lyricsResolver,
    required this.playbackRegionGate,
    required this.updateService,
    required this.audioOutputBackend,
  });

  static Future<MockBootstrap> create() async {
    final server = MockCoverServer();
    await server.start();
    final catalog = MockCatalog(server);
    final tempDir = await Directory.systemTemp.createTemp('flutify_mock_');

    final farFutureMs = DateTime.now()
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch;
    final storage = StorageService.ephemeral({
      'sp_auth_method': 'desktop',
      'sp_refresh_token': 'mock-refresh-token',
      'sp_access_token': 'mock-access-token',
      'sp_access_token_expiry': farFutureMs,
      'sp_client_token': 'mock-client-token',
      'sp_client_token_expiry': farFutureMs,
      'sp_client_token_profile': 'web',
      'sp_dc': 'mock-sp-dc',
      'sp_web_access_token': 'mock-web-access-token',
      'sp_web_access_token_expiry': farFutureMs,
      'sp_username': catalog.currentUser.id,
      'sp_display_name': catalog.currentUser.displayName,
      'sp_email': catalog.currentUser.email,
      'sp_avatar_url': catalog.currentUser.avatarUrl,
      'sp_device_id': 'mock_device_id_flutify_selftest_0001',
    });

    final cacheLocation = CacheLocation(
      storage,
      tempDir.path,
      legacyArtworkDirectory: p.join(tempDir.path, 'legacy_artwork'),
    );
    await cacheLocation.initialize();
    final artworkCache = ArtworkCache(cacheLocation);
    CachedNetworkImageProvider.defaultCacheManager = artworkCache;

    final api = MockSpotifyApiService(storage, catalog);
    final auth = MockSpotifyAuthService(storage);
    api.attachAuth(auth);

    final trackLoader = MockTrackAudioSource(catalog);
    final sessionStore = FilePlaybackSessionStore(
      File(p.join(tempDir.path, 'mock_playback_session.json')),
    );
    final lyricsResolver = LyricsResolver(
      api.getLyrics,
      fallbackEnabled: () => true,
      translationEnabled: () => true,
    );
    final regionGate = PlaybackRegionGate(enabled: () => false);
    final updateService = UpdateService(
      storage: storage,
      installer: _MockUpdateInstaller(tempDir),
      client: MockOfflineHttpClient(),
      currentTag: AppInfo.releaseTag,
    );

    return MockBootstrap._(
      coverServer: server,
      catalog: catalog,
      tempDir: tempDir,
      storageService: storage,
      audioEngine: MockAudioEngine(),
      emePlayer: EmePlayer(),
      spotifyApiService: api,
      authService: auth,
      trackAudioLoader: trackLoader,
      playbackSessionStore: sessionStore,
      audioCacheLocation: cacheLocation,
      artworkCache: artworkCache,
      lyricsResolver: lyricsResolver,
      playbackRegionGate: regionGate,
      updateService: updateService,
      audioOutputBackend: MockAudioOutputBackend(),
    );
  }
}
