import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../l10n/l10n.dart';
import '../../../providers/sleep_timer_provider.dart';
import '../../shell/shell_breakpoints.dart';
import '../menu/desktop_menu.dart';
import '../toast/app_toast.dart';
import '../app_modal.dart';

/// 睡眠定时器选择：桌面端在 [position] 弹出菜单，移动端底部面板。
///
/// 选项：5 / 10 / 15 / 30 / 45 分钟、1 小时、本首结束时；已开启时当前项打勾，并多一项「关闭定时器」。
class SleepTimerMenu {
  SleepTimerMenu._();

  static const Object _off = Object();

  static String presetLabel(AppLocalizations l10n, SleepTimerPreset preset) => switch (preset) {
    SleepTimerPreset.endOfTrack => l10n.sleepTimerEndOfTrack,
    SleepTimerPreset.hour1 => l10n.sleepTimerHour,
    _ => l10n.sleepTimerMinutes(preset.duration!.inMinutes),
  };

  /// 当前状态的一句话描述（播放栏指示器提示、菜单标题）；未开启时为 null。
  static String? statusLabel(AppLocalizations l10n, SleepTimerProvider timer) {
    if (!timer.active) return null;
    final remaining = timer.remaining;
    if (remaining == null) return l10n.sleepTimerEndOfTrackActive;
    return l10n.sleepTimerRemaining(Formatters.formatDuration(remaining));
  }

  static Future<void> show(BuildContext context, {Offset? position}) async {
    final timer = context.read<SleepTimerProvider?>();
    if (timer == null) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);

    final Object? picked = GlassMenuScope.of(context) || ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)
        ? await DesktopMenu.show<Object>(context, position ?? DesktopMenu.anchorOf(context), [
            for (final preset in SleepTimerPreset.values)
              DesktopMenu.check<Object>(preset, presetLabel(l10n, preset), checked: timer.preset == preset),
            if (timer.active) ...[
              DesktopMenu.divider,
              DesktopMenu.item<Object>(_off, Icons.timer_off_outlined, l10n.sleepTimerOff),
            ],
          ])
        : await showAppBottomSheet<Object>(
            context: context,
            useRootNavigator: true,
            builder: (ctx) => _SleepTimerSheet(timer: timer),
          );

    if (picked == null) return;
    if (identical(picked, _off)) {
      timer.cancel();
      AppToast.showOn(messenger, l10n.toastSleepTimerOff, icon: Icons.bedtime_off_rounded);
    } else if (picked is SleepTimerPreset) {
      timer.start(picked);
      AppToast.showOn(
        messenger,
        l10n.toastSleepTimerSet(presetLabel(l10n, picked)),
        icon: Icons.bedtime_rounded,
        tone: ToastTone.success,
      );
    }
  }
}

class _SleepTimerSheet extends StatelessWidget {
  final SleepTimerProvider timer;

  const _SleepTimerSheet({required this.timer});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final primary = Theme.of(context).colorScheme.primary;
    final status = SleepTimerMenu.statusLabel(l10n, timer);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(l10n.sleepTimer, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(status, style: TextStyle(color: primary, fontWeight: FontWeight.w600)),
              ),
            for (final preset in SleepTimerPreset.values)
              ListTile(
                title: Text(SleepTimerMenu.presetLabel(l10n, preset)),
                trailing: timer.preset == preset ? Icon(Icons.check_rounded, color: primary) : null,
                onTap: () => Navigator.pop(context, preset),
              ),
            if (timer.active)
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: Text(l10n.sleepTimerOff),
                onTap: () => Navigator.pop(context, SleepTimerMenu._off),
              ),
          ],
        ),
      ),
    );
  }
}
