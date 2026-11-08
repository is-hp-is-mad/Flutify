import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Pressable;
import '../../core/theme/flutify_tokens.dart';
import '../../core/theme/md3e_shapes.dart';
import '../../l10n/l10n.dart';
import '../../models/category.dart';
import 'cover_image.dart';

class CategoryCard extends StatelessWidget {
  final SpotifyCategory category;
  final VoidCallback onTap;

  const CategoryCard({
    super.key,
    required this.category,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final card = Container(
      height: 100,
      decoration: BoxDecoration(
        color: category.color,
        borderRadius: tokens.radius(MD3EShapes.radiusLarge),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            category.color.withAlpha(240),
            category.color,
          ],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Title
          Positioned(
            top: 14,
            left: 14,
            right: 60,
            child: Text(
              context.l10n.categoryName(category.name, category.id),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

            // Tilted cover in bottom-right corner
            Positioned(
              bottom: -10,
              right: -14,
              child: Transform.rotate(
                angle: 25 * math.pi / 180,
                child: Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(90),
                        blurRadius: 10,
                        offset: const Offset(2, 4),
                      ),
                    ],
                  ),
                  child: CoverImage(url: category.iconUrl, size: 74, borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      );

    if (tokens.hyperMaterial) {
      return Pressable(
        onTap: onTap,
        child: card,
      );
    }

    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      borderRadius: tokens.radius(MD3EShapes.radiusLarge),
      child: card,
    );
  }
}
