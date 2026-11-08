import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/appearance.dart';
import '../../../../providers/appearance_provider.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';
import '../widgets/settings_slider_tile.dart';

/// 文字与形状：字号（带示例文字）+ 圆角风格。
///
/// 拖动字号滑杆时只有示例文字按草稿字号缩放，松手才应用到全局。
class TextShapeSection extends StatefulWidget {
  const TextShapeSection({super.key});

  @override
  State<TextShapeSection> createState() => _TextShapeSectionState();
}

class _TextShapeSectionState extends State<TextShapeSection> {
  /// 字号档位：0.85 ~ 1.30，每档 5%。
  static const int _fontDivisions = 9;

  double? _fontDraft;

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppearanceProvider>();
    final settings = context.select<AppearanceProvider, AppearanceSettings>((p) => p.settings);
    final l10n = context.l10n;
    final theme = Theme.of(context);

    // 全局 textScaler = 系统字号 × 已生效字号；示例文字换成 系统字号 × 草稿字号
    Widget preview = Text(
      l10n.settingsFontPreview,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final draft = _fontDraft;
    if (draft != null) {
      final system = MediaQuery.textScalerOf(context).scale(1) / settings.fontScale;
      preview = MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(system * draft)),
        child: preview,
      );
    }

    return SettingsSection(
      title: l10n.settingsTextShapeSection,
      children: [
        SettingsSliderTile(
          title: l10n.settingsFontScale,
          labelOf: (v) => '${(v * 100).round()}%',
          value: settings.fontScale,
          min: AppearanceSettings.minFontScale,
          max: AppearanceSettings.maxFontScale,
          divisions: _fontDivisions,
          minIcon: Icons.text_decrease_rounded,
          maxIcon: Icons.text_increase_rounded,
          onPreview: (v) => setState(() => _fontDraft = v),
          onChanged: (v) => provider.update(settings.copyWith(fontScale: v)),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 14), child: preview),
        SettingsTile(
          title: l10n.settingsCornerStyle,
          below: SettingsSegmented<CornerStyle>(
            values: CornerStyle.values,
            selected: settings.cornerStyle,
            labelOf: (style) => switch (style) {
              CornerStyle.rounded => l10n.settingsCornerRounded,
              CornerStyle.standard => l10n.settingsCornerStandard,
              CornerStyle.square => l10n.settingsCornerSquare,
            },
            onChanged: (style) => provider.update(settings.copyWith(cornerStyle: style)),
          ),
        ),
      ],
    );
  }
}
