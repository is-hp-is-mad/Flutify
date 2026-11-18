import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/appearance.dart';
import '../../../../providers/appearance_provider.dart';
import '../widgets/settings_menu_field.dart';
import '../widgets/settings_section.dart';

/// 外观：主题模式（跟随系统 / 浅色 / 深色）+ 纯黑背景。
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppearanceProvider>();
    final settings = context.select<AppearanceProvider, AppearanceSettings>((p) => p.settings);
    final l10n = context.l10n;

    return SettingsSection(
      title: l10n.settingsAppearanceSection,
      children: [
        SettingsTile(
          title: l10n.settingsThemeMode,
          below: SettingsMenuField<ThemeMode>(
            semanticLabel: l10n.settingsThemeMode,
            icon: Icons.brightness_6_rounded,
            value: settings.themeMode,
            options: [
              SettingsMenuOption(value: ThemeMode.system, label: l10n.settingsThemeSystem, icon: Icons.brightness_auto_rounded),
              SettingsMenuOption(value: ThemeMode.light, label: l10n.settingsThemeLight, icon: Icons.light_mode_rounded),
              SettingsMenuOption(value: ThemeMode.dark, label: l10n.settingsThemeDark, icon: Icons.dark_mode_rounded),
            ],
            onChanged: (mode) => provider.update(settings.copyWith(themeMode: mode)),
          ),
        ),
        SettingsSwitchTile(
          title: l10n.settingsPureBlack,
          subtitle: l10n.settingsPureBlackSubtitle,
          value: settings.pureBlack,
          onChanged: (v) => provider.update(settings.copyWith(pureBlack: v)),
        ),
      ],
    );
  }
}
