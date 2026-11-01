import 'package:flutter/material.dart';

import '../../core/theme/flutify_tokens.dart';
import 'hover_builder.dart';

/// 胶囊筛选标签（音乐库类型、主页分类、右栏标签）。
///
/// 选中：强调色底 + 自动黑 / 白字（深浅色主题一致；浅色主题的 primary 是加深色，不用它做填充）；
/// 未选中：容器色底，悬停时提亮一级。圆角随「圆角风格」变化。
class FilterPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const FilterPill({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final hyper = tokens.hyperMaterial;

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
          // 被父级给予固定高度时（如搜索页横向列表）文字也要在胶囊内垂直居中
          alignment: Alignment.center,
          // 扁平胶囊：上下内边距仅 10px（整体约 26px 高），与 Spotify 的紧凑筛选胶囊一致。
          // MiSans 汉字视觉重心比行框中心高约 0.03em（约 0.4px，实测字体度量），上下内边距补偿 0.5px
          padding: const EdgeInsets.fromLTRB(14.0, 5.5, 14.0, 4.5),
          decoration: BoxDecoration(
            color: isSelected
                ? (hyper ? colorScheme.primaryContainer : tokens.accent)
                : (hovered ? colorScheme.surfaceContainerHighest : colorScheme.surfaceContainerHigh),
            borderRadius: tokens.pill,
            boxShadow: isSelected && !hyper
                ? [
                    BoxShadow(
                      color: tokens.accent.withAlpha(70),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: isSelected
                  ? (hyper ? colorScheme.primary : tokens.onAccent)
                  : colorScheme.onSurface,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
