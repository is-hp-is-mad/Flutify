import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Pressable;

import '../../core/theme/flutify_tokens.dart';
import 'hover_builder.dart';

/// 胶囊筛选标签（音乐库类型、主页分类、右栏标签）。
///
/// 遵循小米 HyperOS / Material 规范：
/// 选中态为通透呼吸蓝与粗体主题字，未选中态为柔光半透卡片底；圆角随「圆角风格」或 HyperOS 药丸变化。
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
    final isDark = theme.brightness == Brightness.dark;

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) {
        final Color backgroundColor;
        final Color textColor;
        final FontWeight fontWeight;

        if (hyper) {
          if (isSelected) {
            backgroundColor = colorScheme.primary.withValues(
              alpha: isDark ? 0.20 : 0.14,
            );
            textColor = colorScheme.primary;
            fontWeight = FontWeight.w600;
          } else {
            backgroundColor = isDark
                ? (hovered ? const Color(0x24ffffff) : const Color(0x14ffffff))
                : (hovered ? const Color(0x14000000) : const Color(0x0a000000));
            textColor = colorScheme.onSurface.withValues(alpha: 0.85);
            fontWeight = FontWeight.w400;
          }
        } else {
          if (isSelected) {
            backgroundColor = tokens.accent;
            textColor = tokens.onAccent;
            fontWeight = FontWeight.w600;
          } else {
            backgroundColor = hovered
                ? colorScheme.surfaceContainerHighest
                : colorScheme.surfaceContainerHigh;
            textColor = colorScheme.onSurface;
            fontWeight = FontWeight.w500;
          }
        }

        final pillWidget = AnimatedContainer(
          duration: context.motion(const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: hyper
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
              : const EdgeInsets.fromLTRB(14.0, 5.5, 14.0, 4.5),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: hyper ? BorderRadius.circular(20) : tokens.pill,
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
              color: textColor,
              fontWeight: fontWeight,
            ),
          ),
        );

        if (hyper) {
          return Pressable(
            onTap: onTap,
            child: pillWidget,
          );
        }
        return GestureDetector(
          onTap: onTap,
          child: pillWidget,
        );
      },
    );
  }
}
