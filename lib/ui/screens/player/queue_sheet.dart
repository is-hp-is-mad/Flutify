import 'package:flutter/material.dart';

import '../../../core/theme/md3e_shapes.dart';
import '../../../l10n/l10n.dart';
import 'queue_list.dart';
import '../../widgets/app_modal.dart';
import '../../widgets/app_button.dart';

/// 播放队列底部面板（移动端）：拖拽把手 + 标题「播放队列 / 完成」+ [QueueList]。
class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showAppBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) => const QueueSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    // 背景必须是 Material 而不是带颜色的 DecoratedBox，否则 ListTile 的水波纹会被遮住
    return Material(
      color: colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(borderRadius: MD3EShapes.topSheet),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.queueTitle,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  AppButton.text(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      l10n.commonDone,
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const Expanded(child: QueueList()),
          ],
        ),
      ),
    );
  }
}
