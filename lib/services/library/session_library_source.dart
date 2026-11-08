import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import 'library_source.dart';

/// 按当前登录会话在两种媒体库实现之间切换的门面：
/// 桌面版 OAuth 会话走 [desktop]（内部接口），其余会话走 [web]（公开 Web API）。
/// 每次调用时才判断，因此登录 / 登出 / 换登录方式后无需重建。
class SessionLibrarySource implements LibrarySource {
  final LibrarySource desktop;
  final LibrarySource web;
  final bool Function() _useDesktop;

  SessionLibrarySource({required this.desktop, required this.web, required this._useDesktop});

  LibrarySource get _current => _useDesktop() ? desktop : web;

  @override
  bool get isSignedIn => _current.isSignedIn;

  @override
  String get accountId => _current.accountId;

  @override
  Future<List<SpotifyTrack>> fetchLikedTracks() => _current.fetchLikedTracks();

  @override
  Future<List<SpotifyPlaylist>> fetchPlaylists() => _current.fetchPlaylists();

  @override
  Future<List<SpotifyAlbum>> fetchAlbums() => _current.fetchAlbums();

  @override
  Future<List<SpotifyArtist>> fetchArtists() => _current.fetchArtists();

  @override
  Future<void> setTrackLiked(SpotifyTrack track, bool liked) => _current.setTrackLiked(track, liked);

  @override
  Future<void> setAlbumSaved(SpotifyAlbum album, bool saved) => _current.setAlbumSaved(album, saved);

  @override
  Future<void> setArtistFollowed(SpotifyArtist artist, bool followed) =>
      _current.setArtistFollowed(artist, followed);
}
