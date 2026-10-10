import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../models/artist.dart';
import '../../../models/track.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/cover_image.dart';

/// The lyrics card's text opens destinations; the cover returns to artwork.
class PlayerDestinationsSheet extends StatefulWidget {
  const PlayerDestinationsSheet({super.key, required this.track});

  final SpotifyTrack track;

  static Future<void> show(BuildContext context, SpotifyTrack track) async {
    TransitionRoute<dynamic>? route;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        route = ModalRoute.of(sheetContext);
        return PlayerDestinationsSheet(track: track);
      },
    );
    // Keep the player's interaction guard until the closing animation ends.
    await route?.completed;
  }

  @override
  State<PlayerDestinationsSheet> createState() =>
      _PlayerDestinationsSheetState();
}

class _PlayerDestinationsSheetState extends State<PlayerDestinationsSheet> {
  late final List<SpotifyArtist> _artists;
  final Map<String, Future<SpotifyArtist>> _artistDetails = {};
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    final seen = <String>{};
    _artists = widget.track.artists
        .where((artist) => artist.id.trim().isNotEmpty && seen.add(artist.id))
        .toList(growable: false);
    final api = context.read<SpotifyApiService?>();
    if (api != null) {
      for (final artist in _artists) {
        if (artist.avatarUrl.isEmpty) {
          _artistDetails[artist.id] = _resolveArtist(api, artist);
        }
      }
    }
  }

  Future<SpotifyArtist> _resolveArtist(
    SpotifyApiService api,
    SpotifyArtist original,
  ) async {
    try {
      final full = await api.getArtist(original.id);
      return full.id == original.id ? full : original;
    } catch (_) {
      // Offline/simplified tracks still have working destinations and a
      // truthful placeholder. FutureBuilder also ignores updates after close.
      return original;
    }
  }

  void _navigate(VoidCallback open) {
    if (_navigating || !mounted) return;
    _navigating = true;
    // AppRoutes closes this sheet and the player before opening the destination
    // in the active content tab, preserving playback and its back history.
    open();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final album = widget.track.album;
    final canOpenAlbum = album != null && album.id.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CoverImage(
                url: widget.track.coverUrl,
                size: 48,
                borderRadius: context.tokens.radius(6),
                placeholderIcon: Icons.album_rounded,
              ),
              title: Text(l10n.trackGoToAlbum),
              subtitle: album == null || album.name.isEmpty
                  ? null
                  : Text(
                      album.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              enabled: canOpenAlbum,
              onTap: canOpenAlbum
                  ? () => _navigate(() => AppRoutes.openAlbum(context, album))
                  : null,
            ),
            if (_artists.isEmpty)
              _artistTile(context, null)
            else
              for (final artist in _artists)
                FutureBuilder<SpotifyArtist>(
                  key: ValueKey(artist.id),
                  future: _artistDetails[artist.id],
                  initialData: artist,
                  builder: (context, snapshot) =>
                      _artistTile(context, snapshot.data ?? artist),
                ),
          ],
        ),
      ),
    );
  }

  Widget _artistTile(BuildContext context, SpotifyArtist? artist) => ListTile(
    leading: CoverImage(
      url: artist?.avatarUrl ?? '',
      size: 48,
      circular: true,
      placeholderIcon: Icons.person_rounded,
    ),
    title: Text(context.l10n.trackGoToArtist(1)),
    subtitle: artist == null || artist.name.isEmpty
        ? null
        : Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    enabled: artist != null,
    onTap: artist == null
        ? null
        : () => _navigate(() => AppRoutes.openArtist(context, artist)),
  );
}
