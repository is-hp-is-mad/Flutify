import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/category.dart';
import 'package:flutify_app/models/device.dart';
import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/models/user_profile.dart';
import 'package:flutify_app/services/library/library_source.dart';
import 'package:flutify_app/services/spotify_api_service.dart';

/// UI 测试用的数据服务：媒体库、歌词与专辑曲目来自内存，其余方法沿用真实实现
/// （未登录时返回空列表 / 抛 [SpotifyDataException.notSignedIn]，不会发网络请求）。
///
/// 传入 [homeFeed] 时视为已登录：主页返回该数据，用户 / 分类 / 设备返回空值，同样不发网络请求。
class FakeSpotifyApiService extends SpotifyApiService {
  /// 为空时沿用真实的会话媒体库（未登录即为空）。
  final LibrarySource? librarySource;

  /// 曲目 id → 歌词。
  final Map<String, SpotifyLyrics> lyricsById;

  /// 专辑 id → 曲目。
  final Map<String, List<SpotifyTrack>> albumTracks;

  /// 歌单 id → 歌单（曲目含详情）。
  final Map<String, SpotifyPlaylist> playlists;

  /// 主页数据；非空时视为已登录。
  final HomeFeed? homeFeed;

  FakeSpotifyApiService(
    super.storage, {
    this.librarySource,
    this.lyricsById = const {},
    this.albumTracks = const {},
    this.playlists = const {},
    this.homeFeed,
  });

  bool get _signedIn => homeFeed != null;

  @override
  bool get isConfigured => _signedIn || super.isConfigured;

  @override
  LibrarySource get library => librarySource ?? super.library;

  @override
  Future<HomeFeed> getHome({String facet = ''}) async => homeFeed ?? await super.getHome(facet: facet);

  @override
  Future<SpotifyUser> getCurrentUser() async => _signedIn ? SpotifyUser.guest : await super.getCurrentUser();

  @override
  Future<List<SpotifyCategory>> getCategories() async => _signedIn ? const [] : await super.getCategories();

  @override
  Future<List<SpotifyDevice>> getDevices() async => _signedIn ? const [] : await super.getDevices();

  @override
  Future<SpotifyLyrics> getLyrics(String trackId) async => lyricsById[trackId] ?? const SpotifyLyrics();

  @override
  Future<List<SpotifyTrack>> getAlbumTracks(SpotifyAlbum album) async => albumTracks[album.id] ?? const [];

  @override
  Future<SpotifyPlaylist> getPlaylist(String id) async =>
      playlists[id] ?? await super.getPlaylist(id);
}
