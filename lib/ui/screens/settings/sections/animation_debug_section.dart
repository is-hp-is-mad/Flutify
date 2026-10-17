import 'package:flutter/material.dart';

import '../../../../core/debug_toggles.dart';
import '../../../../l10n/l10n.dart';
import '../widgets/settings_section.dart';

/// 动画调试：临时关闭某一类动画 / 特效，用来定位卡顿来源。
///
/// 只对本次运行有效（存在内存里），重启应用后自动恢复，不会因为忘了而一直关着。
class AnimationDebugSection extends StatelessWidget {
  const AnimationDebugSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: DebugToggles.instance,
      builder: (context, _) {
        final toggles = DebugToggles.instance;

        Widget row(DebugToggle toggle, String title, String subtitle) =>
            SettingsSwitchTile(
              title: title,
              subtitle: subtitle,
              value: toggles.isOff(toggle),
              // 构建时已用 --dart-define 关掉的项运行时不能再打开
              onChanged: toggle.compileTimeOff
                  ? (_) {}
                  : (v) => toggles.setOff(toggle, v),
            );

        return SettingsSection(
          title: l10n.settingsAnimDebugSection,
          footer: l10n.settingsAnimDebugFooter,
          children: [
            row(
              DebugToggle.allMotion,
              l10n.settingsAnimDebugAllMotion,
              l10n.settingsAnimDebugAllMotionSubtitle,
            ),
            row(
              DebugToggle.lyricsLineMotion,
              l10n.settingsAnimDebugLyricsLine,
              l10n.settingsAnimDebugLyricsLineSubtitle,
            ),
            row(
              DebugToggle.lyricsScroll,
              l10n.settingsAnimDebugLyricsScroll,
              l10n.settingsAnimDebugLyricsScrollSubtitle,
            ),
            row(
              DebugToggle.lyricsMask,
              l10n.settingsAnimDebugLyricsMask,
              l10n.settingsAnimDebugLyricsMaskSubtitle,
            ),
            row(
              DebugToggle.glassBackdrop,
              l10n.settingsAnimDebugGlass,
              l10n.settingsAnimDebugGlassSubtitle,
            ),
            row(
              DebugToggle.flowingBackground,
              l10n.settingsAnimDebugBackground,
              l10n.settingsAnimDebugBackgroundSubtitle,
            ),
            // 没有运行时关闭项时置灰、不可点
            Opacity(
              opacity: toggles.anyOff ? 1 : 0.45,
              child: SettingsTile(
                title: l10n.settingsAnimDebugResetAll,
                trailing: Icon(
                  Icons.restart_alt_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
                onTap: toggles.anyOff ? toggles.reset : null,
              ),
            ),
          ],
        );
      },
    );
  }
}
