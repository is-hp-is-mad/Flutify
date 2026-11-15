import 'package:flutter/material.dart';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/category.dart';
import '../../models/home_feed.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../models/watch_feed.dart';
import '../screens/detail/album_detail_screen.dart';
import '../screens/detail/artist_detail_screen.dart';
import '../screens/detail/artist_catalog_screen.dart';
import '../screens/detail/playlist_detail_screen.dart';
import '../screens/detail/podcast_detail_screen.dart';
import '../screens/home/home_section_screen.dart';
import '../screens/search/category_screen.dart';
import '../screens/watchfeed/desktop/desktop_watch_feed.dart';
import '../screens/watchfeed/watch_feed_screen.dart';
import '../shell/desktop/desktop_window.dart';
import '../shell/shell_breakpoints.dart';

/// 详情页导航入口。
///
/// - 详情页压入「当前 Tab 的嵌套 Navigator」（由 MainShell 注册），播放器常驻可见。
/// - 从播放器中跳转时，关闭根级弹层及播放器页面，但保留内容区的返回历史，
///   与 Spotify 的「Go to album / Go to artist」行为一致。
class AppRoutes {
  AppRoutes._();

  // 播放器的 PageRoute 也是覆盖层，不能只按 PopupRoute 判断。
  static const fullPlayerRouteName = '/player';
  static const immersiveLyricsRouteName = '/immersive-lyrics';

  /// MainShell 注册：返回当前 Tab 的 NavigatorState。
  static NavigatorState? Function()? contentNavigator;

  /// MainShell 注册：当前 Tab 的后退 / 前进（顶栏 ‹ ›、快捷键与鼠标侧键共用）。
  static VoidCallback? navigateBack;
  static VoidCallback? navigateForward;

  static void openPlaylist(BuildContext context, SpotifyPlaylist playlist) =>
      _push(context, PlaylistDetailScreen(playlist: playlist));

  /// 专辑页；[focusTrack] 不为空时进入后滚动到该曲目并短暂高亮。
  static void openAlbum(
    BuildContext context,
    SpotifyAlbum album, {
    SpotifyTrack? focusTrack,
  }) => _push(context, AlbumDetailScreen(album: album, focusTrack: focusTrack));

  static void openArtist(BuildContext context, SpotifyArtist artist) =>
      _push(context, ArtistDetailScreen(artist: artist));

  static void openArtistAlbums(BuildContext context, SpotifyArtist artist) =>
      _push(
        context,
        ArtistCatalogScreen(artist: artist, kind: ArtistCatalogKind.albums),
      );

  static void openArtistSongs(
    BuildContext context,
    SpotifyArtist artist, {
    List<SpotifyTrack> initialTracks = const [],
  }) => _push(
    context,
    ArtistCatalogScreen(
      artist: artist,
      kind: ArtistCatalogKind.songs,
      initialTracks: initialTracks,
    ),
  );

  /// 官方竖滑发现流；[feedUri] 为 `spotify:watch-feed:…`，[title] 为入口卡片标题（加载前先显示）。
  ///
  /// 移动端与其他详情页一样推入 Tab 内容区，在它是当前页时由外壳隐藏底部导航与迷你播放栏
  /// （见 ShellChrome）；桌面端改为盖住整个窗口的模态层（对齐官方桌面网页版，见 DesktopWatchFeed）。
  static void openWatchFeed(
    BuildContext context,
    String feedUri, {
    String title = '',
    WatchFeedEntityPage? initialPage,
  }) {
    if (ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      DesktopWatchFeed.open(
        context,
        feedUri: feedUri,
        title: title,
        initialPage: initialPage,
      );
      return;
    }
    _push(context, WatchFeedScreen(feedUri: feedUri, title: title));
  }

  /// 播客节目页。[showUri] 为 `spotify:show:xxx`；[initialTitle] / [initialCover] 来自卡片，加载前先展示。
  static void openPodcast(
    BuildContext context,
    String showUri, {
    String initialTitle = '',
    String initialCover = '',
  }) => _push(
    context,
    PodcastDetailScreen(
      showId: showUri.startsWith('spotify:show:')
          ? showUri.substring(13)
          : showUri,
      initialTitle: initialTitle,
      initialCover: initialCover,
    ),
  );

  /// 主页分区的「显示全部」。
  static void openHomeSection(
    BuildContext context,
    HomeSection section, {
    String facet = '',
  }) => _push(context, HomeSectionScreen(section: section, facet: facet));

  /// 分类页（browsePage）。
  static void openCategory(BuildContext context, SpotifyCategory category) =>
      _push(context, CategoryScreen(category: category));

  static bool _isPlayerOverlay(Route<dynamic> route) =>
      !route.isFirst &&
      (route is PopupRoute ||
          route.settings.name == fullPlayerRouteName ||
          route.settings.name == immersiveLyricsRouteName);

  static Future<void> _push(BuildContext context, Widget page) async {
    // 先取出两个 Navigator：关闭弹层后 context 可能已失效
    final root = Navigator.of(context, rootNavigator: true);
    final target = contentNavigator?.call() ?? Navigator.of(context);
    Route<dynamic>? immersive;
    root.popUntil((route) {
      if (!route.isFirst && route.settings.name == immersiveLyricsRouteName) {
        immersive = route;
        return true;
      }
      return !_isPlayerOverlay(route);
    });
    if (immersive != null) {
      // 与沉浸式页面的关闭按钮一致：先移除玻璃模糊再淡出，保护桌面合成器。
      await DesktopWindow.dropGlassForExit();
      if (!root.mounted || !target.mounted || !immersive!.isCurrent) return;
      root.popUntil((route) => !_isPlayerOverlay(route));
    }
    // 根 Navigator 上仍有全屏页面（移动端的发现流、设置）：在它上方继续压栈，
    // 否则新页面会被推进 Tab 内容区、压在全屏页下面看不见；返回时也能回到全屏页。
    (root.canPop() ? root : target).push(
      MaterialPageRoute(builder: (_) => page),
    );
  }
}
