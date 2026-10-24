import 'package:material_3_expressive/material_3_expressive.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../l10n/l10n.dart';
import '../../../l10n/model_labels.dart';
import '../../../models/album.dart';
import '../../../models/artist.dart';
import '../../../models/playback_context.dart';
import '../../../models/share_target.dart';
import '../../../models/track.dart';
import '../../../providers/library_provider.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expressive_card.dart';
import '../../widgets/share/share_button.dart';
import '../../widgets/track_tile.dart';
import 'widgets/collection_hero.dart';
import 'widgets/collection_widgets.dart';
import 'widgets/artist_catalog_widgets.dart';

/// 艺人主页：热门曲目、关注、作品集（Discography）。
class ArtistDetailScreen extends StatefulWidget {
  final SpotifyArtist artist;

  const ArtistDetailScreen({super.key, required this.artist});

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  static const int _collapsedCount = 5;

  late Future<List<SpotifyTrack>> _topTracksFuture;
  late Future<List<SpotifyAlbum>> _albumsFuture;
  late SpotifyArtist _artist = widget.artist;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 热门曲目与作品集失败时由数据层返回空列表；登录后调用本方法重新加载。
  void _load() {
    final api = context.read<SpotifyApiService>();
    _topTracksFuture = api.getArtistTopTracks(widget.artist.id);
    _albumsFuture = api.getArtistAlbums(widget.artist.id);
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final artist = _artist;
    final isFollowing = context.select<LibraryProvider, bool>(
      (l) => l.isFollowing(artist.id),
    );
    final playbackContext = PlaybackContext.artist(
      artist.name,
      uri: artist.contextUri,
    );

    return Scaffold(
      body: FutureBuilder<List<SpotifyTrack>>(
        future: _topTracksFuture,
        builder: (context, snapshot) {
          final topTracks = snapshot.data ?? const <SpotifyTrack>[];
          final loading = snapshot.connectionState != ConnectionState.done;
          final visibleCount = topTracks.length.clamp(0, _collapsedCount);

          return CollectionTintScope(
            imageUrl: artist.avatarUrl,
            fallback: const Color(0xFF3A3A48),
            child: CustomScrollView(
              slivers: [
                CollectionHero(
                  typeLabel: l10n.typeArtist,
                  title: artist.name,
                  imageUrl: artist.avatarUrl,
                  circularCover: true,
                  meta: artist.followers == null
                      ? null
                      : Text(
                          l10n.followerCount(
                            Formatters.formatCompactNumber(
                              l10n,
                              artist.followers,
                            ),
                          ),
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                  collapsedAction: ContextPlayButton(
                    tracks: topTracks,
                    playbackContext: playbackContext,
                    size: 44,
                    elevated: false,
                  ),
                ),

                SliverToBoxAdapter(
                  child: CollectionHeroFade(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CollectionActionRow(
                            tracks: topTracks,
                            playbackContext: playbackContext,
                            leading: [
                              _FollowButton(
                                following: isFollowing,
                                onPressed: () => context
                                    .read<LibraryProvider>()
                                    .toggleFollowArtist(artist),
                              ),
                              const SizedBox(width: 4),
                              ShareButton(target: ShareTarget.artist(artist)),
                            ],
                          ),
                          const SizedBox(height: 20),
                          ArtistCatalogSectionHeading(
                            title: l10n.artistPopular,
                            tooltip: l10n.filterSongs,
                            buttonKey: const Key('artist-songs-link'),
                            onOpen: () => AppRoutes.openArtistSongs(
                              context,
                              artist,
                              initialTracks: topTracks,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                if (loading)
                  const CollectionPlaceholder(loading: true)
                else if (snapshot.hasError)
                  CollectionErrorPlaceholder(
                    signedOut: !context.read<SpotifyApiService>().isConfigured,
                    onRetry: _reload,
                  )
                else if (topTracks.isEmpty &&
                    !context.read<SpotifyApiService>().isConfigured)
                  CollectionErrorPlaceholder(signedOut: true, onRetry: _reload)
                else if (topTracks.isEmpty)
                  CollectionPlaceholder(message: l10n.artistNoPopular)
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => TrackTile(
                        key: ValueKey(topTracks[index].id),
                        track: topTracks[index],
                        index: index + 1,
                        showCover: true,
                        contextQueue: topTracks,
                        playbackContext: playbackContext,
                      ),
                      childCount: visibleCount,
                    ),
                  ),

                SliverToBoxAdapter(
                  child: FutureBuilder<List<SpotifyAlbum>>(
                    future: _albumsFuture,
                    builder: (context, snap) {
                      final albums = snap.data ?? const <SpotifyAlbum>[];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: ArtistCatalogSectionHeading(
                              title: l10n.artistDiscography,
                              tooltip: l10n.filterAlbums,
                              buttonKey: const Key('artist-albums-link'),
                              onOpen: () =>
                                  AppRoutes.openArtistAlbums(context, artist),
                            ),
                          ),
                          if (snap.connectionState != ConnectionState.done)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: M3ELoadingIndicator()),
                            )
                          else if (snap.hasError)
                            EmptyState(
                              icon: Icons.cloud_off_rounded,
                              title: l10n.detailLoadFailed,
                              compact: true,
                              actionLabel: l10n.commonRetry,
                              onAction: _reload,
                            )
                          else if (albums.isEmpty)
                            EmptyState(
                              icon: Icons.album_outlined,
                              title: l10n.artistNoAlbums,
                              compact: true,
                            )
                          else
                            SizedBox(
                              height: ExpressiveCard.heightFor(context, 148),
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                ),
                                itemCount: albums.length,
                                itemBuilder: (context, i) => ExpressiveCard(
                                  title: albums[i].name,
                                  subtitle: l10n.subtitleJoin(
                                    l10n.albumType(albums[i]),
                                    albums[i].releaseYear,
                                  ),
                                  imageUrl: albums[i].coverUrl,
                                  onTap: () =>
                                      AppRoutes.openAlbum(context, albums[i]),
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

class _FollowButton extends StatelessWidget {
  final bool following;
  final VoidCallback onPressed;

  const _FollowButton({required this.following, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return M3EButton.outlined(
      onPressed: onPressed,
      decoration: M3EButtonDecoration(
        side: WidgetStatePropertyAll(
          BorderSide(
            color: following ? colorScheme.onSurface : colorScheme.outline,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Text(
          following ? context.l10n.artistFollowing : context.l10n.artistFollow,
          key: ValueKey(following),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
