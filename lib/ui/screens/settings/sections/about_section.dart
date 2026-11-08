import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_info.dart';
import '../../../../core/utils/file_log.dart';
import '../../../../l10n/l10n.dart';
import '../../../shell/shell_breakpoints.dart';
import '../../../widgets/toast/app_toast.dart';
import '../widgets/settings_section.dart';
import '../widgets/shortcuts_dialog.dart';

/// 关于：版本号、键盘快捷键（仅桌面布局）、开源许可（Flutter 自带许可页，含所有依赖包）。
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final desktop = ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
    final chevron = Icon(Icons.chevron_right_rounded, color: muted);

    return SettingsSection(
      title: l10n.settingsAboutSection,
      children: [
        SettingsTile(
          title: l10n.settingsVersion,
          trailing: Text(AppInfo.displayVersion, style: TextStyle(color: muted)),
        ),
        if (desktop)
          SettingsTile(title: l10n.settingsShortcuts, trailing: chevron, onTap: () => ShortcutsDialog.show(context)),
        SettingsTile(
          title: l10n.settingsCopyLog,
          subtitle: l10n.settingsCopyLogSubtitle,
          trailing: Icon(Icons.content_copy_rounded, color: muted, size: 20),
          onTap: () => _copyLog(context),
        ),
        SettingsTile(
          title: l10n.settingsLicenses,
          trailing: chevron,
          onTap: () => showLicensePage(
            context: context,
            applicationName: AppInfo.name,
            applicationVersion: AppInfo.displayVersion,
          ),
        ),
      ],
    );
  }

  /// 把本次运行的日志末尾复制到剪贴板，方便用户粘贴反馈（手机上没有别的取日志途径）。
  static Future<void> _copyLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    final text = await readLogTail();
    if (text.isEmpty) {
      AppToast.showOn(messenger, l10n.settingsCopyLogEmpty, tone: ToastTone.warning);
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    AppToast.showOn(messenger, l10n.settingsCopyLogDone, tone: ToastTone.success);
  }
}
