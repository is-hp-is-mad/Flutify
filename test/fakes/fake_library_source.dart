import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/editable_playlist.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/services/library/library_source.dart';

/// 内存版 [LibrarySource]：模拟账号媒体库，记录写入调用，并可注入读取 / 写入失败。
class FakeLibrarySource implements LibrarySource {
  @override
  bool isSignedIn;

  @override
  String accountId;

  List<SpotifyTrack> likedTracks;
  List<SpotifyPlaylist> playlists;
  List<SpotifyAlbum> albums;
  List<SpotifyArtist> artists;

  /// 设置后，对应类别的读取抛该异常。
  Object? likedError;
  Object? playlistsError;

  /// 设置后，写操作抛该异常。
  Object? writeError;

  /// 写入记录：`like:<id>` / `unlike:<id>` / `follow:<id>` 等（动作:曲目 / 专辑 / 艺人 id）。
  final List<String> writes = [];

  /// fetchLikedTracks 被调用的次数。
  int likedFetches = 0;

  FakeLibrarySource({
    this.isSignedIn = true,
    this.accountId = 'tester',
    this.likedTracks = const [],
    this.playlists = const [],
    this.albums = const [],
    this.artists = const [],
  });

  @override
  Future<List<SpotifyTrack>> fetchLikedTracks() async {
    likedFetches++;
    if (likedError != null) throw likedError!;
    return likedTracks;
  }

  @override
  Future<List<SpotifyPlaylist>> fetchPlaylists() async {
    if (playlistsError != null) throw playlistsError!;
    return playlists;
  }

  @override
  Future<List<SpotifyAlbum>> fetchAlbums() async => albums;

  @override
  Future<List<SpotifyArtist>> fetchArtists() async => artists;

  @override
  Future<void> setTrackLiked(SpotifyTrack track, bool liked) async {
    if (writeError != null) throw writeError!;
    writes.add('${liked ? 'like' : 'unlike'}:${track.id}');
  }

  @override
  Future<void> setAlbumSaved(SpotifyAlbum album, bool saved) async {
    if (writeError != null) throw writeError!;
    writes.add('${saved ? 'save' : 'unsave'}:${album.id}');
  }

  @override
  Future<void> setArtistFollowed(SpotifyArtist artist, bool followed) async {
    if (writeError != null) throw writeError!;
    writes.add('${followed ? 'follow' : 'unfollow'}:${artist.id}');
  }

  /// 账号里可编辑的歌单；设置 [editableError] 后读取抛该异常。
  List<EditablePlaylist> editable = const [];
  Object? editableError;

  @override
  Future<List<EditablePlaylist>> fetchEditablePlaylists(
    SpotifyTrack track,
  ) async {
    if (editableError != null) throw editableError!;
    return editable;
  }

  @override
  Future<void> addTrackToPlaylist(String playlistUri, SpotifyTrack track) async {
    if (writeError != null) throw writeError!;
    writes.add('add:$playlistUri:${track.id}');
  }
}
