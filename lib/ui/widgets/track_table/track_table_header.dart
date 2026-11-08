import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../hover_builder.dart';
import '../hyper_surface.dart';
import 'track_sort.dart';
import 'track_table_columns.dart';
import '../../screens/detail/widgets/collection_hero.dart';

/// 桌面曲目表格的列表头（Sliver，吸顶在详情页收起后的标题栏之下）：
/// `#` · 标题 · [艺人] · [专辑] · [添加日期] · 🕒
///
/// - 列宽与 TrackTile 共用 [TrackTableColumns]，逐列对齐；
/// - 点列名按该列排序（规则见 [TrackSort.tap]），当前排序列高亮并带方向箭头；
/// - 吸顶后铺上底色，避免与下面滚动的曲目重叠。
/// 桌面曲目表格的列表头内容（纯 Widget，用于一体化吸顶栏或流式列表）：
/// `#` · 标题 · [艺人] · [专辑] · [添加日期] · 🕒
///
/// - 列宽与 TrackTile 共用 [TrackTableColumns]，逐列对齐；
/// - 点列名按该列排序（规则见 [TrackSort.tap]），当前排序列高亮并带方向箭头。
class TrackTableHeaderContent extends StatelessWidget {
  final TrackTableColumns columns;
  final TrackSort sort;
  final ValueChanged<TrackSortKey> onSort;
  final bool showBottomBorder;

  const TrackTableHeaderContent({
    super.key,
    required this.columns,
    required this.sort,
    required this.onSort,
    this.showBottomBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    Widget cell(TrackSortKey key, String label, {TextAlign align = TextAlign.start}) => _SortLabel(
      label: label,
      active: sort.key == key,
      descending: sort.descending,
      align: align,
      onTap: () => onSort(key),
    );

    final row = SizedBox(
      height: TrackTableHeader.height,
      child: Padding(
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
      ),
    );

    if (showBottomBorder) {
      return DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.onSurface.withAlpha(20))),
        ),
        child: row,
      );
    }
    return row;
  }
}

/// 桌面曲目表格的列表头（Sliver）：
/// 平时随页面流动，当滑动到 64dp（吸顶标题栏下方）时自动停留在该位置吸顶，
/// 并呈现高饱和 Tint Glass 着色玻璃与毛玻璃效果。
class TrackTableHeader extends StatelessWidget {
  final TrackTableColumns columns;
  final TrackSort sort;
  final ValueChanged<TrackSortKey> onSort;

  const TrackTableHeader({super.key, required this.columns, required this.sort, required this.onSort});

  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // 当 scrollOffset > 0 时，说明表头已滑动到 64dp 处停住吸附；
        // 当 scrollOffset == 0 时，说明表头还在流式向上滑动，背景完全透明！
        final bool stuck = constraints.scrollOffset > 0;
        final scheme = Theme.of(context).colorScheme;
        final tone = CollectionTint.maybeOf(context);
        final hyper = context.tokens.hyperMaterial;

        final content = TrackTableHeaderContent(
          columns: columns,
          sort: sort,
          onSort: onSort,
          showBottomBorder: !stuck,
        );

        final Widget bar;
        if (!stuck) {
          // 未滑动到 64dp 前：随页面正常流动，100% 透明无底色，绝不显现突兀色块
          bar = content;
        } else if (hyper) {
          // 滑动到 64dp 停住吸附时：接续顶栏 [60, 52, 44, 36]，呈现下半段 [28, 20, 12, 4] 渐变模糊，
          // 上沿着色 0.65 与顶栏底沿 0.65 浑然一体，下沿平滑羽化至 0.18
          final effectiveColor = tone ?? scheme.surface;
          bar = Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  for (final radius in const [28.0, 20.0, 12.0, 4.0])
                    Expanded(
                      child: ClipRect(
                        child: BackdropFilter.grouped(
                          filter: ImageFilter.blur(
                            sigmaX: HyperBlendSurface.blurSigma(radius),
                            sigmaY: HyperBlendSurface.blurSigma(radius),
                            tileMode: TileMode.mirror,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                ],
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      effectiveColor.withValues(alpha: 0.65),
                      effectiveColor.withValues(alpha: 0.18),
                    ],
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.12),
                      width: 0.6,
                    ),
                  ),
                ),
                child: const SizedBox.expand(),
              ),
              content,
            ],
          );
        } else {
          bar = DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              border: Border(bottom: BorderSide(color: scheme.onSurface.withAlpha(28))),
            ),
            child: content,
          );
        }

        return PinnedHeaderSliver(
          child: SizedBox(
            height: height,
            child: bar,
          ),
        );
      },
    );
  }
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
