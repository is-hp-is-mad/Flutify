import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../hyper_surface.dart';
import '../hover_builder.dart';
import 'track_sort.dart';
import 'track_table_columns.dart';
import '../../screens/detail/widgets/collection_hero.dart';

/// 桌面曲目表格的列表头（Sliver，吸顶在详情页收起后的标题栏之下）：
/// `#` · 标题 · [艺人] · [专辑] · [添加日期] · 🕒
///
/// - 列宽与 TrackTile 共用 [TrackTableColumns]，逐列对齐；
/// - 点列名按该列排序（规则见 [TrackSort.tap]），当前排序列高亮并带方向箭头；
/// - 吸顶后铺上底色，避免与下面滚动的曲目重叠。
class TrackTableHeader extends StatelessWidget {
  final TrackTableColumns columns;
  final TrackSort sort;
  final ValueChanged<TrackSortKey> onSort;

  const TrackTableHeader({super.key, required this.columns, required this.sort, required this.onSort});

  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _Delegate(columns: columns, sort: sort, onSort: onSort),
    );
  }
}

class _Delegate extends SliverPersistentHeaderDelegate {
  final TrackTableColumns columns;
  final TrackSort sort;
  final ValueChanged<TrackSortKey> onSort;

  _Delegate({required this.columns, required this.sort, required this.onSort});

  @override
  double get minExtent => TrackTableHeader.height;

  @override
  double get maxExtent => TrackTableHeader.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final stuck = overlapsContent || shrinkOffset > 0;

    Widget cell(TrackSortKey key, String label, {TextAlign align = TextAlign.start}) => _SortLabel(
      label: label,
      active: sort.key == key,
      descending: sort.descending,
      align: align,
      onTap: () => onSort(key),
    );

    final content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: TrackTableColumns.horizontalPadding),
        child: Row(
          children: [
            SizedBox(
              width: columns.leadWidth,
              child: Center(child: Text('#', style: _SortLabel.baseStyle(context))),
            ),
            const SizedBox(width: TrackTableColumns.leadGap),
            Expanded(flex: TrackTableColumns.titleFlex, child: cell(TrackSortKey.title, l10n.trackColumnTitle)),
            if (columns.artist)
              Expanded(flex: TrackTableColumns.artistFlex, child: cell(TrackSortKey.artist, l10n.trackColumnArtist)),
            if (columns.album)
              Expanded(flex: TrackTableColumns.albumFlex, child: cell(TrackSortKey.album, l10n.trackColumnAlbum)),
            if (columns.addedAt)
              SizedBox(
                width: TrackTableColumns.addedAtWidth,
                child: cell(TrackSortKey.addedAt, l10n.trackColumnAddedAt),
              ),
            const SizedBox(width: TrackTableColumns.actionWidth),
            SizedBox(
              width: TrackTableColumns.durationWidth,
              child: Tooltip(
                message: l10n.trackColumnDuration,
                child: _SortLabel(
                  icon: Icons.schedule_rounded,
                  active: sort.key == TrackSortKey.duration,
                  descending: sort.descending,
                  align: TextAlign.end,
                  onTap: () => onSort(TrackSortKey.duration),
                ),
              ),
            ),
            const SizedBox(width: TrackTableColumns.actionWidth),
          ],
        ),
      );

    final tone = CollectionTint.maybeOf(context);

    if (context.tokens.hyperMaterial) {
      if (!stuck) return content;
      // 吸顶时铺上融合歌单色调的坚实底色（100% 不透明），防止下方曲目透字重叠，并彻底消除跨组件滤镜夹缝
      final headerSolidColor = Color.alphaBlend(
        (tone ?? scheme.primary).withValues(alpha: 0.20),
        scheme.surface,
      );
      return DecoratedBox(
        decoration: BoxDecoration(
          color: headerSolidColor,
          border: Border(
            bottom: BorderSide(
              color: Colors.white.withValues(alpha: 0.10),
              width: 0.6,
            ),
          ),
        ),
        child: content,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: stuck ? scheme.surfaceContainer : null,
        border: Border(bottom: BorderSide(color: scheme.onSurface.withAlpha(28))),
      ),
      child: content,
    );
  }

  @override
  bool shouldRebuild(_Delegate old) => old.columns != columns || old.sort != sort || old.onSort != onSort;
}

/// 可点击的列名（或图标）：悬停变亮，当前排序列高亮并显示 ▲ / ▼。
class _SortLabel extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final bool active;
  final bool descending;
  final TextAlign align;
  final VoidCallback onTap;

  const _SortLabel({
    this.label,
    this.icon,
    required this.active,
    required this.descending,
    required this.align,
    required this.onTap,
  });

  static TextStyle? baseStyle(BuildContext context) => Theme.of(
    context,
  ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w500);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final arrow = Icon(
      descending ? Icons.arrow_drop_down_rounded : Icons.arrow_drop_up_rounded,
      size: 20,
      color: scheme.primary,
    );
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) {
        final color = active || hovered ? scheme.onSurface : scheme.onSurfaceVariant;
        final content = icon != null
            ? Icon(icon, size: 18, color: color)
            : Flexible(
                child: Text(
                  label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: baseStyle(context)?.copyWith(color: color),
                ),
              );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            // 左对齐列与行里的文字列一样留 16 列间距；右对齐的时长列贴齐右沿
            padding: EdgeInsets.only(right: align == TextAlign.end ? 0 : 16),
            child: Row(
              mainAxisAlignment: align == TextAlign.end ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                // 右对齐的列（时长）箭头放左边，图标始终与下方时长右沿对齐
                if (active && align == TextAlign.end) arrow,
                content,
                if (active && align != TextAlign.end) arrow,
              ],
            ),
          ),
        );
      },
    );
  }
}
