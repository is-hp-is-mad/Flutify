import 'dart:typed_data';

import 'album.dart';
import 'artist.dart';
import 'image.dart';
import 'track.dart';

/// 官方竖滑发现流（Watch Feed）的内存模型：全部由服务端组件解析而来，不做 JSON 序列化。
/// 协议与字段来源见 docs/DISCOVERY_FEED_ANALYSIS.md。

/// 入口卡片：搜索页「Discover something new」或「Explore 某艺人」里的一张竖版视频卡。
class WatchFeedEntry {
  /// 卡片标题，通常就是标签，如「#mellow indie」「Similar to Rick Astley」。
  final String title;
  final String subtitle;
  final String overline;

  /// 点击后进入的 feed，如 `spotify:watch-feed:discovery-feed:<id>?firstItemUris=…`。
  final String feedUri;

  /// feed 的首条曲目（进入后先播它）。
  final String firstItemUri;

  /// 视频首帧缩略图。
  final String thumbnailUrl;

  /// 卡片上静音循环的 Canvas 视频（可能为空）。
  final String videoUrl;

  /// 首条曲目的专辑封面（缩略图缺失时兜底）。
  final String coverUrl;

  final String accessibilityText;

  const WatchFeedEntry({
    required this.title,
    required this.feedUri,
    this.subtitle = '',
    this.overline = '',
    this.firstItemUri = '',
    this.thumbnailUrl = '',
    this.videoUrl = '',
    this.coverUrl = '',
    this.accessibilityText = '',
  });

  /// 卡片画面：优先视频首帧，其次封面。
  String get imageUrl => thumbnailUrl.isNotEmpty ? thumbnailUrl : coverUrl;
}

/// 一组入口卡片（一行横滑）。
class WatchFeedShelf {
  final String title;
  final List<WatchFeedEntry> entries;

  const WatchFeedShelf({required this.title, required this.entries});
}

/// 条目画面类型。
enum WatchFeedVisualKind {
  /// 官方 Canvas 竖版循环视频。
  canvas,

  /// 无视频：专辑封面卡 + 取色底 + 波形动画。
  trackPreview,

  /// 静态图片铺满。
  image,

  /// 纵向渐变。
  gradient,
}

/// 条目画面。
class WatchFeedVisual {
  final WatchFeedVisualKind kind;

  /// Canvas 视频地址（[WatchFeedVisualKind.canvas]）。
  final String videoUrl;

  /// 视频首帧 / 专辑封面 / 图片。
  final String imageUrl;

  /// 服务端下发的 Lottie 地址（TrackPreview 的波形动画），仅用来判断是否显示波形。
  final String animationUrl;

  /// 渐变色（#RRGGBB / #AARRGGBB）。
  final List<String> colors;

  const WatchFeedVisual({
    required this.kind,
    this.videoUrl = '',
    this.imageUrl = '',
    this.animationUrl = '',
    this.colors = const [],
  });
}

/// 条目试听音频（约 30 秒的副歌片段，公开 CDN 地址）。
class WatchFeedAudio {
  final String url;
  final bool shouldLoop;

  /// 是否 5 秒淡入（官方 increase_volume_gradually）。
  final bool fadeIn;

  const WatchFeedAudio({
    required this.url,
    this.shouldLoop = true,
    this.fadeIn = false,
  });
}

/// 艺人行：头像 + 名字 + 粉丝数 + 关注。
class WatchFeedCreator {
  final String uri;
  final String name;
  final String subtitle;
  final String imageUrl;

  /// 月度听众数（桌面版实体 feed 才有；spclient feed 用 [subtitle] 里的粉丝数）。
  final int? monthlyListeners;

  /// 关注目标（通常与 [uri] 相同）；为空时不显示关注按钮。
  final String followUri;
  final String followText;
  final String followingText;

  const WatchFeedCreator({
    required this.uri,
    required this.name,
    this.subtitle = '',
    this.imageUrl = '',
    this.monthlyListeners,
    this.followUri = '',
    this.followText = '',
    this.followingText = '',
  });

  String get artistId => uri.split(':').last;
}

/// #标签：点击进入该标签的 discovery feed。
class WatchFeedHashtag {
  final String id;
  final String title;
  final String navigationUri;
  final String seedItemUri;

  const WatchFeedHashtag({
    required this.id,
    required this.title,
    required this.navigationUri,
    this.seedItemUri = '',
  });
}

/// 曲目行（「播放完整歌曲」）：封面 + 歌名 + 艺人 + 保存按钮。
class WatchFeedEntityRow {
  final String title;
  final String subtitle;
  final String imageUrl;

  /// 点击播放的 uri（曲目）。
  final String playUri;

  final String accessibilityText;

  const WatchFeedEntityRow({
    required this.title,
    required this.playUri,
    this.subtitle = '',
    this.imageUrl = '',
    this.accessibilityText = '',
  });
}

/// feed 中的一条（一页竖滑卡片）。
class WatchFeedItem {
  /// 服务端条目 id（base64 的曲目 uri）。
  final String id;

  /// 条目对应的实体（通常是曲目 uri）。
  final String uri;

  final WatchFeedVisual visual;
  final WatchFeedAudio? audio;
  final WatchFeedCreator? creator;
  final List<WatchFeedHashtag> hashtags;
  final WatchFeedEntityRow? entityRow;

  /// 额外文字行（TextHeaderBody / StyledTextRow 的标题）。
  final List<String> texts;

  /// 曲目信息（来自曲目菜单组件），用于保存 / 菜单 / 播放完整歌曲。
  final SpotifyTrack? track;

  /// 封面深色取色（ARGB，桌面版弹窗背景）；null 时由界面自行从封面取色。
  final int? backgroundColor;

  /// 是否有分享按钮 / 菜单按钮 / 保存按钮 / 进度条（均由服务端决定）。
  final bool canShare;
  final bool hasMenu;
  final bool canSave;
  final bool hasProgressBar;

  const WatchFeedItem({
    required this.id,
    required this.uri,
    required this.visual,
    this.audio,
    this.creator,
    this.hashtags = const [],
    this.entityRow,
    this.texts = const [],
    this.track,
    this.backgroundColor,
    this.canShare = false,
    this.hasMenu = false,
    this.canSave = false,
    this.hasProgressBar = false,
  });

  /// 用于保存 / 播放的曲目：优先菜单组件给的完整信息，其次由曲目行拼一个最小曲目。
  SpotifyTrack? get playableTrack {
    if (track != null) return track;
    final row = entityRow;
    final uri = row?.playUri ?? this.uri;
    if (!uri.startsWith('spotify:track:')) return null;
    return SpotifyTrack(
      id: uri.split(':').last,
      uri: uri,
      name: row?.title ?? '',
      artists: [
        if (creator != null)
          SpotifyArtist(
            id: creator!.artistId,
            name: creator!.name,
            uri: creator!.uri,
          ),
      ],
      album: row == null || row.imageUrl.isEmpty
          ? null
          : SpotifyAlbum(
              id: '',
              name: '',
              images: [SpotifyImage(url: row.imageUrl)],
            ),
    );
  }
}

/// 实体 feed 的一页（Pathfinder watchFeedEntity，按 offset 分页）。
class WatchFeedEntityPage {
  final List<WatchFeedItem> items;
  final int totalCount;

  /// 下一页起点；null 表示没有更多。
  final int? nextOffset;

  const WatchFeedEntityPage({
    this.items = const [],
    this.totalCount = 0,
    this.nextOffset,
  });
}

/// 一页 feed（含分页、关联 feed、引导）。
class WatchFeedPage {
  /// 头部轮换标题（第 i 个对应第 i 个横向 feed），如「Similar to X」「#folk」。
  final List<String> headerTitles;

  final List<WatchFeedItem> items;

  /// 下一页令牌（原始字节）；为 null 表示没有更多。
  final Uint8List? nextPageToken;

  /// 可左右切换的关联 feed。
  final List<String> associatedFeedUris;

  /// 竖滑引导文案（如「Swipe up to see more」）；为空表示服务端没下发。
  final String verticalOnboardingText;

  /// 横滑引导文案（如「Swipe for more feeds」）。
  final String associatedOnboardingText;

  const WatchFeedPage({
    this.headerTitles = const [],
    this.items = const [],
    this.nextPageToken,
    this.associatedFeedUris = const [],
    this.verticalOnboardingText = '',
    this.associatedOnboardingText = '',
  });
}
