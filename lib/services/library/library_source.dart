import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';

/// 媒体库（Your Library）的远端数据来源抽象。
///
/// LibraryProvider 只依赖它：真实实现按登录方式在桌面端内部接口（[DesktopLibrarySource]）
/// 与公开 Web API（[WebApiLibrarySource]）之间选择，测试用内存替身。
/// 四类数据独立读取，互不阻塞（某一类失败不影响其他类）。
abstract class LibrarySource {
  /// 当前是否已登录（未登录时各 fetch 方法返回空列表，不发请求）。
  bool get isSignedIn;

  /// 当前账号的用户名（canonical user id）；未登录为空。用来区分账号切换时的本地缓存。
  String get accountId;

  /// 已点赞的歌曲，最新点赞在前。
  Future<List<SpotifyTrack>> fetchLikedTracks();

  /// 用户歌单：自建 + 收藏（rootlist 顺序），不含「已点赞的歌曲」。
  Future<List<SpotifyPlaylist>> fetchPlaylists();

  /// 已收藏专辑，最新在前。
  Future<List<SpotifyAlbum>> fetchAlbums();

  /// 已关注艺人，最新在前。
  Future<List<SpotifyArtist>> fetchArtists();

  /// 点赞 / 取消点赞（写入失败抛 [LibrarySourceException]）。
  Future<void> setTrackLiked(SpotifyTrack track, bool liked);

  /// 收藏 / 取消收藏专辑。
  Future<void> setAlbumSaved(SpotifyAlbum album, bool saved);

  /// 关注 / 取消关注艺人。
  Future<void> setArtistFollowed(SpotifyArtist artist, bool followed);
}

/// 媒体库读写失败（网络、鉴权或接口返回非 2xx）。
class LibrarySourceException implements Exception {
  final String message;
  final int? statusCode;

  const LibrarySourceException(this.message, [this.statusCode]);

  @override
  String toString() => statusCode == null ? message : '$message（HTTP $statusCode）';
}
