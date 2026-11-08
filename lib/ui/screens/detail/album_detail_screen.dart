import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../l10n/l10n.dart';
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
import 'widgets/collection_hero.dart';
import 'widgets/collection_widgets.dart';

/// 专辑详情页：曲目列表、收藏、发行信息与「More by 艺人」。
class AlbumDetailScreen extends StatefulWidget {
  final SpotifyAlbum album;

  const AlbumDetailScreen({super.key, required this.album});

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  late Future<List<SpotifyTrack>> _tracksFuture;
  late Future<List<SpotifyAlbum>> _moreByArtistFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 曲目与「More by」失败时由数据层返回空列表；登录后调用本方法重新加载。
  void _load() {
    final api = context.read<SpotifyApiService>();
    _tracksFuture = api.getAlbumTracks(widget.album);
    _moreByArtistFuture = widget.album.artists.isEmpty
        ? Future.value(const [])
        : api
              .getArtistAlbums(widget.album.artists.first.id)
              .then((albums) => albums.where((a) => a.id != widget.album.id).toList());
  }

  void _reload() => setState(_load);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final album = widget.album;
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
                                    style: const TextStyle(fontWeight: FontWeight.w600),
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
                      (context, index) => TrackTile(
                        key: ValueKey(tracks[index].id),
                        track: tracks[index],
                        index: index + 1,
                        showCover: false,
                        contextQueue: tracks,
                        playbackContext: playbackContext,
                      ),
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
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
