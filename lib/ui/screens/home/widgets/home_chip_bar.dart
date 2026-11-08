import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show HyTextTabs, Pressable;

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/home_feed.dart';
import '../../../widgets/filter_pill.dart';
import '../../../widgets/hover_builder.dart';
import '../../../widgets/text_metrics.dart';

/// 主页顶部筛选标签栏（遵循小米 HyperOS 规范，默认随页面内容滚动，仅在顶部可见）。
///
/// 标签来自服务端 homeChips：
/// - 未选中任何标签：「全部」+ 各一级标签；
/// - 选中某个一级标签（或其二级标签）：「×」清除 + 该一级标签 + 它的二级标签。
/// [leading] 为手机端左侧的头像（点按打开设置）。
class HomeChipBar extends StatelessWidget {
  final List<HomeChip> chips;

  /// 当前 facet（空 = 全部）。
  final String selected;
  final ValueChanged<String> onSelected;
  final Widget? leading;
  final Widget? trailing;

  /// 与页面背景同位置的渐变切片，吸顶时遮住下方滚动内容（若不吸顶或为 null 则全透光）。
  final Widget? background;

  /// 是否吸顶（默认为 true 以兼容既有吸顶场景；在小米 HyperOS 主页中显式传入 false 随页面滚动）。
  final bool pinned;

  const HomeChipBar({
    super.key,
    required this.chips,
    required this.selected,
    required this.onSelected,
    this.background,
    this.pinned = true,
    this.leading,
    this.trailing,
  });

  static const double _verticalPadding = 8;
  static const double _leadingSize = 36;

  /// 胶囊高度：遵循小米 HyperOS 规范（40dp 圆润药丸）。
  static const double pillHeight = 40;

  /// 标签行高度：胶囊与头像取大者，再加上下留白。
  static double extentOf(BuildContext context, {bool hasSubChips = false}) {
    final pill =
        TextMetrics.lineHeight(
          context,
          Theme.of(context).textTheme.labelMedium,
        ) +
        10;
    final base = math.max(pill, _leadingSize) + _verticalPadding * 2;
    return hasSubChips ? base + 48 : base;
  }

  /// 选中的 facet 属于哪个一级标签（一级本身或其二级标签）。
  HomeChip? get _parent {
    if (selected.isEmpty) return null;
    for (final chip in chips) {
      if (chip.id == selected || chip.subChips.any((s) => s.id == selected)) {
        return chip;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final parent = _parent;
    final hyper = context.tokens.hyperMaterial;

    final Widget content;
    if (hyper) {
      final items = [
        l10n.filterAll,
        for (final chip in chips) l10n.homeChipLabel(chip.label, chip.id),
      ];
      final primaryIndex = parent == null
          ? 0
          : (chips.contains(parent) ? chips.indexOf(parent) + 1 : 0);

      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (leading != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: leading!,
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.fromLTRB(
                      leading == null ? 16 : 10,
                      0,
                      16,
                      0,
                    ),
                    child: HyTextTabs(
                      items: items,
                      index: primaryIndex,
                      onChanged: (index) {
                        if (index == 0) {
                          onSelected('');
                        } else {
                          final chip = chips[index - 1];
                          if (parent?.id == chip.id) {
                            onSelected('');
                          } else {
                            onSelected(chip.id);
                          }
                        }
                      },
                    ),
                  ),
                ),
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: trailing!,
                  ),
              ],
            ),
            if (parent != null && parent.subChips.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.fromLTRB(
                    leading == null ? 16 : 10,
                    0,
                    16,
                    0,
                  ),
                  child: Row(
                    children: [
                      for (final sub in parent.subChips)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterPill(
                            label: l10n.homeChipLabel(sub.label, sub.id),
                            isSelected: selected == sub.id,
                            onTap: () {
                              if (selected == sub.id) {
                                onSelected(parent.id);
                              } else {
                                onSelected(sub.id);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    } else {
      final pills = <Widget>[
        if (parent == null) ...[
          FilterPill(
            label: l10n.filterAll,
            isSelected: true,
            onTap: () => onSelected(''),
          ),
          for (final chip in chips)
            FilterPill(
              label: l10n.homeChipLabel(chip.label, chip.id),
              isSelected: false,
              onTap: () => onSelected(chip.id),
            ),
        ] else ...[
          _ClearPill(tooltip: l10n.homeClearFilter, onTap: () => onSelected('')),
          FilterPill(
            label: l10n.homeChipLabel(parent.label, parent.id),
            isSelected: selected == parent.id,
            onTap: () => onSelected(parent.id),
          ),
          for (final sub in parent.subChips)
            FilterPill(
              label: l10n.homeChipLabel(sub.label, sub.id),
              isSelected: selected == sub.id,
              onTap: () => onSelected(sub.id),
            ),
        ],
      ];

      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
        child: Row(
          children: [
            if (leading != null)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: leading!,
              ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(
                  leading == null ? 16 : 10,
                  0,
                  16,
                  0,
                ),
                child: Row(
                  children: [
                    for (final pill in pills)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(height: pillHeight, child: pill),
                      ),
                  ],
                ),
              ),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: trailing!,
              ),
          ],
        ),
      );
    }

    if (!pinned) {
      return SliverToBoxAdapter(
        child: background == null
            ? content
            : Stack(children: [Positioned.fill(child: background!), content]),
      );
    }

    final hasSubChips = hyper && parent != null && parent.subChips.isNotEmpty;
    return SliverPersistentHeader(
      pinned: true,
      delegate: _ChipBarDelegate(
        extent: extentOf(context, hasSubChips: hasSubChips),
        background: background ?? const SizedBox.shrink(),
        child: content,
      ),
    );
  }
}

class _ChipBarDelegate extends SliverPersistentHeaderDelegate {
  final double extent;
  final Widget background;
  final Widget child;

  _ChipBarDelegate({
    required this.extent,
    required this.background,
    required this.child,
  });

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) =>
      // 必须撑满 extent：吸顶 sliver 以子组件高度作为绘制高度
      SizedBox.expand(
        child: Stack(fit: StackFit.expand, children: [background, child]),
      );

  @override
  bool shouldRebuild(_ChipBarDelegate old) =>
      old.extent != extent ||
      old.background != background ||
      old.child != child;
}

/// 「×」清除筛选（与胶囊同高的圆形按钮）。
class _ClearPill extends StatelessWidget {
  final String tooltip;
  final VoidCallback onTap;

  const _ClearPill({required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hyper = context.tokens.hyperMaterial;
    final isDark = theme.brightness == Brightness.dark;
    const size = HomeChipBar.pillHeight;
    return Tooltip(
      message: tooltip,
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) {
          final button = AnimatedContainer(
            duration: context.motion(const Duration(milliseconds: 200)),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: hyper
                  ? (isDark
                      ? (hovered ? const Color(0x24ffffff) : const Color(0x14ffffff))
                      : (hovered ? const Color(0x14000000) : const Color(0x0a000000)))
                  : (hovered
                      ? colorScheme.surfaceContainerHighest
                      : colorScheme.surfaceContainerHigh),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.close_rounded,
              size: 18,
              color: hyper
                  ? colorScheme.onSurface.withValues(alpha: 0.85)
                  : colorScheme.onSurface,
            ),
          );
          if (hyper) {
            return Pressable(
              onTap: onTap,
              child: button,
            );
          }
          return GestureDetector(
            onTap: onTap,
            child: button,
          );
        },
      ),
    );
  }
}
