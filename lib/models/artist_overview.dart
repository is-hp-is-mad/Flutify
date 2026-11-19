import 'album.dart';
import 'artist.dart';
import 'image.dart';

/// 艺人主页的附加信息（桌面版会话 `queryArtistOverview`）：头图、简介、月听众、
/// 最新发行、专辑 / 单曲分组与类似艺人。公开 Web API 没有这些字段，为空时各分区隐藏。
class ArtistOverview {
  final List<SpotifyImage> headerImages;
  final String biography;
  final int? monthlyListeners;
  final SpotifyAlbum? latestRelease;
  final List<SpotifyAlbum> albums;
  final List<SpotifyAlbum> singles;
  final List<SpotifyArtist> relatedArtists;

  const ArtistOverview({
    this.headerImages = const [],
    this.biography = '',
    this.monthlyListeners,
    this.latestRelease,
    this.albums = const [],
    this.singles = const [],
    this.relatedArtists = const [],
  });

  String get headerImageUrl => headerImages.isNotEmpty ? headerImages.first.url : '';
}
