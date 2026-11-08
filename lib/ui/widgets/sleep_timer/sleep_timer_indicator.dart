import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../providers/sleep_timer_provider.dart';
import 'sleep_timer_menu.dart';

/// 播放栏上的睡眠定时器指示：只在定时器开启时出现（月亮图标 + 剩余时间提示），点击重新选择或关闭。
class SleepTimerIndicator extends StatelessWidget {
  final ButtonStyle? style;

  const SleepTimerIndicator({super.key, this.style});

  /// 定时器是否开启（父组件据此决定是否给它留位置）。
  static bool isActive(BuildContext context) => context.select<SleepTimerProvider?, bool>((t) => t?.active ?? false);

  @override
  Widget build(BuildContext context) {
    final timer = context.watch<SleepTimerProvider?>();
    if (timer == null || !timer.active) return const SizedBox.shrink();
    return Builder(
      // 独立 context：菜单锚定在按钮下方
      builder: (buttonContext) => IconButton(
        icon: const Icon(Icons.bedtime_rounded, size: 18),
        color: Theme.of(context).colorScheme.primary,
        tooltip: SleepTimerMenu.statusLabel(context.l10n, timer),
        style: style,
        onPressed: () => SleepTimerMenu.show(buttonContext),
      ),
    );
  }
}
