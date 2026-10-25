import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/appearance.dart';
import '../../../../providers/appearance_provider.dart';
import '../widgets/glass_preview.dart';
import '../widgets/hyper_glass_preview.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';
import '../widgets/settings_slider_tile.dart';

/// 材质：在「伪液态玻璃」和「柔光玻璃（Beta）」之间切换，各自有不同的预览和选项。
///
/// 伪液态玻璃：实时预览 + 模糊强度 + 不透明度；拖动滑杆时只把草稿值交给预览（局部重绘），
/// 松手才写入全局外观。柔光玻璃：动态预览（玻璃卡片 + 可展开的模糊菜单），选项待定。
class GlassSection extends StatefulWidget {
  const GlassSection({super.key});

  @override
  State<GlassSection> createState() => _GlassSectionState();
}

class _GlassSectionState extends State<GlassSection> {
  double? _blurDraft;
  double? _opacityDraft;

  static String _percent(double v) => '${(v * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppearanceProvider>();
    final settings = context.select<AppearanceProvider, AppearanceSettings>((p) => p.settings);
    final l10n = context.l10n;

    return SettingsSection(
      title: l10n.settingsGlassSection,
      children: [
        SettingsTile(
          title: l10n.settingsGlassMaterial,
          below: SettingsSegmented<GlassMaterial>(
            values: GlassMaterial.values,
            selected: settings.glassMaterial,
            labelOf: (m) => switch (m) {
              GlassMaterial.liquid => l10n.settingsGlassMaterialLiquid,
              GlassMaterial.hyper => l10n.settingsGlassMaterialHyper,
            },
            onChanged: (m) => provider.update(settings.copyWith(glassMaterial: m)),
          ),
        ),
        if (settings.glassMaterial == GlassMaterial.hyper) ...[
          const Padding(
            padding: EdgeInsets.all(12),
            child: HyperGlassPreview(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              l10n.settingsHyperGlassNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ] else ...[
        Padding(
          padding: const EdgeInsets.all(12),
          child: GlassPreview(blur: _blurDraft, opacity: _opacityDraft),
        ),
        SettingsSliderTile(
          title: l10n.settingsGlassBlur,
          labelOf: _percent,
          value: settings.glassBlur,
          divisions: 20,
          minIcon: Icons.blur_off_rounded,
          maxIcon: Icons.blur_on_rounded,
          onPreview: (v) => setState(() => _blurDraft = v),
          onChanged: (v) => provider.update(settings.copyWith(glassBlur: v)),
        ),
        SettingsSliderTile(
          title: l10n.settingsGlassOpacity,
          labelOf: _percent,
          value: settings.glassOpacity,
          divisions: 20,
          minIcon: Icons.circle_outlined,
          maxIcon: Icons.circle_rounded,
          onPreview: (v) => setState(() => _opacityDraft = v),
          onChanged: (v) => provider.update(settings.copyWith(glassOpacity: v)),
        ),
        ],
      ],
    );
  }
}
