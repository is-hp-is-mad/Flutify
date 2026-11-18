import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../../core/constants/app_info.dart';
import '../../../../core/utils/file_log.dart';
import '../../../../l10n/l10n.dart';
import '../../../shell/shell_breakpoints.dart';
import '../../../widgets/app_button.dart';
import '../../../widgets/app_modal.dart';
import '../../../widgets/flutify_dialog.dart';
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
          title: l10n.settingsExportLog,
          subtitle: l10n.settingsExportLogSubtitle,
          trailing: Icon(Icons.save_alt_rounded, color: muted, size: 20),
          onTap: () => _exportLog(context),
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

  /// 导出完整诊断日志为 `.log` 或 `.txt` 文件。
  static Future<void> _exportLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    final text = await readFullLog();
    if (text.isEmpty) {
      AppToast.showOn(messenger, l10n.settingsCopyLogEmpty, tone: ToastTone.warning);
      return;
    }
    if (!context.mounted) return;
    final ext = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => FlutifyDialog(
        icon: const Icon(Icons.save_alt_rounded),
        title: l10n.settingsExportLogFormat,
        content: Material(
          type: MaterialType.transparency,
          child: Text(l10n.settingsExportLogSubtitle),
        ),
        actions: [
          AppButton.text(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel),
          ),
          AppButton.text(
            onPressed: () => Navigator.pop(dialogContext, 'txt'),
            child: const Text('.txt'),
          ),
          AppButton.filled(
            onPressed: () => Navigator.pop(dialogContext, 'log'),
            child: const Text('.log'),
          ),
        ],
      ),
    );
    if (ext == null) return;

    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final fileName = 'flutify-log-$stamp.$ext';

    try {
      String? targetPath;
      if (!Platform.isAndroid && !Platform.isIOS) {
        final location = await getSaveLocation(
          suggestedName: fileName,
          acceptedTypeGroups: [
            XTypeGroup(
              label: ext == 'txt' ? 'Text' : 'Log',
              extensions: [ext],
            ),
          ],
        );
        if (location == null) return;
        targetPath = location.path;
      } else {
        final candidates = <Directory?>[
          await getDownloadsDirectory(),
          if (Platform.isAndroid) await getExternalStorageDirectory(),
          await getApplicationDocumentsDirectory(),
        ];
        for (final dir in candidates) {
          if (dir == null) continue;
          try {
            await dir.create(recursive: true);
            final candidate = File(p.join(dir.path, fileName));
            await candidate.writeAsString(text, flush: true);
            targetPath = candidate.path;
            break;
          } catch (_) {
            // 部分 Android 目录可能无直接写入权限，回退到应用外部文件目录
          }
        }
        if (targetPath == null) {
          throw const FileSystemException('No writable export directory');
        }
        AppToast.showOn(
          messenger,
          l10n.settingsExportLogDone(targetPath),
          tone: ToastTone.success,
        );
        return;
      }
      await File(targetPath).writeAsString(text, flush: true);
      AppToast.showOn(
        messenger,
        l10n.settingsExportLogDone(targetPath),
        tone: ToastTone.success,
      );
    } catch (e) {
      debugPrint('[LogExport] 导出日志失败: $e');
      AppToast.showOn(messenger, l10n.settingsExportLogFailed, tone: ToastTone.error);
    }
  }
}
