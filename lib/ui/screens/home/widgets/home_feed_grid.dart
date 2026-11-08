import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../models/home_feed.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/expressive_card.dart';
import '../../../widgets/text_metrics.dart';
import 'home_item_card.dart';

/// 推荐流网格（官方桌面端的 HomeFeedBaselineUnifiedShelf）：
/// 所有 FeedBaseline 分区合并成一个网格，每张卡上方一行推荐理由（可带艺人头像），
/// 如「为你推荐」「与 Vicetone 相似的更多艺人」。
///
/// 列数随宽度（每列不小于 [_minCellDesktop] / [_minCellMobile]，至少 2 列），
/// 与官方一样只显示整行（多出来不满一行的卡片不显示）。行高按当前字号实测。
class HomeFeedGrid extends StatelessWidget {
  final HomeSection section;
  final bool desktop;

  const HomeFeedGrid({super.key, required this.section, required this.desktop});

  static const double _minCellDesktop = 180;
  static const double _minCellMobile = 150;
  static const double _spacing = 4;
  static const double _avatarSize = 20;
  static const double _reasonGap = 6;

  @override
  Widget build(BuildContext context) {
    final reasonStyle = _reasonStyle(context);
    final reasonRow = math.max(_avatarSize, TextMetrics.lineHeight(context, reasonStyle));

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(10, 24, 10, 0),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final minCell = desktop ? _minCellDesktop : _minCellMobile;
          final columns = math.max(2, ((width + _spacing) / (minCell + _spacing)).floor());
          final cellWidth = (width - _spacing * (columns - 1)) / columns;
          final items = section.items;
          final count = items.length >= columns ? items.length - items.length % columns : items.length;

          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: _spacing,
              mainAxisSpacing: 12,
              mainAxisExtent: reasonRow + _reasonGap + ExpressiveCard.heightFor(context, cellWidth),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) =>
                  _FeedCell(item: items[index], width: cellWidth, reasonStyle: reasonStyle, reasonRow: reasonRow),
              childCount: count,
            ),
          );
        },
      ),
    );
  }

  static TextStyle? _reasonStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
  }
}

class _FeedCell extends StatelessWidget {
  final HomeItem item;
  final double width;
  final TextStyle? reasonStyle;

  /// 推荐理由行高（头像与当前字号下文字行高取大者）。
  final double reasonRow;

  const _FeedCell({required this.item, required this.width, required this.reasonStyle, required this.reasonRow});

  @override
  Widget build(BuildContext context) {
    final artist = item.reasonArtist;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // 与卡片内封面左缘对齐
          padding: const EdgeInsets.fromLTRB(6, 0, 6, HomeFeedGrid._reasonGap),
          child: SizedBox(
            height: reasonRow,
            child: Row(
              children: [
                if (artist != null) ...[
                  CoverImage(
                    url: artist.avatarUrl,
                    size: HomeFeedGrid._avatarSize,
                    circular: true,
                    placeholderIcon: Icons.person_rounded,
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(item.reason, style: reasonStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: HomeItemCard(item: item, width: width, margin: EdgeInsets.zero),
        ),
      ],
    );
  }
}
