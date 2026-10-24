import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/album.dart';
import '../../../models/artist.dart';
import '../../../models/catalog_page.dart';
import '../../../models/playback_context.dart';
import '../../../models/track.dart';
import '../../../services/spotify_api_service.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/track_tile.dart';
import 'widgets/artist_catalog_widgets.dart';
import 'widgets/collection_widgets.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton, M3EButtonStyle;
import '../../widgets/flutify_progress.dart';

enum ArtistCatalogKind { albums, songs }

/// Full artist catalog. Pages are fetched as the user approaches the end;
/// the artist overview is only a preview, never the catalog's data source.
class ArtistCatalogScreen extends StatefulWidget {
  final SpotifyArtist artist;
  final ArtistCatalogKind kind;
  final List<SpotifyTrack> initialTracks;

  const ArtistCatalogScreen({
    super.key,
    required this.artist,
    required this.kind,
    this.initialTracks = const [],
  });

  @override
  State<ArtistCatalogScreen> createState() => _ArtistCatalogScreenState();
}

class _ArtistCatalogScreenState extends State<ArtistCatalogScreen> {
  final _scrollController = ScrollController();
  final _albums = <SpotifyAlbum>[];
  final _tracks = <SpotifyTrack>[];
  ArtistTracksCursor? _trackCursor;
  int _albumOffset = 0;
  int _generation = 0;
  int _emptyPages = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _seeding = false;
  Object? _error;

  bool get _isAlbums => widget.kind == ArtistCatalogKind.albums;
  bool get _isEmpty => _isAlbums ? _albums.isEmpty : _tracks.isEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_loadNearEnd);
    _start();
  }

  @override
  void didUpdateWidget(covariant ArtistCatalogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.id != widget.artist.id ||
        oldWidget.kind != widget.kind) {
      _start();
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    }
  }

  void _start() {
    _generation++;
    _albums.clear();
    _tracks.clear();
    _trackCursor = null;
    _albumOffset = 0;
    _emptyPages = 0;
    _hasMore = true;
    _loading = false;
    _seeding = false;
    _error = null;
    if (!_isAlbums) {
      _mergeTracks(widget.initialTracks);
      if (_tracks.isEmpty) unawaited(_seedTopTracks(_generation));
    }
    unawaited(_loadMore());
  }

  Future<void> _seedTopTracks(int generation) async {
    _seeding = true;
    try {
      final tracks = await context.read<SpotifyApiService>().getArtistTopTracks(
        widget.artist.id,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _mergeTracks(tracks, prepend: true));
    } catch (_) {
      // Popular tracks are optional; the independently paged catalog remains usable.
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _seeding = false);
      }
    }
  }

  void _mergeTracks(List<SpotifyTrack> incoming, {bool prepend = false}) {
    final merged = <String, SpotifyTrack>{};
    for (final track in [
      ...(prepend ? incoming : _tracks),
      ...(prepend ? _tracks : incoming),
    ]) {
      final previous = merged[track.id];
      merged[track.id] = previous == null
          ? track
          : previous.copyWith(
              album: (track.album?.releaseDate.isNotEmpty ?? false)
                  ? track.album
                  : previous.album,
            );
    }
    _tracks
      ..clear()
      ..addAll(merged.values);
  }

  Future<void> _loadMore() async {
    if (!mounted || _loading || !_hasMore) return;
    final generation = _generation;
    final api = context.read<SpotifyApiService>();
    final previousCount = _isAlbums ? _albums.length : _tracks.length;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isAlbums) {
        final page = await api.getArtistAlbumsPage(
          widget.artist.id,
          offset: _albumOffset,
        );
        if (!mounted || generation != _generation) return;
        final ids = _albums.map((album) => album.id).toSet();
        _albums.addAll(page.items.where((album) => ids.add(album.id)));
        _hasMore = page.nextOffset != null && page.nextOffset! > _albumOffset;
        if (_hasMore) _albumOffset = page.nextOffset!;
      } else {
        final page = await api.getArtistTracksPage(
          widget.artist.id,
          cursor: _trackCursor,
        );
        if (!mounted || generation != _generation) return;
        _mergeTracks(page.items);
        _trackCursor = page.nextCursor;
        _hasMore = page.hasMore;
      }
      final count = _isAlbums ? _albums.length : _tracks.length;
      _emptyPages = count == previousCount ? _emptyPages + 1 : 0;
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _error = error;
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadNearEnd());
      }
    }
  }

  void _loadNearEnd() {
    // A run of empty/duplicate pages must not cause an unbounded request loop.
    // The explicit continuation button remains available in that situation.
    if (!mounted ||
        _error != null ||
        _emptyPages >= 3 ||
        !_scrollController.hasClients) {
      return;
    }
    if (_scrollController.position.extentAfter < 320) unawaited(_loadMore());
  }

  void _continue() {
    _emptyPages = 0;
    unawaited(_loadMore());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final title = _isAlbums ? l10n.filterAlbums : l10n.filterSongs;
    final titleStyle = _isAlbums
        ? theme.textTheme.headlineMedium
        : theme.textTheme.displaySmall;
    final playbackContext = PlaybackContext.artist(
      widget.artist.name,
      uri: widget.artist.contextUri,
    );
    final edge = MediaQuery.sizeOf(context).width >= 700 ? 24.0 : 16.0;
    // One immutable queue snapshot per rebuild, shared by every visible row.
    final contextQueue = List<SpotifyTrack>.unmodifiable(_tracks);

    return Scaffold(
      body: CustomScrollView(
        key: PageStorageKey('artist-${widget.artist.id}-${widget.kind.name}'),
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            pinned: true,
            toolbarHeight: 64,
            leadingWidth: 64,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: IconButton.filledTonal(
                key: const Key('artist-catalog-back'),
                tooltip: l10n.shellBack,
                style: IconButton.styleFrom(shape: const CircleBorder()),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            ),
            title: Text(
              widget.artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                edge,
                _isAlbums ? 12 : 16,
                edge,
                _isAlbums ? 20 : 24,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: titleStyle?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ),
          if (!_isEmpty && _isAlbums)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: edge),
              sliver: ArtistAlbumGrid(albums: _albums),
            )
          else if (!_isEmpty)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: edge - 16),
              sliver: SliverList.builder(
                itemCount: _tracks.length,
                itemBuilder: (context, index) {
                  final track = _tracks[index];
                  final album = track.album;
                  final subtitle = [
                    album?.name ?? '',
                    album?.releaseYear ?? '',
                  ].where((part) => part.isNotEmpty).join(' · ');
                  return Column(
                    children: [
                      TrackTile(
                        key: ValueKey('artist-song-${track.id}'),
                        track: track,
                        subtitle: subtitle.isEmpty
                            ? track.artistNames
                            : subtitle,
                        alwaysShowMore: true,
                        contextQueue: contextQueue,
                        playbackContext: playbackContext,
                      ),
                      const Padding(
                        padding: EdgeInsets.only(left: 80, right: 16),
                        child: Divider(height: 1),
                      ),
                    ],
                  );
                },
              ),
            ),
          if (_isEmpty && (_loading || _seeding))
            _isAlbums
                ? SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: edge),
                    sliver: const SliverToBoxAdapter(
                      child: SkeletonPulse(
                        child: SkeletonGrid(aspectRatio: 0.8),
                      ),
                    ),
                  )
                : const CollectionPlaceholder(loading: true)
          else if (_error != null)
            CollectionErrorPlaceholder(
              signedOut: !context.read<SpotifyApiService>().isConfigured,
              onRetry: _continue,
            )
          else if (_isEmpty && !_hasMore)
            CollectionPlaceholder(
              message: _isAlbums ? l10n.artistNoAlbums : l10n.artistNoSongs,
              icon: _isAlbums ? Icons.album_outlined : Icons.music_note_rounded,
            )
          else if (_hasMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: _loading
                      ? const SizedBox.square(
                          dimension: 24,
                          child: FlutifySpinner(size: 24),
                        )
                      : M3EButton.icon(style: M3EButtonStyle.outlined,
                          key: const Key('artist-catalog-load-more'),
                          onPressed: _continue,
                          icon: const Icon(Icons.expand_more_rounded),
                          label: Text(l10n.commonLoadMore),
                        ),
                ),
              ),
            ),
          const ContentBottomSpacer(),
        ],
      ),
    );
  }
}
