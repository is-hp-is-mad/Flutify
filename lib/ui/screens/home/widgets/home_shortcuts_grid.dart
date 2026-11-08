import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Pressable;

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../core/theme/md3e_shapes.dart';
import '../../../../core/utils/artwork_palette.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/home_feed.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/hover_builder.dart';
import '../../../widgets/text_metrics.dart';
import '../home_item_actions.dart';
import 'home_item_card.dart';

/// 顶部快捷入口（官方 HomeShortcutsGrid）：左侧方形封面 + 两行粗体标题。
///
/// - 桌面（内容区 ≥ [_wideWidth]）：条目数为 4 的倍数时 4 列，否则 3 列；
///   内容区 ≥ [_largeWidth] 时封面 64，否则 48（与官方 small / large 两档一致）；
///   悬停时提亮底色并在右侧浮出播放键；
/// - 手机：2 列、封面 56。
/// 行高取「封面边长」与「两行标题实测高度」的较大者，字号放大不溢出。
class HomeShortcutsGrid extends StatelessWidget {
  final List<HomeItem> items;
  final bool desktop;

  /// 悬停条目时回调封面主色（离开时回调 null）；主页顶部渐变按它取色。
  final ValueChanged<Color?>? onHoverTint;

  const HomeShortcutsGrid({
    super.key,
    required this.items,
    required this.desktop,
    this.onHoverTint,
  });

  static const double _wideWidth = 720;
  static const double _largeWidth = 1141;
  static const double _spacing = 8;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.25);
    final twoLines = TextMetrics.lineHeight(context, titleStyle) * 2 + 8;

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final wide = desktop && width >= _wideWidth;
          final columns = wide ? (items.length % 4 == 0 ? 4 : 3) : 2;
          final cover = desktop ? (width >= _largeWidth ? 64.0 : 48.0) : 56.0;
          final tileWidth = (width - _spacing * (columns - 1)) / columns;

          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: _spacing,
              crossAxisSpacing: _spacing,
              mainAxisExtent: math.max(cover, twoLines),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _ShortcutTile(
                item: items[index],
                cover: cover,
                titleStyle: titleStyle,
                // 太窄时不放播放键，把空间留给标题
                showPlay: desktop && tileWidth >= 200 && HomeItemActions.canPlay(items[index]),
                onHoverTint: onHoverTint,
              ),
              childCount: items.length,
            ),
          );
        },
      ),
    );
  }
}

class _ShortcutTile extends StatefulWidget {
  final HomeItem item;
  final double cover;
  final TextStyle? titleStyle;
  final bool showPlay;
  final ValueChanged<Color?>? onHoverTint;

  const _ShortcutTile({
    required this.item,
    required this.cover,
    required this.titleStyle,
    required this.showPlay,
    this.onHoverTint,
  });

  @override
  State<_ShortcutTile> createState() => _ShortcutTileState();
}

class _ShortcutTileState extends State<_ShortcutTile> {
  /// 悬停代数：封面主色异步解析完时若已离开（或悬停了别的），丢弃结果。
  int _hoverGen = 0;

  void _onHoverChanged(bool hovered) {
    final gen = ++_hoverGen;
    final tint = widget.onHoverTint;
    if (tint == null) return;
    if (!hovered) {
      tint(null);
      return;
    }
    final liked = widget.item.kind == HomeItemKind.likedSongs;
    final url = liked ? HomeItemCard.likedSongsCover : widget.item.imageUrl;
    ArtworkPalette.resolve(url).then((color) {
      if (mounted && gen == _hoverGen) tint(color);
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final cover = widget.cover;
    final titleStyle = widget.titleStyle;
    final showPlay = widget.showPlay;
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;
    final radius = tokens.radius(MD3EShapes.radiusSmall);
    final liked = item.kind == HomeItemKind.likedSongs;

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      onHoverChanged: _onHoverChanged,
      builder: (context, hovered) {
        final content = Row(
          children: [
            // 封面贴左、上下居中；行高大于封面时（大字号）上下留白
            SizedBox(
              width: cover,
              height: cover,
              child: CoverImage(
                url: liked ? HomeItemCard.likedSongsCover : item.imageUrl,
                size: cover,
                circular: item.isCircular,
                placeholderIcon: item.isCircular ? Icons.person_rounded : Icons.music_note_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                HomeItemCard.titleOf(context.l10n, item),
                style: titleStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showPlay)
              AnimatedOpacity(
                opacity: hovered ? 1 : 0,
                duration: context.motion(const Duration(milliseconds: 160)),
                child: IgnorePointer(
                  ignoring: !hovered,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _PlayButton(onPressed: () => HomeItemActions.play(context, item)),
                  ),
                ),
              )
            else
              const SizedBox(width: 8),
          ],
        );

        if (tokens.hyperMaterial) {
          return Pressable(
            onTap: () => HomeItemActions.open(context, item),
            child: AnimatedContainer(
              duration: context.motion(const Duration(milliseconds: 200)),
              decoration: BoxDecoration(
                color: hovered ? colorScheme.surfaceContainerHighest : colorScheme.surfaceContainerHigh,
                borderRadius: radius,
              ),
              clipBehavior: Clip.antiAlias,
              child: content,
            ),
          );
        }

        return Material(
          color: hovered ? colorScheme.surfaceContainerHighest : colorScheme.surfaceContainerHigh,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: SystemMouseCursors.click,
            onTap: () => HomeItemActions.open(context, item),
            hoverColor: Colors.transparent,
            child: content,
          ),
        );
      },
    );
  }
}

/// 快捷入口右侧的强调色圆形播放键（悬停出现）。
class _PlayButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _PlayButton({required this.onPressed});

  static const double _size = 32;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final hyper = tokens.hyperMaterial;

    final icon = SizedBox.square(
      dimension: _size,
      child: Icon(
        Icons.play_arrow_rounded,
        size: 22,
        color: hyper ? Theme.of(context).colorScheme.onPrimary : tokens.onAccent,
      ),
    );

    if (hyper) {
      return Pressable(
        onTap: onPressed,
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
          ),
          child: icon,
        ),
      );
    }

    return Material(
      color: tokens.accent,
      shape: tokens.squareCorners
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
          : const CircleBorder(),
      elevation: 3,
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: icon,
      ),
    );
  }
}
