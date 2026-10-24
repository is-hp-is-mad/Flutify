import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../providers/appearance_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/taskbar_lyrics/taskbar_lyrics_controls.dart';
import '../widgets/custom_color_dialog.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';
import '../widgets/settings_slider_tile.dart';
import '../widgets/taskbar_lyrics_preview.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton, M3EButtonStyle;

/// 任务栏歌词（Windows）：开关、文字颜色（自动 / 白 / 黑 / 强调色 / 自定义）、不透明度，顶部带实时预览。
///
/// 没有任务栏歌词能力（非 Windows、测试）时不显示整个分组。
class TaskbarLyricsSection extends StatelessWidget {
  const TaskbarLyricsSection({super.key});

  static bool _available(BuildContext context) {
    try {
      return context.read<TaskbarLyricsControls?>() != null;
    } on ProviderNotFoundException {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_available(context)) return const SizedBox.shrink();
    final l10n = context.l10n;
    final provider = context.read<PreferencesProvider>();
    final prefs = context.select<PreferencesProvider, AppPreferences>((p) => p.prefs);
    void update(AppPreferences Function(AppPreferences p) change) => provider.update(change(provider.prefs));

    // 设置页预览跟随应用当前主题；实际任务栏仍由原生端跟随系统。
    final lightTaskbar = Theme.of(context).brightness == Brightness.light;
    final accent = context.select<AppearanceProvider, Color>((a) => a.accent);
    final color = switch (prefs.taskbarLyricsColor) {
      TaskbarLyricsColor.auto => lightTaskbar ? const Color(0xFF141414) : Colors.white,
      TaskbarLyricsColor.white => Colors.white,
      TaskbarLyricsColor.black => const Color(0xFF141414),
      TaskbarLyricsColor.accent => _accentFor(context, accent, lightTaskbar),
      TaskbarLyricsColor.custom => Color(prefs.taskbarLyricsCustomColor),
    };

    return SettingsSection(
      title: l10n.settingsTaskbarLyricsSection,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
          child: AnimatedOpacity(
            opacity: prefs.taskbarLyrics ? 1 : 0.45,
            duration: const Duration(milliseconds: 200),
            child: TaskbarLyricsPreview(
              color: color,
              opacity: prefs.taskbarLyricsOpacity / 100,
              lightTaskbar: lightTaskbar,
              fontScale: prefs.taskbarLyricsFontScale / 100,
            ),
          ),
        ),
        SettingsSwitchTile(
          title: l10n.settingsTaskbarLyrics,
          subtitle: l10n.settingsTaskbarLyricsSubtitle,
          value: prefs.taskbarLyrics,
          onChanged: (v) => update((p) => p.copyWith(taskbarLyrics: v)),
        ),
        if (prefs.taskbarLyrics) ...[
          SettingsTile(
            title: l10n.settingsTaskbarLyricsColor,
            below: SettingsSegmented<TaskbarLyricsColor>(
              values: TaskbarLyricsColor.values,
              labelOf: (v) => switch (v) {
                TaskbarLyricsColor.auto => l10n.taskbarLyricsColorAuto,
                TaskbarLyricsColor.white => l10n.taskbarLyricsColorWhite,
                TaskbarLyricsColor.black => l10n.taskbarLyricsColorBlack,
                TaskbarLyricsColor.accent => l10n.taskbarLyricsColorAccent,
                TaskbarLyricsColor.custom => l10n.taskbarLyricsColorCustom,
              },
              selected: prefs.taskbarLyricsColor,
              onChanged: (v) => update((p) => p.copyWith(taskbarLyricsColor: v)),
            ),
          ),
          if (prefs.taskbarLyricsColor == TaskbarLyricsColor.custom)
            SettingsTile(
              title: l10n.settingsTaskbarLyricsCustomColor,
              trailing: _ColorButton(
                color: Color(prefs.taskbarLyricsCustomColor),
                label: l10n.settingsTaskbarLyricsChangeColor,
                onTap: () async {
                  final picked = await CustomColorDialog.show(context, initial: Color(prefs.taskbarLyricsCustomColor));
                  if (picked != null) update((p) => p.copyWith(taskbarLyricsCustomColor: picked.toARGB32()));
                },
              ),
            ),
          SettingsSliderTile(
            title: l10n.settingsTaskbarLyricsOpacity,
            value: prefs.taskbarLyricsOpacity.toDouble(),
            min: AppPreferences.minTaskbarLyricsOpacity.toDouble(),
            max: 100,
            divisions: 17,
            minIcon: Icons.opacity_rounded,
            maxIcon: Icons.circle,
            labelOf: (v) => '${v.round()}%',
            onChanged: (v) => update((p) => p.copyWith(taskbarLyricsOpacity: v.round())),
          ),
          SettingsSliderTile(
            title: l10n.settingsTaskbarLyricsFontSize,
            value: prefs.taskbarLyricsFontScale.toDouble(),
            min: AppPreferences.minTaskbarLyricsFontScale.toDouble(),
            max: AppPreferences.maxTaskbarLyricsFontScale.toDouble(),
            divisions: 10,
            minIcon: Icons.text_decrease_rounded,
            maxIcon: Icons.text_increase_rounded,
            labelOf: (v) => '${v.round()}%',
            onChanged: (v) => update((p) => p.copyWith(taskbarLyricsFontScale: v.round())),
          ),
        ],
      ],
    );
  }

  /// 与原生一致：深色任务栏用强调色的亮色调，浅色任务栏用暗色调。
  static Color _accentFor(BuildContext context, Color accent, bool lightTaskbar) {
    final appearance = context.read<AppearanceProvider>();
    return appearance.theme(lightTaskbar ? Brightness.light : Brightness.dark).colorScheme.primary;
  }
}

/// 当前自定义色的圆点 + 「更改」。
class _ColorButton extends StatelessWidget {
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _ColorButton({required this.color, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return M3EButton.icon(style: M3EButtonStyle.text,
      onPressed: onTap,
      icon: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: colorScheme.outlineVariant, width: 1.5),
        ),
      ),
      label: Text(label),
    );
  }
}
