import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../l10n/l10n.dart';
import '../../../l10n/model_labels.dart';
import '../../../models/album.dart';
import '../../../models/playback_context.dart';
import '../../../models/share_target.dart';
import '../../../models/track.dart';
import '../../../providers/library_provider.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/expressive_card.dart';
import '../../widgets/share/share_button.dart';
import '../../widgets/track_tile.dart';
import '../watchfeed/widgets/watch_feed_entity_button.dart';
import 'widgets/collection_hero.dart';
import 'widgets/collection_widgets.dart';

/// 专辑详情页：曲目列表、收藏、发行信息与「More by 艺人」。
class AlbumDetailScreen extends StatefulWidget {
  final SpotifyAlbum album;

  /// 进入后定位的曲目（滚动到该行并短暂高亮）；为 null 时停在顶部。
  final SpotifyTrack? focusTrack;

  const AlbumDetailScreen({super.key, required this.album, this.focusTrack});

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  late Future<List<SpotifyTrack>> _tracksFuture;
  late Future<List<SpotifyAlbum>> _moreByArtistFuture;

  /// 当前展示的专辑：从发现流等处进入时只带 id / 名称 / 封面，补全后替换。
  late SpotifyAlbum _album = widget.album;

  /// 定位曲目那一行的 key；定位只做一次。
  final GlobalKey _focusKey = GlobalKey();
  bool _focusDone = false;

  /// 定位后的高亮：显示一会儿后淡出。
  bool _focusHighlight = false;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _load();
    if (_album.artists.isEmpty || _album.releaseDate.isEmpty) unawaited(_fillAlbum());
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  /// 曲目与「More by」失败时由数据层返回空列表；登录后调用本方法重新加载。
  void _load() {
    final api = context.read<SpotifyApiService>();
    _tracksFuture = api.getAlbumTracks(_album);
    _loadMoreBy(api);
  }

  void _loadMoreBy(SpotifyApiService api) {
    final album = _album;
    _moreByArtistFuture = album.artists.isEmpty
        ? Future.value(const [])
        : api
              .getArtistAlbums(album.artists.first.id)
              .then((albums) => albums.where((a) => a.id != album.id).toList());
  }

  /// 补全专辑信息（艺人、发行日期、类型）；失败时保留原样。曲目列表不重载，避免定位跳动。
  Future<void> _fillAlbum() async {
    final api = context.read<SpotifyApiService>();
    try {
      final full = await api.getAlbum(widget.album.id);
      if (!mounted || full.id != widget.album.id) return;
      setState(() {
        _album = full.images.isNotEmpty
            ? full
            : SpotifyAlbum(
                id: full.id,
                name: full.name,
                uri: full.uri,
                albumType: full.albumType,
                releaseDate: full.releaseDate,
                totalTracks: full.totalTracks,
                images: widget.album.images,
                artists: full.artists,
              );
        _loadMoreBy(api);
      });
    } catch (_) {}
  }

  /// 定位曲目在列表中的下标：先按 id，再按歌名（地区替换曲目时 id 可能不同）。
  int _focusIndex(List<SpotifyTrack> tracks) {
    final focus = widget.focusTrack;
    if (focus == null) return -1;
    final byId = tracks.indexWhere((t) => t.id == focus.id);
    if (byId >= 0) return byId;
    final name = focus.name.trim().toLowerCase();
    if (name.isEmpty) return -1;
    return tracks.indexWhere((t) => t.name.trim().toLowerCase() == name);
  }

  /// 曲目加载完成后的下一帧：滚动到定位行（置于视口上方约三分之一处）并高亮。
  void _scheduleFocus() {
    if (_focusDone) return;
    _focusDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final target = _focusKey.currentContext;
      if (!mounted || target == null) return;
      setState(() => _focusHighlight = true);
      await Scrollable.ensureVisible(
        target,
        alignment: 0.35,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
      _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _focusHighlight = false);
      });
    });
  }

  void _reload() => setState(_load);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final album = _album;
    final isSaved = context.select<LibraryProvider, bool>((l) => l.isAlbumSaved(album.id));
    final playbackContext = PlaybackContext.album(album.name, uri: album.contextUri);
    final mainArtist = album.artists.isNotEmpty ? album.artists.first : null;
    final resolvedArtist = mainArtist;

    return Scaffold(
      body: FutureBuilder<List<SpotifyTrack>>(
        future: _tracksFuture,
        builder: (context, snapshot) {
          final tracks = snapshot.data ?? const <SpotifyTrack>[];
          final loading = snapshot.connectionState != ConnectionState.done;
          final focusIndex = loading ? -1 : _focusIndex(tracks);
          if (focusIndex >= 0) _scheduleFocus();
          final totalMs = tracks.fold<int>(0, (sum, t) => sum + t.durationMs);

          // 年份 · 12 首歌曲，45 分钟（曲目加载完成后才有数量与时长）
          final facts = [
            if (album.releaseYear.isNotEmpty) album.releaseYear,
            if (tracks.isNotEmpty)
              l10n.countAndDuration(l10n.songCount(tracks.length), Formatters.formatLongDuration(l10n, totalMs)),
          ];

          return CollectionTintScope(
            imageUrl: album.coverUrl,
            fallback: const Color(0xFF3A3A48),
            child: CustomScrollView(
              // 需要定位时把整张曲目表都建出来（专辑通常不长），保证目标行有 context 可以滚动过去。
              cacheExtent: widget.focusTrack != null ? 20000 : null,
              slivers: [
                CollectionHero(
                  typeLabel: l10n.albumType(album),
                  title: album.name,
                  imageUrl: album.coverUrl,
                  meta: Row(
                    children: [
                      if (resolvedArtist != null)
                        Flexible(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            mouseCursor: SystemMouseCursors.click,
                            onTap: () => AppRoutes.openArtist(context, resolvedArtist),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CoverImage(
                                  url: resolvedArtist.avatarUrl,
                                  size: 24,
                                  circular: true,
                                  placeholderIcon: Icons.person_rounded,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    album.artistNames,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (facts.isNotEmpty)
                        Flexible(
                          child: Text(
                            ' · ${facts.join(' · ')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colorScheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                  collapsedAction: ContextPlayButton(
                    tracks: tracks,
                    playbackContext: playbackContext,
                    size: 44,
                    elevated: false,
                  ),
                ),

                SliverToBoxAdapter(
                  child: CollectionHeroFade(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: CollectionActionRow(
                        tracks: tracks,
                        playbackContext: playbackContext,
                        afterPlay: WatchFeedEntityButton(
                          feedUri: 'spotify:watch-feed:album:${album.id}',
                          name: album.name,
                        ),
                        leading: [
                          SaveToggleButton(
                            saved: isSaved,
                            onPressed: () => context.read<LibraryProvider>().toggleAlbumSaved(album),
                          ),
                          ShareButton(target: ShareTarget.album(album)),
                        ],
                      ),
                    ),
                  ),
                ),

                if (loading)
                  const CollectionPlaceholder(loading: true)
                else if (tracks.isEmpty && !context.read<SpotifyApiService>().isConfigured)
                  CollectionErrorPlaceholder(signedOut: true, onRetry: _reload)
                else if (tracks.isEmpty)
                  CollectionPlaceholder(message: l10n.albumNoTracks)
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final tile = TrackTile(
                          key: ValueKey(tracks[index].id),
                          track: tracks[index],
                          index: index + 1,
                          showCover: false,
                          contextQueue: tracks,
                          playbackContext: playbackContext,
                        );
                        if (index != focusIndex) return tile;
                        // 定位行：主题色底先亮起，约 2 秒后淡出。
                        return AnimatedContainer(
                          key: _focusKey,
                          duration: const Duration(milliseconds: 600),
                          curve: Curves.easeOut,
                          color: colorScheme.primary.withValues(alpha: _focusHighlight ? 0.18 : 0),
                          child: tile,
                        );
                      },
                      childCount: tracks.length,
                    ),
                  ),

                // 发行信息
                if (!loading && tracks.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        [
                          if (album.releaseDate.isNotEmpty) Formatters.formatReleaseDate(l10n, album.releaseDate),
                          l10n.countAndDuration(
                            l10n.songCount(tracks.length),
                            Formatters.formatLongDuration(l10n, totalMs),
                          ),
                        ].join('\n'),
                        style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13, height: 1.5),
                      ),
                    ),
                  ),

                // More by artist
                SliverToBoxAdapter(
                  child: FutureBuilder<List<SpotifyAlbum>>(
                    future: _moreByArtistFuture,
                    builder: (context, snap) {
                      final more = snap.data ?? const <SpotifyAlbum>[];
                      if (more.isEmpty || mainArtist == null) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Text(
                              l10n.albumMoreBy(mainArtist.name),
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          SizedBox(
                            height: 220,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              itemCount: more.length,
                              itemBuilder: (context, i) => ExpressiveCard(
                                title: more[i].name,
                                subtitle: l10n.subtitleJoin(more[i].releaseYear, l10n.albumType(more[i])),
                                imageUrl: more[i].coverUrl,
                                onTap: () => AppRoutes.openAlbum(context, more[i]),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                const ContentBottomSpacer(),
              ],
            ),
          );
        },
      ),
    );
  }
}
