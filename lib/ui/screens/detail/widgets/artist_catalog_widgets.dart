import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../models/album.dart';
import '../../../navigation/app_routes.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/text_metrics.dart';

/// A catalog remains reachable even when its overview preview is empty.
class ArtistCatalogSectionHeading extends StatelessWidget {
  final String title;
  final String tooltip;
  final Key buttonKey;
  final VoidCallback onOpen;

  const ArtistCatalogSectionHeading({
    super.key,
    required this.title,
    required this.tooltip,
    required this.buttonKey,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(
        child: Semantics(
          header: true,
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        key: buttonKey,
        tooltip: tooltip,
        onPressed: onOpen,
        style: IconButton.styleFrom(
          shape: const CircleBorder(),
          minimumSize: const Size.square(32),
          fixedSize: const Size.square(32),
          padding: const EdgeInsets.all(6),
          iconSize: 20,
          visualDensity: VisualDensity.standard,
          // Shrink the painted circle, not the accessible hit target.
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        icon: const Icon(Icons.chevron_right_rounded),
      ),
    ],
  );
}

/// Square artwork with two title lines and a release year, built lazily.
class ArtistAlbumGrid extends StatelessWidget {
  final List<SpotifyAlbum> albums;

  const ArtistAlbumGrid({super.key, required this.albums});

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.crossAxisExtent;
      final gap = width >= 700 ? 20.0 : 16.0;
      // An extra desktop column makes artwork about 75–80% of its previous
      // size. Keep two columns on phones and widen cells for large text.
      final preferred = width >= 1000
          ? 5
          : width >= 650
          ? 4
          : width >= 480
          ? 3
          : 2;
      final minWidth = MediaQuery.textScalerOf(context).scale(120);
      final columns = math.max(
        1,
        math.min(preferred, ((width + gap) / (minWidth + gap)).floor()),
      );
      final cellWidth = (width - gap * (columns - 1)) / columns;
      final theme = Theme.of(context);
      final titleStyle = theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
      );
      final yearStyle = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
      final height =
          cellWidth +
          8 +
          TextMetrics.lineHeight(context, titleStyle) * 2 +
          2 +
          TextMetrics.lineHeight(context, yearStyle) +
          4;
      return SliverGrid.builder(
        itemCount: albums.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gap,
          mainAxisSpacing: 20,
          mainAxisExtent: height,
        ),
        itemBuilder: (context, index) {
          final album = albums[index];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('artist-album-${album.id}'),
              borderRadius: context.tokens.radius(12),
              mouseCursor: SystemMouseCursors.click,
              onTap: () => AppRoutes.openAlbum(context, album),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: CoverImage(
                      url: album.coverUrl,
                      borderRadius: context.tokens.radius(12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    album.name,
                    style: titleStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    album.releaseYear,
                    style: yearStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
