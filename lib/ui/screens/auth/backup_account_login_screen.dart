import 'package:material_3_expressive/material_3_expressive.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../l10n/l10n.dart';
import '../../../services/auth/login_region_check.dart';

/// 独立 WebView 资料登录页的结果：直接从 `open.spotify.com` WebView 会话里拿到的
/// 登录凭据与账号唯一识别符（邮箱 / 唯一用户名 ID），不手动铸造 token。
class BackupLoginResult {
  final String spDc;
  final String accessToken;
  final String clientToken;
  final String userId;
  final String email;
  final String displayName;
  final String avatarUrl;
  final String profileDir;

  const BackupLoginResult({
    required this.spDc,
    this.accessToken = '',
    this.clientToken = '',
    this.userId = '',
    this.email = '',
    this.displayName = '',
    this.avatarUrl = '',
    this.profileDir = '',
  });
}

/// 独立 WebView 资料登录页（供歌单备份添加额外账号使用）：
///
/// - 每个备份账号使用独立的 `userDataFolder`（Windows `WebViewEnvironment`）或独立无痕存储，
///   与主账号的 `EmePlayer.cachedEnvironment` 完全隔离，互不串号；
/// - 登录 `open.spotify.com` 后直接从页面会话拦截 / 读取 `open.spotify.com` 自身的
///   `accessToken`、`clientToken`、`sp_dc` 以及账户唯一识别符（邮箱 `email` 与唯一 `id`），
///   **不手动铸造 token**。
class BackupAccountLoginScreen extends StatefulWidget {
  const BackupAccountLoginScreen({super.key, this.regionProbe});

  final LoginRegionProbe? regionProbe;

  static Future<BackupLoginResult?> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<BackupLoginResult?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const BackupAccountLoginScreen(),
      ),
    );
  }

  @override
  State<BackupAccountLoginScreen> createState() =>
      _BackupAccountLoginScreenState();
}

class _BackupAccountLoginScreenState extends State<BackupAccountLoginScreen> {
  static const String _loginUrl =
      'https://accounts.spotify.com/zh-CN/login?continue=https%3A%2F%2Fopen.spotify.com%2F';

  /// 注入 `open.spotify.com` 的前置脚本：直接捕获网页自身请求携带的 Bearer token /
  /// client-token 或页面内嵌的 `#session` JSON，绝不手动拼 TOTP 铸造 token。
  static const String _sessionHookScript = r'''
(function() {
  if (window.__flutifyBackupHooked) return;
  window.__flutifyBackupHooked = true;
  window.__flutifySession = { accessToken: '', clientToken: '', id: '', email: '', displayName: '', avatarUrl: '' };

  function recordAuth(val) {
    if (typeof val === 'string' && val.startsWith('Bearer ')) {
      var t = val.slice(7).trim();
      if (t.length > 20) window.__flutifySession.accessToken = t;
    }
  }
  function recordClientToken(val) {
    if (typeof val === 'string' && val.trim().length > 10) {
      window.__flutifySession.clientToken = val.trim();
    }
  }
  function inspectHeaders(h) {
    if (!h) return;
    try {
      if (typeof Headers !== 'undefined' && h instanceof Headers) {
        recordAuth(h.get('authorization') || h.get('Authorization'));
        recordClientToken(h.get('client-token'));
      } else if (Array.isArray(h)) {
        for (var i = 0; i < h.length; i++) {
          var k = String(h[i][0] || '').toLowerCase();
          if (k === 'authorization') recordAuth(h[i][1]);
          if (k === 'client-token') recordClientToken(h[i][1]);
        }
      } else if (typeof h === 'object') {
        for (var key in h) {
          var lk = key.toLowerCase();
          if (lk === 'authorization') recordAuth(h[key]);
          if (lk === 'client-token') recordClientToken(h[key]);
        }
      }
    } catch (_) {}
  }

  var origFetch = window.fetch;
  if (typeof origFetch === 'function') {
    window.fetch = function(input, init) {
      try {
        if (init && init.headers) inspectHeaders(init.headers);
        if (input && typeof input === 'object' && input.headers) inspectHeaders(input.headers);
      } catch (_) {}
      return origFetch.apply(this, arguments);
    };
  }

  var origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    try {
      var lk = String(name || '').toLowerCase();
      if (lk === 'authorization') recordAuth(value);
      if (lk === 'client-token') recordClientToken(value);
    } catch (_) {}
    return origSetHeader.apply(this, arguments);
  };
})();
''';

  WebViewEnvironment? _environment;
  InAppWebViewController? _controller;
  late final String _profileDir;
  Timer? _pollTimer;
  bool _envReady = false;
  bool _regionChecking = false;
  bool _regionBlocked = false;
  bool _busy = false;
  bool _done = false;
  int _openSpotifyTicks = 0;

  @override
  void initState() {
    super.initState();
    _profileDir =
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutify_backup_profile_${DateTime.now().millisecondsSinceEpoch}';
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollSession()),
    );
    unawaited(_initIsolatedEnvironment());
  }

  Future<void> _initIsolatedEnvironment() async {
    if (Platform.isWindows && _environment == null) {
      try {
        final dir = Directory(_profileDir);
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: _profileDir),
        );
      } catch (_) {}
    }

    if (!LoginRegionCheck.skippedThisRun) {
      if (mounted && !_done) setState(() => _regionChecking = true);
      final probe =
          widget.regionProbe ??
          () => LoginRegionCheck.detect(environment: _environment);
      LoginRegion region;
      try {
        region = await probe();
      } catch (_) {
        region = const LoginRegion.unknown();
      }
      if (!mounted || _done) return;
      if (region.isMainlandChina) {
        setState(() {
          _regionChecking = false;
          _regionBlocked = true;
        });
        return;
      }
      setState(() => _regionChecking = false);
    }

    if (!mounted || _done) return;
    setState(() {
      _regionBlocked = false;
      _envReady = true;
    });
  }

  void _skipRegionAndContinue() {
    LoginRegionCheck.skipForThisRun();
    setState(() => _regionBlocked = false);
    unawaited(_initIsolatedEnvironment());
  }

  Future<String?> _readSpDc() async {
    if (!_envReady || !mounted || _done) return null;
    final manager = CookieManager.instance(webViewEnvironment: _environment);
    for (final url in const [
      'https://open.spotify.com',
      'https://accounts.spotify.com',
      'https://www.spotify.com',
    ]) {
      try {
        final c = await manager.getCookie(url: WebUri(url), name: 'sp_dc');
        final v = c?.value.trim();
        if (v != null && v.isNotEmpty) return v;
      } catch (_) {}
    }
    return null;
  }

  /// 直接从 `open.spotify.com` 页面读取已就绪的会话与账户唯一识别符（邮箱 / 用户名 ID），不手动铸造 token。
  Future<void> _pollSession() async {
    if (_busy || _done || !_envReady || !mounted) return;
    _busy = true;
    try {
      final spDc = await _readSpDc();
      if (spDc == null || spDc.isEmpty || _done || !mounted) return;

      final controller = _controller;
      if (controller == null) return;

      final currentUrl = (await controller.getUrl())?.toString() ?? '';
      // 若刚在 accounts.spotify.com 完成登录但尚未跳转到 open.spotify.com，主动进一次以拿到页面会话
      if (!currentUrl.startsWith('https://open.spotify.com')) {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri('https://open.spotify.com/')),
        );
        return;
      }

      _openSpotifyTicks++;
      final raw = await controller.evaluateJavascript(
        source: r'''
(function() {
  var s = window.__flutifySession || { accessToken: '', clientToken: '' };
  if (!s.accessToken) {
    try {
      var el = document.getElementById('session');
      if (el && el.textContent) {
        var parsed = JSON.parse(el.textContent);
        if (parsed && parsed.accessToken && parsed.isAnonymous === false) {
          s.accessToken = parsed.accessToken;
        }
      }
    } catch (_) {}
  }
  return JSON.stringify(s);
})();
''',
      );

      var accessToken = '';
      var clientToken = '';
      if (raw is String && raw.isNotEmpty) {
        try {
          final map = jsonDecode(raw);
          if (map is Map<String, dynamic>) {
            accessToken = (map['accessToken'] as String? ?? '').trim();
            clientToken = (map['clientToken'] as String? ?? '').trim();
          }
        } catch (_) {}
      }

      // 给 open.spotify.com 最多 3 个轮询周期（约 6 秒）完成自身初始化并捕获 token；
      // 若已拿到 token 或达到上限则立即结束登录页。
      if (accessToken.isEmpty && _openSpotifyTicks < 3) {
        return;
      }

      var userId = '';
      var email = '';
      var displayName = '';
      var avatarUrl = '';

      if (accessToken.isNotEmpty) {
        try {
          final profileRaw = await controller.callAsyncJavaScript(
            functionBody: r'''
try {
  var r = await fetch('https://api.spotify.com/v1/me', {
    headers: { 'Authorization': 'Bearer ' + token, 'Accept': 'application/json' }
  });
  if (r.ok) {
    var me = await r.json();
    return JSON.stringify({
      id: me.id || '',
      email: me.email || '',
      displayName: me.display_name || '',
      avatarUrl: (me.images && me.images.length > 0 && me.images[0].url) ? me.images[0].url : ''
    });
  }
} catch (_) {}
return '';
''',
            arguments: {'token': accessToken},
          );
          final val = profileRaw?.value;
          if (val is String && val.isNotEmpty) {
            final me = jsonDecode(val);
            if (me is Map<String, dynamic>) {
              userId = (me['id'] as String? ?? '').trim();
              email = (me['email'] as String? ?? '').trim();
              displayName = (me['displayName'] as String? ?? '').trim();
              avatarUrl = (me['avatarUrl'] as String? ?? '').trim();
            }
          }
        } catch (_) {}
      }

      _finish(
        BackupLoginResult(
          spDc: spDc,
          accessToken: accessToken,
          clientToken: clientToken,
          userId: userId,
          email: email,
          displayName: displayName,
          avatarUrl: avatarUrl,
          profileDir: _profileDir,
        ),
      );
    } finally {
      _busy = false;
    }
  }

  void _finish(BackupLoginResult? result) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context, rootNavigator: true).pop(result);
  }

  @override
  void dispose() {
    _done = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录要备份的 Spotify 账号'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: l10n.commonClose,
          onPressed: () => _finish(null),
        ),
      ),
      body: _regionChecking
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const M3ELoadingIndicator(),
                  const SizedBox(height: 16),
                  Text(l10n.webLoginRegionChecking),
                ],
              ),
            )
          : _regionBlocked
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.public_off_rounded, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      l10n.webLoginRegionBlockedTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.webLoginRegionBlockedBody,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    M3EButton.filled(
                      onPressed: _skipRegionAndContinue,
                      child: Text(l10n.regionCheckSkipThisRun),
                    ),
                  ],
                ),
              ),
            )
          : !_envReady
          ? const Center(child: M3ELoadingIndicator())
          : InAppWebView(
              webViewEnvironment: _environment,
              initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: _sessionHookScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                incognito: !Platform.isWindows,
                javaScriptEnabled: true,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStop: (_, _) => unawaited(_pollSession()),
            ),
    );
  }
}
