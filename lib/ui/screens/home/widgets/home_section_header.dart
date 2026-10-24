import 'package:flutter/material.dart';

import '../../../../l10n/l10n.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;

/// 主页分区标题行：[leading]（艺人头像）+ 标题 / 副标题 + 右侧「显示全部」。
///
/// 标题最多两行、副标题一行，窄屏与大字号下自动截断，不会挤压「显示全部」。
class HomeSectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? leading;
  final VoidCallback? onShowAll;

  const HomeSectionHeader({super.key, required this.title, this.subtitle = '', this.leading, this.onShowAll});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (onShowAll != null)
            M3EButton.text(
              onPressed: onShowAll,
              child: Text(
                context.l10n.commonShowAll,
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}
