import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/constants/app_info.dart';
import '../../../../l10n/l10n.dart';
import '../../../../services/updates/update_release.dart';
import '../../../../services/updates/update_service.dart';
import '../../../widgets/app_modal.dart';
import '../../../widgets/flutify_dialog.dart';
import '../../../widgets/toast/app_toast.dart';
import '../../../widgets/update_prompt.dart';
import '../widgets/settings_menu_field.dart';
import '../widgets/settings_section.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import '../../../widgets/app_button.dart';

class UpdateSection extends StatelessWidget {
  const UpdateSection({super.key});

  /// 切到自测版前必须先确认：那是开发者自测用的，不能拿来正常使用。
  static Future<void> _changeChannel(
    BuildContext context,
    UpdateService service,
    UpdateChannel channel,
  ) async {
    if (channel == service.channel) return;
    if (channel == UpdateChannel.selfTest) {
      final l = context.l10n;
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialogContext) => FlutifyDialog(
          icon: Icon(
            Icons.warning_amber_rounded,
            color: Theme.of(dialogContext).colorScheme.error,
          ),
          title: l.updatesSelfTestWarningTitle,
          content: Material(
            type: MaterialType.transparency,
            child: Text(l.updatesSelfTestWarning),
          ),
          actions: [
            AppButton.text(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l.commonCancel),
            ),
            AppButton.filled(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l.updatesSelfTestConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await service.setChannel(channel);
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<UpdateService?>();
    if (service == null) return const SizedBox.shrink();
    final l = context.l10n;
    return SettingsSection(
      title: l.updatesTitle,
      footer: l.updatesHint,
      children: [
        SettingsTile(
          title: l.updatesMode,
          below: SettingsMenuField<UpdateMode>(
            semanticLabel: l.updatesMode,
            icon: Icons.update_rounded,
            value: service.mode,
            options: [
              SettingsMenuOption(value: UpdateMode.manual, label: l.updatesManual),
              SettingsMenuOption(value: UpdateMode.automatic, label: l.updatesAutomatic),
              SettingsMenuOption(value: UpdateMode.disabled, label: l.updatesDisabled),
            ],
            onChanged: service.status == UpdateStatus.installing ? null : (mode) => service.setMode(mode),
          ),
        ),
        SettingsTile(
          title: l.updatesChannel,
          subtitle: l.updatesChannelHint,
          below: SettingsMenuField<UpdateChannel>(
            semanticLabel: l.updatesChannel,
            icon: Icons.alt_route_rounded,
            value: service.channel,
            options: [
              SettingsMenuOption(value: UpdateChannel.release, label: l.updatesChannelRelease),
              SettingsMenuOption(value: UpdateChannel.beta, label: l.updatesChannelBeta),
              SettingsMenuOption(value: UpdateChannel.selfTest, label: l.updatesChannelSelfTest),
            ],
            onChanged: service.status == UpdateStatus.installing
                ? null
                : (channel) => _changeChannel(context, service, channel),
          ),
        ),
        SettingsTile(
          title: '${l.updatesCurrent} · ${AppInfo.releaseTag}'
              '${service.currentVersion.build > 0 ? ' · ${l.updatesBuild(service.currentVersion.build)}' : ''}',
          subtitle: service.release == null ? null : '${l.updatesAvailable} ${service.release!.tag}',
          below: Wrap(spacing: 8, runSpacing: 8, children: [
            AppButton.icon(
                      style: M3EButtonStyle.tonal,
              onPressed: service.busy ? null : () async {
                if (service.release != null && service.status == UpdateStatus.ready) {
                  await showUpdateDialog(context, service);
                  return;
                }
                await service.check(manual: true);
                if (!context.mounted) return;
                if (service.release != null) {
                  await showUpdateDialog(context, service);
                } else {
                  AppToast.plain(context, service.error == null ? l.updatesUpToDate : l.updatesFailed);
                }
              },
              icon: const Icon(Icons.system_update_rounded),
              label: Text(service.status == UpdateStatus.checking ? l.updatesChecking : l.updatesCheck),
            ),
            if (service.release != null)
              AppButton.text(onPressed: () => showUpdateDialog(context, service), child: Text(l.updatesDetails)),
          ]),
        ),
        if (service.status == UpdateStatus.downloading || service.status == UpdateStatus.installing)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: UpdateProgress(service: service)),
        if (service.error != null)
          SettingsTile(title: l.updatesFailed, onTap: () => openUpdatePage(context, service)),
      ],
    );
  }
}
