import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/network/network_proxy.dart';
import '../../../../services/network/proxy_probe.dart';
import '../../../../services/storage_service.dart';
import '../widgets/proxy_auth_fields.dart';
import '../widgets/proxy_server_fields.dart';
import '../widgets/gateway_settings.dart';
import '../widgets/settings_section.dart';
import '../widgets/settings_segmented.dart';

/// 网络：代理模式（系统代理 / 不使用 / 手动）+ 手动代理的地址与认证 + 测试连接。
///
/// - 改动即时生效：main 里监听偏好，重配全局 [NetworkProxy]，之后的新连接都按新策略走；
///   代理密码不进偏好（在 StorageService），由认证字段提交后直接重配；
/// - 「系统代理」下显示当前读到的系统代理，进入设置页时重读一次；
/// - 没有注入 [NetworkProxy]（测试）时只显示模式与手动地址，不探测系统、不提供测试。
class NetworkSection extends StatefulWidget {
  const NetworkSection({super.key});

  @override
  State<NetworkSection> createState() => _NetworkSectionState();
}

enum _ProbeState { idle, running, ok, failed }

class _NetworkSectionState extends State<NetworkSection> {
  NetworkProxy? _proxy;
  StorageService? _storage;
  late final PreferencesProvider _prefs;
  _ProbeState _probe = _ProbeState.idle;
  String _probeDetail = '';

  /// 防止旧的测试结果覆盖切换模式后发起的新测试。
  int _probeToken = 0;

  @override
  void initState() {
    super.initState();
    _proxy = Provider.of<NetworkProxy?>(context, listen: false);
    _storage = Provider.of<StorageService?>(context, listen: false);
    _prefs = context.read<PreferencesProvider>();
    if (context.read<PreferencesProvider>().prefs.proxyMode == ProxyMode.system)
      _refreshSystem();
  }

  void _refreshSystem() {
    _proxy?.refreshSystem().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _update(AppPreferences next) {
    final provider = context.read<PreferencesProvider>();
    provider.update(next);
    setState(() {
      _probe = _ProbeState.idle;
      _probeToken++;
    });
  }

  void _setMode(ProxyMode mode) {
    final provider = context.read<PreferencesProvider>();
    _update(provider.prefs.copyWith(proxyMode: mode));
    if (mode == ProxyMode.system) _refreshSystem();
  }

  /// 认证改动即时生效：用户名走偏好（main 的监听会重配），密码落盘后这里直接重配一次
  ///（密码不在偏好 JSON 里，监听的指纹看不到密码变化）。
  ///
  /// 离开设置页时 [ProxyAuthFields] 会在本页卸载后补交未提交的改动，所以这里不能依赖
  /// context：用 initState 里取好的 Provider，setState 也只在仍挂载时做。
  void _applyAuth(String username, String password) {
    final storage = _storage;
    storage?.setProxyPassword(password);
    final provider = _prefs;
    if (provider.prefs.proxyUsername != username) {
      provider.update(provider.prefs.copyWith(proxyUsername: username));
    }
    final proxy = _proxy;
    if (proxy != null) unawaited(_reapply(proxy, provider.prefs));
    if (!mounted) return;
    setState(() {
      _probe = _ProbeState.idle;
      _probeToken++;
    });
  }

  /// 按当前偏好 + 存储里的密码重配全局代理。
  Future<void> _reapply(NetworkProxy proxy, AppPreferences prefs) =>
      proxy.configure(
        mode: prefs.proxyMode,
        proxyHost: prefs.proxyHost,
        proxyPort: prefs.proxyPort,
        gateway: prefs.gateway,
        proxyUsername: prefs.proxyUsername,
        proxyPassword: _storage?.proxyPassword ?? '',
      );

  Future<void> _runProbe() async {
    // 先让正在编辑的手动地址失焦提交（焦点回调在下一轮事件里触发），再按最新配置测试
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final token = ++_probeToken;
    setState(() => _probe = _ProbeState.running);
    // 等手动地址这类刚提交的配置生效（系统模式会重读系统代理）
    final proxy = _proxy;
    if (proxy != null) {
      await _reapply(proxy, context.read<PreferencesProvider>().prefs);
    }
    try {
      final elapsed = await ProxyProbe.run();
      if (!mounted || token != _probeToken) return;
      setState(() {
        _probe = _ProbeState.ok;
        _probeDetail = '${elapsed.inMilliseconds}';
      });
    } catch (e) {
      if (!mounted || token != _probeToken) return;
      setState(() {
        _probe = _ProbeState.failed;
        _probeDetail = _describe(e);
      });
    }
  }

  /// 异常的一行摘要：去掉类型前缀，过长截断。
  static String _describe(Object error) {
    if (error is TimeoutException) return 'timeout';
    var text = '$error'
        .split('\n')
        .first
        .replaceFirst(RegExp(r'^\w*Exception:\s*'), '');
    if (text.length > 90) text = '${text.substring(0, 90)}…';
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final provider = context.read<PreferencesProvider>();
    final (mode, host, port, username) = context
        .select<PreferencesProvider, (ProxyMode, String, int, String)>(
          (p) => (
            p.prefs.proxyMode,
            p.prefs.proxyHost,
            p.prefs.proxyPort,
            p.prefs.proxyUsername,
          ),
        );
    final proxy = _proxy;

    final String? subtitle = switch (mode) {
      ProxyMode.system =>
        proxy == null
            ? null
            : proxy.system.primary == null
            ? proxy.system.autoProxy
                  ? l10n.settingsProxySystemAuto
                  : l10n.settingsProxySystemEmpty
            : l10n.settingsProxySystemDetected('${proxy.system.primary}'),
      ProxyMode.none => l10n.settingsProxyNoneSubtitle,
      ProxyMode.manual => l10n.settingsProxyManualSubtitle,
    };

    return SettingsSection(
      title: l10n.settingsNetworkSection,
      footer: l10n.settingsProxyFootnote,
      children: [
        GatewaySettings(
          onChanged: () {
            setState(() {
              _probe = _ProbeState.idle;
              _probeToken++;
            });
          },
        ),
        SettingsTile(
          title: l10n.settingsProxy,
          subtitle: subtitle,
          below: SettingsSegmented<ProxyMode>(
            values: ProxyMode.values,
            labelOf: (m) => switch (m) {
              ProxyMode.system => l10n.settingsProxySystem,
              ProxyMode.none => l10n.settingsProxyNone,
              ProxyMode.manual => l10n.settingsProxyManual,
            },
            selected: mode,
            onChanged: _setMode,
          ),
        ),
        if (mode == ProxyMode.manual) ...[
          SettingsTile(
            title: l10n.settingsProxyServer,
            below: ProxyServerFields(
              host: host,
              port: port,
              onApply: (h, p) =>
                  _update(provider.prefs.copyWith(proxyHost: h, proxyPort: p)),
            ),
          ),
          // 认证字段可选：代理不需要用户名 / 密码时两个都留空即可
          SettingsTile(
            title: l10n.settingsProxyAuth,
            below: ProxyAuthFields(
              username: username,
              password: _storage?.proxyPassword ?? '',
              onApply: _applyAuth,
            ),
          ),
        ],
        if (proxy != null)
          SettingsTile(
            title: l10n.settingsProxyTest,
            subtitle: switch (_probe) {
              _ProbeState.idle => null,
              _ProbeState.running => l10n.settingsProxyTesting,
              _ProbeState.ok => l10n.settingsProxyTestOk(
                int.parse(_probeDetail),
              ),
              _ProbeState.failed => l10n.settingsProxyTestFailed(_probeDetail),
            },
            trailing: switch (_probe) {
              _ProbeState.running => const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              _ProbeState.ok => Icon(
                Icons.check_circle_rounded,
                color: colorScheme.primary,
              ),
              _ProbeState.failed => Icon(
                Icons.error_rounded,
                color: colorScheme.error,
              ),
              _ProbeState.idle => Icon(
                Icons.network_check_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
            },
            onTap: _probe == _ProbeState.running ? null : _runProbe,
          ),
      ],
    );
  }
}
