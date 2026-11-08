import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/utils/local_device_name.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../providers/connect_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/connect/receiver/connect_receiver.dart';
import '../widgets/device_name_field.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_slider_tile.dart';

/// Spotify Connect：总开关 + 启动时同步播放状态 + 远程歌词提前量。
///
/// 关闭后立即断开（不再显示其他设备的播放、播放栏回到本机模式）；重新打开立即接入。
/// 提前量只影响歌词切行，不改动进度条：远程进度由服务端快照推算，网络延迟会让歌词慢半拍。
class ConnectSection extends StatelessWidget {
  const ConnectSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final provider = context.read<PreferencesProvider>();
    final (enabled, leadMs, reportOnLaunch) = context.select<PreferencesProvider, (bool, int, bool)>(
      (p) => (p.prefs.connectEnabled, p.prefs.remoteLyricsLeadMs, p.prefs.connectReportOnLaunch),
    );
    final deviceName = context.select<PreferencesProvider, String>((p) => p.prefs.connectDeviceName);
    const maxSeconds = AppPreferences.maxRemoteLyricsLeadMs / 1000;

    return SettingsSection(
      title: l10n.settingsConnectSection,
      children: [
        SettingsSwitchTile(
          title: l10n.settingsConnectEnabled,
          subtitle: l10n.settingsConnectEnabledSubtitle,
          value: enabled,
          onChanged: (v) {
            provider.update(provider.prefs.copyWith(connectEnabled: v));
            Provider.of<ConnectProvider?>(context, listen: false)?.sessionChanged();
          },
        ),
        if (enabled)
          SettingsTile(
            title: l10n.settingsConnectDeviceName,
            subtitle: l10n.settingsConnectDeviceNameSubtitle,
            below: DeviceNameField(
              name: deviceName,
              hint: cachedLocalDeviceName.isNotEmpty ? cachedLocalDeviceName : ConnectReceiver.defaultDeviceName,
              onApply: (v) => provider.update(provider.prefs.copyWith(connectDeviceName: v)),
              suggestion: localDeviceName,
              suggestionLabel: l10n.settingsConnectUseDeviceName,
            ),
          ),
        if (enabled)
          SettingsSwitchTile(
            title: l10n.settingsConnectReportOnLaunch,
            subtitle: l10n.settingsConnectReportOnLaunchSubtitle,
            value: reportOnLaunch,
            onChanged: (v) => provider.update(provider.prefs.copyWith(connectReportOnLaunch: v)),
          ),
        if (enabled)
          SettingsSliderTile(
            title: l10n.settingsRemoteLyricsLead,
            subtitle: l10n.settingsRemoteLyricsLeadSubtitle,
            value: leadMs / 1000,
            min: -maxSeconds,
            max: maxSeconds,
            divisions: 40,
            labelOf: _formatSeconds,
            onChanged: (v) => provider.update(provider.prefs.copyWith(remoteLyricsLeadMs: (v * 1000).round())),
          ),
      ],
    );
  }

  /// 「+0.3s」「-1.2s」「0s」：带符号，一位小数。
  static String _formatSeconds(double seconds) {
    final rounded = (seconds * 10).round() / 10;
    if (rounded == 0) return '0s';
    return '${rounded > 0 ? '+' : ''}${rounded.toStringAsFixed(1)}s';
  }
}
