import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/constants/app_info.dart';
import '../../../../l10n/l10n.dart';
import '../../../../services/updates/update_release.dart';
import '../../../../services/updates/update_service.dart';
import '../../../widgets/update_prompt.dart';
import '../widgets/settings_menu_field.dart';
import '../widgets/settings_section.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

class UpdateSection extends StatelessWidget {
  const UpdateSection({super.key});

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
          title: '${l.updatesCurrent} · ${AppInfo.releaseTag}',
          subtitle: service.release == null ? null : '${l.updatesAvailable} ${service.release!.tag}',
          below: Wrap(spacing: 8, runSpacing: 8, children: [
            M3EButton.icon(
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
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(service.error == null ? l.updatesUpToDate : l.updatesFailed)));
                }
              },
              icon: const Icon(Icons.system_update_rounded),
              label: Text(service.status == UpdateStatus.checking ? l.updatesChecking : l.updatesCheck),
            ),
            if (service.release != null)
              M3EButton.text(onPressed: () => showUpdateDialog(context, service), child: Text(l.updatesDetails)),
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
