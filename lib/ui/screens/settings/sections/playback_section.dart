import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/playback_state.dart' show SpotifyRepeatMode;
import '../../../../providers/playback_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';
import '../widgets/settings_slider_tile.dart';

/// 播放：连续多首无法播放时自动暂停（默认开启）、音量均衡、歌曲间淡入淡出。
///
/// 都只作用于本机播放；遥控其他设备（Spotify Connect）时由对方设备自己的设置决定。
class PlaybackSection extends StatelessWidget {
  const PlaybackSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final playback = context.read<PlaybackProvider>();
    final preferences = context.read<PreferencesProvider>();
    final canvasEnabled = context.select<PreferencesProvider, bool>(
      (p) => p.prefs.canvasEnabled,
    );
    final defaultRepeat = context
        .select<PreferencesProvider, SpotifyRepeatMode>(
          (p) => p.prefs.defaultRepeatMode,
        );
    final (pauseAfterFailures, normalize, fadeSeconds) = context
        .select<PlaybackProvider, (bool, bool, int)>(
          (p) => (p.pauseAfterFailures, p.normalizeVolume, p.fadeSeconds),
        );

    return SettingsSection(
      title: l10n.settingsPlaybackSection,
      children: [
        SettingsSwitchTile(
          title: l10n.settingsCanvas,
          subtitle: l10n.settingsCanvasSubtitle,
          value: canvasEnabled,
          onChanged: (v) =>
              preferences.update(preferences.prefs.copyWith(canvasEnabled: v)),
        ),
        SettingsTile(
          title: l10n.settingsDefaultRepeat,
          subtitle: l10n.settingsDefaultRepeatSubtitle,
          below: SettingsSegmented<SpotifyRepeatMode>(
            values: SpotifyRepeatMode.values,
            labelOf: (v) => switch (v) {
              SpotifyRepeatMode.off => l10n.settingsRepeatOff,
              SpotifyRepeatMode.context => l10n.settingsRepeatList,
              SpotifyRepeatMode.track => l10n.settingsRepeatTrack,
            },
            selected: defaultRepeat,
            // 除了存起来，还要当场交给播放器：它才是循环方式的实际持有者。
            // 否则用户在设置里选完，要等到下次启动（甚至切歌单）才看到效果。
            onChanged: (v) {
              preferences.update(
                preferences.prefs.copyWith(defaultRepeatMode: v),
              );
              playback.updateDefaultRepeatMode(v);
            },
          ),
        ),
        SettingsSwitchTile(
          title: l10n.settingsPauseAfterFailures,
          subtitle: l10n.settingsPauseAfterFailuresSubtitle(
            PlaybackProvider.failureLimit,
          ),
          value: pauseAfterFailures,
          onChanged: playback.setPauseAfterFailures,
        ),
        SettingsSwitchTile(
          title: l10n.settingsNormalize,
          subtitle: l10n.settingsNormalizeSubtitle,
          value: normalize,
          onChanged: playback.setNormalizeVolume,
        ),
        SettingsSliderTile(
          title: l10n.settingsFade,
          subtitle: l10n.settingsFadeSubtitle,
          value: fadeSeconds.toDouble(),
          max: PlaybackProvider.maxFadeSeconds.toDouble(),
          divisions: PlaybackProvider.maxFadeSeconds,
          labelOf: (v) => v.round() == 0
              ? l10n.settingsOff
              : l10n.settingsSeconds(v.round()),
          onChanged: (v) => playback.setFadeSeconds(v.round()),
        ),
      ],
    );
  }
}
