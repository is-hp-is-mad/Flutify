import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/artist_artwork_scheme.dart';
import '../../../core/theme/flutify_tokens.dart';
import '../../../core/utils/artwork_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../l10n/app_locale.dart';
import '../../../l10n/l10n.dart';
import '../../../models/album.dart';
import '../../../models/artist.dart';
import '../../../models/artist_overview.dart';
import '../../../models/playback_context.dart';
import '../../../models/share_target.dart';
import '../../../models/track.dart';
import '../../../models/watch_feed.dart';
import '../../../providers/appearance_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/spotify_provider.dart';
import '../../../services/apple_music/apple_music_artist_service.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../shell/shell_chrome.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expressive_card.dart';
import '../watchfeed/widgets/watch_feed_entity_button.dart';
import '../watchfeed/widgets/watch_feed_shelf_row.dart';
import '../../widgets/flutify_progress.dart';
import '../../widgets/track_tile.dart';
import 'widgets/artist_hero.dart';
import 'widgets/artist_info_sheet.dart';
import 'widgets/collection_widgets.dart';

/// 艺人主页（复刻 Apple Music 7.0 艺人页布局与配色）：
///
/// - 整页背景色从艺人头图取色并按 `la.C5366a` 非线性压暗；
/// - 顶栏：左上返回键、右上毛玻璃胶囊（随机播放 + 分享）；
/// - 头图底部居中：艺人名 + `i`（艺人信息，含月听众 / 粉丝数 / 简介）+ 播放 + 星号关注；
/// - 最新发行卡片 + 热门歌曲（手机为四行一列的横向翻页网格，宽屏左右并排）；
/// - 专辑、单曲和 EP、粉丝也喜欢、关于（Spotify 数据，缺失的分区不显示）。
class ArtistDetailScreen extends StatefulWidget {
  final SpotifyArtist artist;

  const ArtistDetailScreen({super.key, required this.artist});

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  /// 热门歌曲：手机每列四首（Apple Music 的 swiping chart），宽屏左侧最新发行旁显示五首。
  static const int _rowsPerColumn = 4;
  static const int _maxTopTracks = 12;

  late Future<List<SpotifyTrack>> _topTracksFuture;
  late Future<List<SpotifyAlbum>> _albumsFuture;
  late Future<ArtistOverview> _overviewFuture;
  late SpotifyArtist _artist = widget.artist;

  /// Apple Music 动态视频：按「名字 + 是否宽屏 + 语言」请求一次。
  String? _appleKey;
  AppleMusicArtistMedia? _apple;
  Uint8List? _appleVideo;

  @override
  void initState() {
    super.initState();
    _load();
    // 官方「Explore 某艺人」入口（以热门第一首为种子）；推迟到首帧后，避免 build 期通知。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        context.read<SpotifyProvider?>()?.loadArtistSeedShelf(widget.artist.id),
      );
    });
  }

  /// 热门曲目与作品集失败时由数据层返回空列表；登录后调用本方法重新加载。
  void _load() {
    final api = context.read<SpotifyApiService>();
    _topTracksFuture = api.getArtistTopTracks(widget.artist.id);
    _albumsFuture = api.getArtistAlbums(widget.artist.id);
    _overviewFuture = api.getArtistOverview(widget.artist.id);
    if (_artist.images.isEmpty) unawaited(_fillArtist(api));
  }

  void _reload() {
    if (mounted) setState(_load);
  }

  /// 从曲目跳转过来的 simplified artist 没有头像与粉丝数，补全完整信息；失败时保留原样。
  Future<void> _fillArtist(SpotifyApiService api) async {
    try {
      final full = await api.getArtist(widget.artist.id);
      if (mounted && full.id == widget.artist.id) {
        setState(() => _artist = full);
      }
    } catch (_) {}
  }

  /// 先显示 Spotify 原图；只有可用视频下载完成后才叠加视频并启用对应配色。
  void _requestApple(bool enabled, bool wide) {
    final key = enabled && _artist.name.isNotEmpty
        ? '${_artist.name}|$wide|${AppLocale.spotifyLanguage}'
        : null;
    if (key == _appleKey) return;
    _appleKey = key;
    _apple = null;
    _appleVideo = null;
    if (key == null) return;
    final service = context.read<SpotifyApiService>().appleMusicArtist;
    unawaited(() async {
      final media = await service.find(
        _artist.name,
        language: AppLocale.spotifyLanguage,
        wide: wide,
      );
      if (!mounted ||
          key != _appleKey ||
          media == null ||
          media.videoUrl?.isNotEmpty != true) {
        return;
      }
      final video = await service.video(media);
      if (!mounted || key != _appleKey || video == null || video.isEmpty) {
        return;
      }
      setState(() {
        _apple = media;
        _appleVideo = video;
      });
    }());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final artist = _artist;
    final isFollowing = context.select<LibraryProvider, bool>(
      (l) => l.isFollowing(artist.id),
    );
    final appleEnabled = context.select<PreferencesProvider?, bool>(
      (p) => p?.prefs.appleMusicArtistMedia ?? true,
    );
    final increaseContrast = context.select<AppearanceProvider?, bool>(
      (p) => p?.settings.increaseContrast ?? false,
    );
    final width = MediaQuery.sizeOf(context).width;
    _requestApple(appleEnabled, width >= 600);
    final seedShelf = context.select<SpotifyProvider?, WatchFeedShelf?>(
      (p) => p?.seedShelfFor(widget.artist.id),
    );
    final playbackContext = PlaybackContext.artist(
      artist.name,
      uri: artist.contextUri,
    );
    final baseTheme = Theme.of(context);

    return FutureBuilder<ArtistOverview>(
      future: _overviewFuture,
      builder: (context, overviewSnap) {
        final overview = overviewSnap.data ?? const ArtistOverview();
        final apple = _apple;
        final heroUrl = overview.headerImageUrl.isNotEmpty
            ? overview.headerImageUrl
            : artist.avatarUrl;
        final appleBgColor = ArtistArtworkScheme.parseHexColor(apple?.bgColor);

        return _ArtistArtworkThemeBuilder(
          imageUrl: heroUrl.isNotEmpty ? heroUrl : artist.avatarUrl,
          appleBgColor: appleBgColor,
          increaseContrast: increaseContrast,
          builder: (context, scheme) {
            final artistTheme = scheme.toThemeData(baseTheme);
            return Theme(
              data: artistTheme,
              child: ShellBackdrop(
                color: scheme.backgroundColor,
                child: Scaffold(
                  backgroundColor: scheme.backgroundColor,
                  body: FutureBuilder<List<SpotifyTrack>>(
                    future: _topTracksFuture,
                    builder: (context, snapshot) {
                      final topTracks = snapshot.data ?? const <SpotifyTrack>[];
                      final loading =
                          snapshot.connectionState != ConnectionState.done;
                      return CustomScrollView(
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        slivers: [
                          ArtistHero(
                            name: artist.name,
                            imageUrl: heroUrl,
                            scheme: scheme,
                            video: _appleVideo,
                            tracks: topTracks,
                            playbackContext: playbackContext,
                            following: isFollowing,
                            onToggleFollow: () => context
                                .read<LibraryProvider>()
                                .toggleFollowArtist(artist),
                            onOpenInfo: (infoContext) => ArtistInfoSheet.show(
                              infoContext,
                              artist: artist,
                              overview: overview,
                              imageUrl: heroUrl,
                              scheme: scheme,
                            ),
                            shareTarget: ShareTarget.artist(artist),
                          ),
                          if (overview.latestRelease != null ||
                              topTracks.isNotEmpty ||
                              loading ||
                              snapshot.hasError)
                            SliverToBoxAdapter(
                              child: _TopSection(
                                artist: artist,
                                latest: overview.latestRelease,
                                topTracks: topTracks,
                                loading: loading,
                                failed: snapshot.hasError,
                                playbackContext: playbackContext,
                                scheme: scheme,
                                rowsPerColumn: _rowsPerColumn,
                                maxTracks: _maxTopTracks,
                                onRetry: _reload,
                              ),
                            )
                          else
                            SliverToBoxAdapter(
                              child: _SectionHeader(
                                title: l10n.artistPopular,
                                linkKey: const Key('artist-songs-link'),
                                onOpen: () => AppRoutes.openArtistSongs(
                                  context,
                                  artist,
                                  initialTracks: topTracks,
                                ),
                                trailing: WatchFeedEntityButton(
                                  feedUri:
                                      'spotify:watch-feed:artist:${artist.id}',
                                  name: artist.name,
                                ),
                              ),
                            ),
                          if (!loading &&
                              !snapshot.hasError &&
                              topTracks.isEmpty &&
                              overview.latestRelease == null)
                            _emptyTopTracks(context),
                          // 官方发现流入口（「Explore 某艺人」：本人歌曲 / 相似艺人 / 相似歌曲），无内容时不占位。
                          if (seedShelf != null)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: WatchFeedShelfRow(
                                  shelf: seedShelf,
                                  fallbackTitle: l10n.watchFeedDiscoverTitle,
                                  aspectRatio: 9 / 16,
                                  cardWidth: 120,
                                ),
                              ),
                            ),
                          SliverToBoxAdapter(
                            child: _AlbumsSection(
                              artist: artist,
                              overview: overview,
                              albumsFuture: _albumsFuture,
                              onRetry: _reload,
                            ),
                          ),
                          if (overview.singles.isNotEmpty)
                            SliverToBoxAdapter(
                              child: _AlbumShelf(
                                title: l10n.artistSingles,
                                albums: overview.singles,
                                onOpen: () =>
                                    AppRoutes.openArtistAlbums(context, artist),
                              ),
                            ),
                          if (overview.relatedArtists.isNotEmpty)
                            SliverToBoxAdapter(
                              child: _RelatedArtists(
                                artists: overview.relatedArtists,
                              ),
                            ),
                          if (overview.biography.isNotEmpty)
                            SliverToBoxAdapter(
                              child: _AboutSection(
                                artist: artist,
                                overview: overview,
                                imageUrl: heroUrl,
                                scheme: scheme,
                              ),
                            ),
                          const ContentBottomSpacer(),
                        ],
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _emptyTopTracks(BuildContext context) {
    final l10n = context.l10n;
    final api = context.read<SpotifyApiService>();
    if (!api.isConfigured) {
      return CollectionErrorPlaceholder(signedOut: true, onRetry: _reload);
    }
    return CollectionPlaceholder(message: l10n.artistNoPopular);
  }
}

/// 解析并平滑过渡艺人页配色（`m7.c.a.a`：250ms DecelerateInterpolator）：
/// 优先使用 Apple Music 目录接口自带的头图 `bgColor`，缺失时从当前头图 URL 本地提取背景原色。
class _ArtistArtworkThemeBuilder extends StatefulWidget {
  final String imageUrl;
  final Color? appleBgColor;
  final bool increaseContrast;
  final Widget Function(BuildContext context, ArtistArtworkScheme scheme)
  builder;

  const _ArtistArtworkThemeBuilder({
    required this.imageUrl,
    required this.appleBgColor,
    required this.increaseContrast,
    required this.builder,
  });

  @override
  State<_ArtistArtworkThemeBuilder> createState() =>
      _ArtistArtworkThemeBuilderState();
}

class _ArtistArtworkThemeBuilderState
    extends State<_ArtistArtworkThemeBuilder> {
  Color? _extracted;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_ArtistArtworkThemeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.appleBgColor != widget.appleBgColor) {
      _resolve();
    }
  }

  void _resolve() {
    if (widget.appleBgColor != null) return;
    final url = widget.imageUrl;
    if (url.isEmpty) {
      _extracted = null;
      return;
    }
    final cached = ArtworkPalette.cachedArtistColor(url);
    _extracted = cached;
    if (cached != null) return;
    ArtworkPalette.resolveArtistColor(url).then((color) {
      if (!mounted || widget.imageUrl != url || color == null) return;
      if (color != _extracted) setState(() => _extracted = color);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.increaseContrast) {
      return widget.builder(context, ArtistArtworkScheme.highContrast);
    }
    final targetSource =
        widget.appleBgColor ??
        _extracted ??
        ArtistArtworkScheme.defaultSourceColor;
    if (context.reduceMotion) {
      return widget.builder(context, ArtistArtworkScheme.from(targetSource));
    }
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: targetSource),
      duration: const Duration(milliseconds: 250),
      curve: Curves.decelerate,
      builder: (context, animatedColor, _) {
        final scheme = ArtistArtworkScheme.from(animatedColor ?? targetSource);
        return widget.builder(context, scheme);
      },
    );
  }
}

// -----------------------------------------------------------------------------
// 分区
// -----------------------------------------------------------------------------

/// Apple Music 的分区标题（`header_section_b`）：20sp 粗体 + 箭头，整行可点。
class _SectionHeader extends StatelessWidget {
  final String title;
  final Key? linkKey;
  final VoidCallback? onOpen;

  /// 标题行右侧的附加入口（如发现流缩略图按钮）。
  final Widget? trailing;

  const _SectionHeader({
    required this.title,
    this.linkKey,
    this.onOpen,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: 20,
      ),
    );
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 8, 4),
      child: onOpen == null
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Semantics(header: true, child: text),
            )
          : InkWell(
              key: linkKey,
              borderRadius: BorderRadius.circular(10),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    Flexible(child: Semantics(header: true, child: text)),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 26,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
    );
    if (trailing == null) return header;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: header),
        Padding(
          padding: const EdgeInsets.only(right: 10, bottom: 4),
          child: trailing,
        ),
      ],
    );
  }
}

/// 最新发行 + 热门歌曲（`latest_release_top_songs_model_group`）。
/// 宽屏左 0.4 / 右 0.6 并排；手机上下排列，最新发行为 Spotlight 圆角卡片，热门歌曲为每列四首的横向翻页网格。
class _TopSection extends StatelessWidget {
  final SpotifyArtist artist;
  final SpotifyAlbum? latest;
  final List<SpotifyTrack> topTracks;
  final bool loading;
  final bool failed;
  final PlaybackContext playbackContext;
  final ArtistArtworkScheme scheme;
  final int rowsPerColumn;
  final int maxTracks;
  final VoidCallback onRetry;

  const _TopSection({
    required this.artist,
    required this.latest,
    required this.topTracks,
    required this.loading,
    required this.failed,
    required this.playbackContext,
    required this.scheme,
    required this.rowsPerColumn,
    required this.maxTracks,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final header = _SectionHeader(
      title: l10n.artistPopular,
      linkKey: const Key('artist-songs-link'),
      onOpen: () =>
          AppRoutes.openArtistSongs(context, artist, initialTracks: topTracks),
      trailing: WatchFeedEntityButton(
        feedUri: 'spotify:watch-feed:artist:${artist.id}',
        name: artist.name,
      ),
    );
    final Widget songs;
    if (loading) {
      songs = const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: FlutifyLoadingIndicator()),
      );
    } else if (failed) {
      songs = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.detailLoadFailed,
        compact: true,
        actionLabel: l10n.commonRetry,
        onAction: onRetry,
      );
    } else if (topTracks.isEmpty) {
      songs = EmptyState(
        icon: Icons.music_note_rounded,
        title: l10n.artistNoPopular,
        compact: true,
      );
    } else {
      songs = _TopSongsGrid(
        tracks: topTracks.take(maxTracks).toList(),
        playbackContext: playbackContext,
        rows: rowsPerColumn,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 720 && latest != null) {
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionHeader(title: l10n.artistLatestRelease),
                      _LatestRelease(
                        album: latest!,
                        scheme: scheme,
                        large: true,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [header, songs],
                  ),
                ),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (latest != null)
              Semantics(
                label: l10n.artistLatestRelease,
                child: _LatestRelease(
                  album: latest!,
                  scheme: scheme,
                  large: false,
                ),
              ),
            header,
            songs,
          ],
        );
      },
    );
  }
}

/// 最新发行 Spotlight 圆角卡片（复刻参考图与 Apple Music 7.0 `Ub.C2563h`）：
/// 半透明着色卡片 + 封面 + 发行日期 / 名称 / 曲目数 + 右侧圆形收藏按钮。
class _LatestRelease extends StatelessWidget {
  final SpotifyAlbum album;
  final ArtistArtworkScheme scheme;
  final bool large;

  const _LatestRelease({
    required this.album,
    required this.scheme,
    required this.large,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isSaved = context.select<LibraryProvider, bool>(
      (l) => l.isAlbumSaved(album.id),
    );
    final cover = large ? 116.0 : 96.0;
    final date = album.releaseDate.isEmpty
        ? ''
        : Formatters.formatReleaseDate(l10n, album.releaseDate);
    final detail = album.totalTracks > 0
        ? l10n.songCount(album.totalTracks)
        : l10n.albumType(album);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, large ? 4 : 10, 16, 4),
      child: DecoratedBox(
        key: const Key('artist-latest-release-card'),
        decoration: BoxDecoration(
          color: scheme.spotlightCardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.spotlightBorderColor, width: 0.75),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => AppRoutes.openAlbum(context, album),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(48),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: CoverImage(
                      url: album.coverUrl,
                      size: cover,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (date.isNotEmpty)
                          Text(
                            date,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.86,
                              ),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        const SizedBox(height: 3),
                        Text(
                          album.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Tooltip(
                    message: isSaved ? l10n.libraryRemove : l10n.libraryAdd,
                    child: Material(
                      color: Colors.white.withValues(alpha: 0.14),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => context
                            .read<LibraryProvider>()
                            .toggleAlbumSaved(album),
                        child: SizedBox.square(
                          dimension: 32,
                          child: Icon(
                            isSaved ? Icons.check_rounded : Icons.add_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 热门歌曲横向翻页网格：每列 [rows] 首，列宽为可视宽度的 88%，露出下一列提示可滑动。
/// 只有一列时直接铺满宽度。
class _TopSongsGrid extends StatefulWidget {
  final List<SpotifyTrack> tracks;
  final PlaybackContext playbackContext;
  final int rows;

  const _TopSongsGrid({
    required this.tracks,
    required this.playbackContext,
    required this.rows,
  });

  @override
  State<_TopSongsGrid> createState() => _TopSongsGridState();
}

class _TopSongsGridState extends State<_TopSongsGrid> {
  PageController? _controller;
  double? _fraction;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  PageController _controllerFor(double fraction) {
    if (_controller == null || _fraction != fraction) {
      _controller?.dispose();
      _controller = PageController(viewportFraction: fraction);
      _fraction = fraction;
    }
    return _controller!;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    final rows = widget.rows;
    final columns = (tracks.length / rows).ceil();
    String? albumSubtitle(SpotifyTrack track) {
      final album = track.album;
      if (album == null || album.name.isEmpty) return null;
      return [
        album.name,
        if (album.releaseYear.isNotEmpty) album.releaseYear,
      ].join(' · ');
    }

    Widget column(int c) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = c * rows; i < (c + 1) * rows && i < tracks.length; i++)
          TrackTile(
            key: ValueKey(tracks[i].id),
            track: tracks[i],
            subtitle: albumSubtitle(tracks[i]),
            showCover: true,
            showLike: false,
            showDuration: false,
            showDivider: i != (c + 1) * rows - 1 && i != tracks.length - 1,
            contextQueue: tracks,
            playbackContext: widget.playbackContext,
          ),
      ],
    );
    if (columns <= 1) return column(0);
    return LayoutBuilder(
      builder: (context, box) {
        // 列高按实际行高测一次（受字号影响），避免 PageView 需要固定高度时裁掉内容
        final fraction = box.maxWidth >= 720 ? 0.5 : 0.88;
        return _MeasuredHeight(
          probe: column(0),
          builder: (height) => SizedBox(
            height: height,
            child: PageView.builder(
              controller: _controllerFor(fraction),
              padEnds: false,
              itemCount: columns,
              itemBuilder: (context, c) =>
                  Align(alignment: Alignment.topCenter, child: column(c)),
            ),
          ),
        );
      },
    );
  }
}

/// 先离屏布局 [probe] 得到高度，再交给 [builder]；高度变化（字号调整）时重新测量。
class _MeasuredHeight extends StatefulWidget {
  final Widget probe;
  final Widget Function(double height) builder;

  const _MeasuredHeight({required this.probe, required this.builder});

  @override
  State<_MeasuredHeight> createState() => _MeasuredHeightState();
}

class _MeasuredHeightState extends State<_MeasuredHeight> {
  double? _height;

  @override
  Widget build(BuildContext context) {
    final height = _height;
    return Stack(
      children: [
        if (height != null) widget.builder(height),
        Offstage(
          child: _SizeReporter(
            onSize: (size) {
              if (size.height != _height && mounted) {
                setState(() => _height = size.height);
              }
            },
            child: widget.probe,
          ),
        ),
      ],
    );
  }
}

class _SizeReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;

  const _SizeReporter({required this.onSize, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReporter renderObject,
  ) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  ValueChanged<Size> onSize;
  Size? _last;

  _RenderSizeReporter(this.onSize);

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onSize(size));
    }
  }
}

/// 专辑分区：桌面版会话用 overview 的专辑分组，否则用作品集预览（与原艺人页一致，带加载 / 重试）。
class _AlbumsSection extends StatelessWidget {
  final SpotifyArtist artist;
  final ArtistOverview overview;
  final Future<List<SpotifyAlbum>> albumsFuture;
  final VoidCallback onRetry;

  const _AlbumsSection({
    required this.artist,
    required this.overview,
    required this.albumsFuture,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    void open() => AppRoutes.openArtistAlbums(context, artist);
    if (overview.albums.isNotEmpty) {
      return _AlbumShelf(
        title: l10n.artistAlbums,
        albums: overview.albums,
        onOpen: open,
        linkKey: const Key('artist-albums-link'),
      );
    }
    return FutureBuilder<List<SpotifyAlbum>>(
      future: albumsFuture,
      builder: (context, snap) {
        final albums = snap.data ?? const <SpotifyAlbum>[];
        final header = _SectionHeader(
          title: l10n.artistDiscography,
          linkKey: const Key('artist-albums-link'),
          onOpen: open,
        );
        if (snap.connectionState != ConnectionState.done) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: FlutifyLoadingIndicator()),
              ),
            ],
          );
        }
        if (snap.hasError || albums.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              snap.hasError
                  ? EmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: l10n.detailLoadFailed,
                      compact: true,
                      actionLabel: l10n.commonRetry,
                      onAction: onRetry,
                    )
                  : EmptyState(
                      icon: Icons.album_outlined,
                      title: l10n.artistNoAlbums,
                      compact: true,
                    ),
            ],
          );
        }
        return _AlbumShelf(
          title: l10n.artistDiscography,
          albums: albums,
          onOpen: open,
          linkKey: const Key('artist-albums-link'),
        );
      },
    );
  }
}

/// 横向专辑卡架：标题 + 方形封面、名称、年份。
class _AlbumShelf extends StatelessWidget {
  final String title;
  final List<SpotifyAlbum> albums;
  final VoidCallback onOpen;
  final Key? linkKey;

  const _AlbumShelf({
    required this.title,
    required this.albums,
    required this.onOpen,
    this.linkKey,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title, linkKey: linkKey, onOpen: onOpen),
        SizedBox(
          height: ExpressiveCard.heightFor(context, 156),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: albums.length,
            itemBuilder: (context, i) => ExpressiveCard(
              width: 156,
              title: albums[i].name,
              subtitle: albums[i].releaseYear,
              imageUrl: albums[i].coverUrl,
              onTap: () => AppRoutes.openAlbum(context, albums[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 粉丝也喜欢：圆形头像卡架。
class _RelatedArtists extends StatelessWidget {
  final List<SpotifyArtist> artists;

  const _RelatedArtists({required this.artists});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: context.l10n.artistRelated),
        SizedBox(
          height: ExpressiveCard.heightFor(context, 132),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: artists.length,
            itemBuilder: (context, i) => ExpressiveCard(
              width: 132,
              isCircular: true,
              title: artists[i].name,
              imageUrl: artists[i].avatarUrl,
              onTap: () => AppRoutes.openArtist(context, artists[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 关于：照片卡片上叠简介前几行（Apple Music `artist_main_about`），点开以非线性动画弹出艺人信息页。
class _AboutSection extends StatelessWidget {
  final SpotifyArtist artist;
  final ArtistOverview overview;
  final String imageUrl;
  final ArtistArtworkScheme scheme;

  const _AboutSection({
    required this.artist,
    required this.overview,
    required this.imageUrl,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: context.l10n.artistAbout),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Builder(
            builder: (cardContext) => Material(
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(16),
              color: scheme.spotlightCardColor,
              child: InkWell(
                onTap: () => ArtistInfoSheet.show(
                  cardContext,
                  artist: artist,
                  overview: overview,
                  imageUrl: imageUrl,
                  scheme: scheme,
                ),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CoverImage(
                        url: imageUrl,
                        placeholderIcon: Icons.person_rounded,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.35, 1],
                            colors: [Color(0x00000000), Color(0xB3000000)],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 14,
                        child: Text(
                          overview.biography,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.white, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
