import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/deep_link/spotify_link_handler.dart';
import '../../../widgets/toast/app_toast.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';

/// 启动：启动时打开的页面；桌面端另有「记住窗口大小和位置」（下次启动生效）。
class StartupSection extends StatelessWidget {
  const StartupSection({super.key});

  static bool get _isDesktopPlatform => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final provider = context.read<PreferencesProvider>();
    final (startPage, rememberWindow) = context.select<PreferencesProvider, (StartPage, bool)>(
      (p) => (p.prefs.startPage, p.prefs.rememberWindow),
    );

    return SettingsSection(
      title: l10n.settingsStartupSection,
      children: [
        SettingsTile(
          title: l10n.settingsStartPage,
          below: SettingsSegmented<StartPage>(
            values: StartPage.values,
            labelOf: (v) => switch (v) {
              StartPage.home => l10n.settingsStartPageHome,
              StartPage.library => l10n.settingsStartPageLibrary,
              StartPage.last => l10n.settingsStartPageLast,
            },
            selected: startPage,
            onChanged: (v) => provider.update(provider.prefs.copyWith(startPage: v)),
          ),
        ),
        if (_isDesktopPlatform)
          SettingsSwitchTile(
            title: l10n.settingsRememberWindow,
            subtitle: l10n.settingsRememberWindowSubtitle,
            value: rememberWindow,
            onChanged: (v) => provider.update(provider.prefs.copyWith(rememberWindow: v)),
          ),
        if (SpotifyLinkHandler.canSetDefault) const _SpotifyLinksTile(),
      ],
    );
  }
}

/// 「用 Flutify 打开 Spotify 链接」：状态以系统注册为准（用户也可能在 Windows 设置里改过），不存偏好。
class _SpotifyLinksTile extends StatefulWidget {
  const _SpotifyLinksTile();

  @override
  State<_SpotifyLinksTile> createState() => _SpotifyLinksTileState();
}

class _SpotifyLinksTileState extends State<_SpotifyLinksTile> {
  SpotifyLinkStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final status = await SpotifyLinkHandler.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _toggle(bool enable) async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await SpotifyLinkHandler.setDefault(enable);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == SpotifyLinkSetResult.needsSystemSettings) {
      AppToast.show(context, context.l10n.settingsSpotifyLinksSystem, tone: ToastTone.error);
      unawaited(launchUrl(Uri.parse('ms-settings:defaultapps')));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = _status;
    final other = status?.otherHandler ?? '';
    return SettingsSwitchTile(
      title: l10n.settingsSpotifyLinks,
      subtitle: status != null && !status.isDefault && other.isNotEmpty
          ? '${l10n.settingsSpotifyLinksSubtitle}\n${l10n.settingsSpotifyLinksOther(other)}'
          : l10n.settingsSpotifyLinksSubtitle,
      value: status?.isDefault ?? false,
      onChanged: (v) {
        if (status != null && !_busy) unawaited(_toggle(v));
      },
    );
  }
}
