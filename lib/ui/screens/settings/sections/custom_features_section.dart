import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../widgets/app_button.dart';
import '../../../widgets/app_modal.dart';
import '../../../widgets/flutify_dialog.dart';
import '../widgets/settings_section.dart';

/// 自定义功能：智能上一首、歌单 / 专辑曲目行的滑动手势、歌词界面常亮。默认都关闭。
///
/// 智能上一首只作用于本机播放；遥控其他设备时「上一首」的行为由对方设备决定。
class CustomFeaturesSection extends StatelessWidget {
  const CustomFeaturesSection({super.key});

  /// 开启常亮前先提醒耗电与 OLED 烧屏风险；关闭不需要确认。
  static Future<void> _setLyricsKeepAwake(
    BuildContext context,
    bool value,
  ) async {
    final preferences = context.read<PreferencesProvider>();
    if (value) {
      final l10n = context.l10n;
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialogContext) => FlutifyDialog(
          title: l10n.settingsLyricsKeepAwakeWarningTitle,
          icon: const Icon(Icons.warning_amber_rounded),
          content: Material(
            type: MaterialType.transparency,
            child: Text(l10n.settingsLyricsKeepAwakeWarningMessage),
          ),
          actions: [
            AppButton.text(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.commonCancel),
            ),
            AppButton.filled(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.settingsLyricsKeepAwakeEnable),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    preferences.update(preferences.prefs.copyWith(lyricsKeepScreenOn: value));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final playback = context.read<PlaybackProvider>();
    final preferences = context.read<PreferencesProvider>();
    final smartPrevious = context.select<PlaybackProvider, bool>(
      (p) => p.smartPrevious,
    );
    final (swipeToPlayNext, swipeToLibrary, lyricsKeepAwake) = context
        .select<PreferencesProvider, (bool, bool, bool)>(
          (p) => (
            p.prefs.swipeToPlayNext,
            p.prefs.swipeToLibrary,
            p.prefs.lyricsKeepScreenOn,
          ),
        );

    return SettingsSection(
      title: l10n.settingsCustomSection,
      children: [
        SettingsSwitchTile(
          title: l10n.settingsSmartPrevious,
          subtitle: l10n.settingsSmartPreviousSubtitle,
          value: smartPrevious,
          onChanged: playback.setSmartPrevious,
        ),
        SettingsSwitchTile(
          title: l10n.settingsSwipePlayNext,
          subtitle: l10n.settingsSwipePlayNextSubtitle,
          value: swipeToPlayNext,
          onChanged: (v) => preferences.update(
            preferences.prefs.copyWith(swipeToPlayNext: v),
          ),
        ),
        SettingsSwitchTile(
          title: l10n.settingsSwipeLibrary,
          subtitle: l10n.settingsSwipeLibrarySubtitle,
          value: swipeToLibrary,
          onChanged: (v) =>
              preferences.update(preferences.prefs.copyWith(swipeToLibrary: v)),
        ),
        SettingsSwitchTile(
          title: l10n.settingsLyricsKeepAwake,
          subtitle: l10n.settingsLyricsKeepAwakeSubtitle,
          value: lyricsKeepAwake,
          onChanged: (v) => _setLyricsKeepAwake(context, v),
        ),
      ],
    );
  }
}
