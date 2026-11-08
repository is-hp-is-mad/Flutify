import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/appearance.dart';
import '../../../../providers/appearance_provider.dart';
import '../widgets/accent_picker.dart';
import '../widgets/settings_section.dart';

/// 强调色：预设 / 自定义色板 + 跟随封面取色。
class AccentSection extends StatelessWidget {
  const AccentSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppearanceProvider>();
    final settings = context.select<AppearanceProvider, AppearanceSettings>((p) => p.settings);
    final l10n = context.l10n;

    return SettingsSection(
      title: l10n.settingsAccentSection,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
          child: AccentPicker(
            selected: settings.accent,
            dimmed: settings.dynamicAccent,
            onChanged: (color) => provider.update(settings.copyWith(accent: color)),
          ),
        ),
        SettingsSwitchTile(
          title: l10n.settingsDynamicAccent,
          subtitle: l10n.settingsDynamicAccentSubtitle,
          value: settings.dynamicAccent,
          onChanged: (v) => provider.update(settings.copyWith(dynamicAccent: v)),
        ),
      ],
    );
  }
}
