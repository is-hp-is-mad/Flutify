import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/lyric_bridge/lyric_bridge_channel.dart';
import '../../../../services/lyric_bridge/lyric_metadata_controls.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';

/// 车机与状态栏歌词（Android）：蓝牙歌词（车机屏幕显示当前歌词行）与 Flyme 状态栏歌词。
///
/// 没有 [LyricMetadataControls]（非 Android、测试）时不显示整个分组。
class ExternalLyricsSection extends StatefulWidget {
  const ExternalLyricsSection({super.key});

  @override
  State<ExternalLyricsSection> createState() => _ExternalLyricsSectionState();
}

class _ExternalLyricsSectionState extends State<ExternalLyricsSection>
    with WidgetsBindingObserver {
  LyricMetadataControls? _controls;
  bool _permission = true;

  @override
  void initState() {
    super.initState();
    try {
      _controls = context.read<LyricMetadataControls?>();
    } on ProviderNotFoundException {
      _controls = null;
    }
    if (_controls == null) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_recheck());
  }

  @override
  void dispose() {
    if (_controls != null) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统授权页回来时重新检查权限并刷新设备列表。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_recheck());
  }

  Future<void> _recheck() async {
    final controls = _controls;
    if (controls == null) return;
    final granted = await controls.hasBluetoothPermission();
    if (!mounted) return;
    setState(() => _permission = granted);
    if (granted) await controls.reloadDevices();
  }

  @override
  Widget build(BuildContext context) {
    final controls = _controls;
    if (controls == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final provider = context.read<PreferencesProvider>();
    final prefs = context.select<PreferencesProvider, AppPreferences>(
      (p) => p.prefs,
    );
    void update(AppPreferences Function(AppPreferences p) change) =>
        provider.update(change(provider.prefs));

    final enabled = prefs.bluetoothLyrics != BluetoothLyricsMode.off;
    return SettingsSection(
      title: l10n.settingsExternalLyricsSection,
      children: [
        SettingsTile(
          title: l10n.settingsBluetoothLyrics,
          subtitle: l10n.settingsBluetoothLyricsSubtitle,
          below: SettingsSegmented<BluetoothLyricsMode>(
            values: BluetoothLyricsMode.values,
            labelOf: (v) => switch (v) {
              BluetoothLyricsMode.off => l10n.bluetoothLyricsOff,
              BluetoothLyricsMode.car => l10n.bluetoothLyricsCar,
              BluetoothLyricsMode.all => l10n.bluetoothLyricsAll,
            },
            selected: prefs.bluetoothLyrics,
            onChanged: (v) => update((p) => p.copyWith(bluetoothLyrics: v)),
          ),
        ),
        if (enabled) ...[
          SettingsSwitchTile(
            title: l10n.settingsBluetoothLyricsTranslation,
            subtitle: l10n.settingsBluetoothLyricsTranslationSubtitle,
            value: prefs.bluetoothLyricsTranslation,
            onChanged: (v) =>
                update((p) => p.copyWith(bluetoothLyricsTranslation: v)),
          ),
          if (!_permission)
            SettingsTile(
              title: l10n.settingsBluetoothPermission,
              subtitle: l10n.settingsBluetoothPermissionSubtitle,
              trailing: M3EButton.text(
                onPressed: () =>
                    unawaited(controls.requestBluetoothPermission()),
                child: Text(l10n.settingsBluetoothPermissionGrant),
              ),
            )
          else
            ValueListenableBuilder<List<BluetoothAudioDevice>>(
              valueListenable: controls.connectedDevices,
              builder: (context, devices, _) => _DeviceList(
                devices: devices,
                mode: prefs.bluetoothLyrics,
                manual: prefs.bluetoothLyricsDevices,
                onToggle: (address, on) => update((p) {
                  final next = {...p.bluetoothLyricsDevices};
                  on ? next.add(address) : next.remove(address);
                  return p.copyWith(bluetoothLyricsDevices: next.toList());
                }),
              ),
            ),
        ],
        ValueListenableBuilder<bool>(
          valueListenable: controls.flyme,
          builder: (context, flyme, _) => flyme
              ? SettingsSwitchTile(
                  title: l10n.settingsFlymeLyrics,
                  subtitle: l10n.settingsFlymeLyricsSubtitle,
                  value: prefs.flymeStatusBarLyrics,
                  onChanged: (v) =>
                      update((p) => p.copyWith(flymeStatusBarLyrics: v)),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 当前连接的蓝牙音频设备：车载设备自动生效；[BluetoothLyricsMode.car] 下其他设备可手动加入。
class _DeviceList extends StatelessWidget {
  final List<BluetoothAudioDevice> devices;
  final BluetoothLyricsMode mode;
  final List<String> manual;
  final void Function(String address, bool on) onToggle;

  const _DeviceList({
    required this.devices,
    required this.mode,
    required this.manual,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (devices.isEmpty) {
      return SettingsTile(
        title: l10n.settingsBluetoothDevices,
        subtitle: l10n.settingsBluetoothDevicesEmpty,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final device in devices)
          _tile(context, device),
      ],
    );
  }

  Widget _tile(BuildContext context, BluetoothAudioDevice device) {
    final l10n = context.l10n;
    final name = device.name.isEmpty ? l10n.bluetoothDeviceUnnamed : device.name;
    // 「全部设备」或车载设备：一定生效，只显示状态
    final automatic = mode == BluetoothLyricsMode.all || device.isCar;
    if (automatic) {
      return SettingsTile(
        title: name,
        subtitle: device.isCar
            ? l10n.bluetoothDeviceCar
            : l10n.bluetoothDeviceAll,
        trailing: Icon(
          Icons.check_circle_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }
    return SettingsSwitchTile(
      title: name,
      subtitle: l10n.bluetoothDeviceManual,
      value: manual.contains(device.address),
      onChanged: (v) => onToggle(device.address, v),
    );
  }
}
