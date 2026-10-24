import 'package:material_3_expressive/material_3_expressive.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/auth/web_token_service.dart';
import '../../../services/eme/chrome/linux_chrome.dart';
import '../../widgets/toast/app_toast.dart';
import 'web_login_screen.dart' show WebLoginResult;
import '../../widgets/flutify_progress.dart';

/// Linux 全曲播放 Web 登录：没有内嵌 WebView，改用一个受管理的系统 Chrome
/// 打开 Spotify 官方登录页，用户在窗口里登录后，App 经 CDP 读取 HttpOnly 的
/// `sp_dc` cookie（Widevine 真密钥所需），随后窗口自动隐藏、登录态持久化。
class LinuxWebLoginScreen extends StatefulWidget {
  const LinuxWebLoginScreen({super.key});

  static Future<WebLoginResult?> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<WebLoginResult?>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const LinuxWebLoginScreen()),
    );
  }

  @override
  State<LinuxWebLoginScreen> createState() => _LinuxWebLoginScreenState();
}

class _LinuxWebLoginScreenState extends State<LinuxWebLoginScreen> {
  static final Uri _loginUrl = Uri.parse(
    'https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F',
  );

  late final WebTokenService _tokens = context.read<WebTokenService>();
  AuthProvider? _auth;
  Timer? _poll;
  String? _error;
  bool _busy = true;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider?>();
    unawaited(_start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final tokens = _tokens;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await tokens.prepareForLogin();
      if (tokens.hasSpDc) {
        _finish(tokens.spDc);
        return;
      }
      await LinuxChromeManager.instance.page(_loginUrl, visible: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
      return;
    }
    if (!mounted) return;
    _poll?.cancel();
    _poll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_check()),
    );
  }

  Future<void> _check() async {
    if (_done) return;
    try {
      final cookies = await LinuxChromeManager.instance.cookies(
        'https://open.spotify.com',
      );
      final spDc = cookies['sp_dc'];
      if (spDc == null || spDc.isEmpty) return;
      await _tokens.setSpDc(spDc);
      try {
        await _tokens.mintAccessToken().timeout(const Duration(seconds: 15));
        await _auth?.completeWebSignIn();
      } catch (_) {}
      // 登录完成：关掉可见的 Chrome 窗口；之后全曲播放会以无窗口（headless）模式重新拉起。
      await LinuxChromeManager.instance.dispose();
      _finish(spDc);
    } catch (_) {}
  }

  void _finish(String? spDc) {
    if (_done || !mounted) return;
    _done = true;
    _poll?.cancel();
    Navigator.of(context, rootNavigator: true).pop(
      WebLoginResult(spDc: spDc),
    );
  }

  Future<void> _reopen() async {
    try {
      await LinuxChromeManager.instance.page(_loginUrl, visible: true);
    } catch (_) {
      await launchUrl(_loginUrl, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.webLoginTitle),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: l10n.commonClose,
          onPressed: () => _finish(_tokens.spDc),
        ),
      ),
      body: Column(
        children: [
          if (_busy) const FlutifyLinearProgress(thickness: 4),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error == null) ...[
                      const SizedBox(
                        width: 64,
                        height: 64,
                        child: M3ELoadingIndicator(),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        l10n.webLoginAuthorizing,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.loginBrowserSubtitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ] else ...[
                      Icon(
                        Icons.error_outline_rounded,
                        color: Theme.of(context).colorScheme.error,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text('${l10n.loginFailed}：$_error', textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 8,
                      children: [
                        M3EButton.icon(
                          style: M3EButtonStyle.tonal,
                          onPressed: _reopen,
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: Text(l10n.loginReopen),
                        ),
                        M3EButton.icon(style: M3EButtonStyle.outlined, 
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.maybeOf(context);
                            await Clipboard.setData(
                              ClipboardData(text: _loginUrl.toString()),
                            );
                            AppToast.showOn(
                              messenger,
                              l10n.loginLinkCopied,
                              icon: Icons.link_rounded,
                              tone: ToastTone.success,
                            );
                          },
                          icon: const Icon(Icons.link_rounded),
                          label: Text(l10n.loginCopyLink),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
