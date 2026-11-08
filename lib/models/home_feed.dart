import 'album.dart';
import 'artist.dart';
import 'image.dart';
import 'playlist.dart';

/// 主页数据（与官方客户端同源的 Pathfinder `home` 查询，按分区还原）。
///
/// 结构与官方桌面端一致：
/// - [chips]：顶部筛选标签（音乐 / 播客…），选中后带 facet 重新请求；
/// - [shortcuts]：顶部快捷入口网格（最多 8 个，含「已点赞的歌曲」）；
/// - [sections]：自上而下的分区（卡架 / 最近播放 / 推荐流）。
class HomeFeed {
  /// 服务端按时区给出的问候语（如「早上好」）；为空时由界面按本地时间生成。
  final String greeting;
  final List<HomeChip> chips;
  final List<HomeItem> shortcuts;
  final List<HomeSection> sections;

  const HomeFeed({
    this.greeting = '',
    this.chips = const [],
    this.shortcuts = const [],
    this.sections = const [],
  });

  static const HomeFeed empty = HomeFeed();

  bool get isEmpty => shortcuts.isEmpty && sections.isEmpty;
}

/// 筛选标签；选中后可能出现二级标签 [subChips]（如「音乐」下的细分）。
class HomeChip {
  /// 作为 home 查询的 facet 参数，如 `music-chip`。
  final String id;
  final String label;
  final List<HomeChip> subChips;

  const HomeChip({
    required this.id,
    required this.label,
    this.subChips = const [],
  });
}

/// 分区的展示形态。
enum HomeSectionKind {
  /// 普通卡架（横向滚动的卡片）。
  shelf,

  /// 「最近播放」卡架。
  recents,

  /// 推荐流：官方桌面端把所有 FeedBaseline 分区合并为一个网格，每张卡上方标注推荐理由。
  feed,
}

class HomeSection {
  /// `spotify:section:...`；「显示全部」按它找回同一分区。
  final String uri;
  final HomeSectionKind kind;
  final String title;
  final String subtitle;

  /// 标题旁的艺人头像（如「与 Clean Bandit 相似」）。
  final SpotifyArtist? headerArtist;
  final List<HomeItem> items;

  /// 服务端该分区的条目总数（大于 [items] 时显示「显示全部」）。
  final int totalCount;

  const HomeSection({
    required this.uri,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.headerArtist,
    required this.items,
    this.totalCount = 0,
  });

  bool get hasMore => totalCount > items.length;
}

/// 主页条目的实体类型。
enum HomeItemKind { playlist, album, artist, likedSongs, podcast, episode }

/// 主页上的一个条目（卡片 / 快捷入口）。
///
/// 可打开的实体保留原始模型（[playlist] / [album] / [artist]），点击直接进入详情页；
/// 播客与单集只展示。
class HomeItem {
  final HomeItemKind kind;
  final String uri;
  final String title;
  final String subtitle;
  final List<SpotifyImage> images;

  /// 推荐流卡片上方的推荐理由（如「为你推荐」「与 Vicetone 相似」）。
  final String reason;

  /// 推荐理由旁的艺人头像。
  final SpotifyArtist? reasonArtist;

  final SpotifyPlaylist? playlist;
  final SpotifyAlbum? album;
  final SpotifyArtist? artist;

  /// 单集所属节目的 URI（`spotify:show:...`）；仅 [HomeItemKind.episode] 可能有值。
  final String parentUri;

  const HomeItem({
    required this.kind,
    required this.uri,
    required this.title,
    this.subtitle = '',
    this.images = const [],
    this.reason = '',
    this.reasonArtist,
    this.playlist,
    this.album,
    this.artist,
    this.parentUri = '',
  });

  String get imageUrl => images.isEmpty ? '' : images.first.url;

  bool get isCircular => kind == HomeItemKind.artist;

  /// App 内能打开详情页的类型（播客节目页已支持；单集打开所属节目）。
  bool get isOpenable => true;

  HomeItem withReason(String reason, SpotifyArtist? artist) => HomeItem(
    kind: kind,
    uri: uri,
    title: title,
    subtitle: subtitle,
    images: images,
    reason: reason,
    reasonArtist: artist,
    playlist: playlist,
    album: album,
    artist: this.artist,
    parentUri: parentUri,
  );
}
