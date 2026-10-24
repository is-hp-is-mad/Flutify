import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';

import '../../../core/platform/flutify_platform.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/auth/login_region_check.dart';
import '../../../services/auth/web_login_flow.dart';
import '../../../services/auth/web_token_service.dart';
import '../../../services/eme/eme_player.dart';
import '../../shell/desktop/desktop_window.dart';
import 'linux_web_login_screen.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton, M3EButtonStyle;
import '../../widgets/flutify_progress.dart';

export '../../../services/auth/web_login_flow.dart' show WebLoginStage;

/// 统一登录页：在内嵌 WebView2 里完成一次 Web 登录，其余全部自动收尾。
///
/// 1. 用户在 WebView 里登录 open.spotify.com（唯一有感知的一步）；
/// 2. 登录完成自动捕获 `sp_dc`（Web 会话凭据，httpOnly）并铸 Web token——**自动获取需要的内容**；
/// 3. 桌面 OAuth 若还没做，**后台无感补上**：同一 WebView 会话打开授权页（已登录自动过），
///    回环收 code、换令牌，全程不需要用户操作。
///
/// sp_dc 是铸造「Web 播放器 access_token」（Widevine 真密钥所需）的唯一凭据；
/// 桌面 OAuth 管媒体库 / API / Connect。一次登录两样都齐。
///
/// 性能说明：这是**用户主动打开的一次性登录页**，不是后台常驻渲染 open.spotify.com；
/// 登录完成即销毁 WebView。
class WebLoginScreen extends StatefulWidget {
  const WebLoginScreen({super.key, this.regionProbe});

  /// 登录前的网络地区检测；默认在 WebView 里读 Cloudflare trace（见 [LoginRegionCheck]），测试可注入。
  final LoginRegionProbe? regionProbe;

  /// 打开统一登录页。返回登录结果（用户取消 / 跳过返回 null）。
  static Future<WebLoginResult?> open(BuildContext context) {
    // Linux 没有内嵌 WebView：用系统 Chrome 抓取 sp_dc（见 LinuxWebLoginScreen）。
    if (FlutifyPlatform.isLinuxDesktop) {
      return LinuxWebLoginScreen.open(context);
    }
    return Navigator.of(context, rootNavigator: true).push<WebLoginResult?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const WebLoginScreen(),
      ),
    );
  }

  @override
  State<WebLoginScreen> createState() => _WebLoginScreenState();
}

/// 登录结果：[spDc] 非空即 Web 会话已就绪（已同时完成全局登录）。
class WebLoginResult {
  final String? spDc;
  const WebLoginResult({this.spDc});

  bool get webSignedIn => spDc != null && spDc!.isNotEmpty;
}

class _WebLoginScreenState extends State<WebLoginScreen> {
  InAppWebViewController? _controller;
  late final WebLoginFlow _flow;
  late final WebTokenService _tokens;
  bool _sessionRejected = false;
  bool _webViewReady = false;
  bool _preparingLogin = false;
  String? _preparationError;
  int _pageRevision = 0;

  /// 登录前的网络地区检测：最近一次结果、是否检测中、用户是否选择了强制跳过。
  LoginRegion? _region;
  bool _regionChecking = false;
  bool _regionSkipped = false;
  Timer? _regionWatchTimer;

  /// 登录期间复查出口地区的间隔：中途切到大陆出口时立即销毁 WebView 并提示。
  static const Duration _regionWatchInterval = Duration(seconds: 45);

  bool get _regionBlocked =>
      !_regionSkipped && (_region?.isMainlandChina ?? false);

  LoginRegionProbe get _probeRegion =>
      widget.regionProbe ??
      () => LoginRegionCheck.detect(environment: EmePlayer.cachedEnvironment);

  Timer? _pollTimer;
  Timer? _consentTimer;

  /// 页面已结束（pop 过），后续回调全部忽略。
  bool _done = false;

  /// 最近一次页面地址（同意页自动点击的判定依据）。
  String? _currentUrl;

  @override
  void initState() {
    super.initState();
    final tokens = context.read<WebTokenService>();
    _tokens = tokens;
    final auth = context.read<AuthProvider?>();
    _flow = WebLoginFlow(
      // 关键：CookieManager 必须与 WebView 同一个 WebViewEnvironment。
      // 用默认环境会与 EME 的自定义环境（同 user data 目录、不同浏览器参数）冲突，
      // 创建即 ERROR_INVALID_STATE，读 cookie 永远抛异常 —— 登录完卡在 open.spotify.com 的根因。
      readSpDc: _readSpDc,
      saveSpDc: tokens.setSpDc,
      prepareWebToken: () async {
        await tokens.mintAccessToken().timeout(const Duration(seconds: 15));
        await auth?.completeWebSignIn();
      },
      onFinished: (_) => _finish(WebLoginResult(spDc: _flow.spDc)),
    );
    _flow.addListener(_onFlowChanged);
    tokens.sessionInvalidated.addListener(_onSessionInvalidated);
    tokens.addCookieCleanupHook(_stopRejectedWebView);
    // 兜底：每 2 秒推一次流程（读 sp_dc 的轮询；跳转路径不固定，不能只靠导航事件）
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _flow.poll(),
    );
    // 同意页自动点击：React 页面的按钮晚于 onLoadStop 渲染，按小周期多试几次
    _consentTimer = Timer.periodic(
      const Duration(milliseconds: 900),
      (_) => _tryAutoApprove(),
    );
    _regionWatchTimer = Timer.periodic(
      _regionWatchInterval,
      (_) => _watchRegion(),
    );
    // 清理上次失效会话的 Cookie、确认出口地区之后才允许创建 WebView。
    unawaited(_prepareLoginPage());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _consentTimer?.cancel();
    _regionWatchTimer?.cancel();
    _flow.removeListener(_onFlowChanged);
    _tokens.sessionInvalidated.removeListener(_onSessionInvalidated);
    _tokens.removeCookieCleanupHook(_stopRejectedWebView);
    // 关页后到达的异步结果一律丢弃
    unawaited(_flow.cancel());
    _flow.dispose();
    super.dispose();
  }

  void _finish(WebLoginResult? result) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context, rootNavigator: true).pop(result);
  }

  // ---------------------------------------------------------------------------
  // 流程推进
  // ---------------------------------------------------------------------------

  void _onFlowChanged() {
    if (!mounted || _done) return;
    setState(() {});
  }

  void _onSessionInvalidated() {
    if (!mounted || _done) return;
    ++_pageRevision;
    _sessionRejected = true;
    _webViewReady = false;
    _currentUrl = null;
    _flow.invalidateSession();
  }

  Future<void> _stopRejectedWebView() async {
    if (!mounted || _done) return;
    try {
      await _controller?.stopLoading();
    } catch (_) {}
    // Let Flutter dispose the old login page before clearing cookies, so its
    // pending navigation cannot immediately refill the cookie store.
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 5),
    );
    _controller = null;
  }

  Future<void> _retry() => _prepareLoginPage(retry: true);

  Future<void> _prepareLoginPage({bool retry = false}) async {
    if (_preparingLogin) return;
    final revision = _pageRevision;
    _preparingLogin = true;
    try {
      await _tokens.prepareForLogin();
      if (!mounted || _done || revision != _pageRevision) return;
      await EmePlayer.ensureEnvironment();
      if (!mounted || _done || revision != _pageRevision) return;
      // 加载登录页之前先确认出口地区；大陆出口时不创建 WebView，等用户选择
      if (!_regionSkipped && !await _checkRegion(revision)) return;
      setState(() {
        _sessionRejected = false;
        _webViewReady = true;
        _preparationError = null;
      });
      if (retry) await _flow.retry();
      if (!mounted || _done || revision != _pageRevision) return;
      await _flow.poll();
    } catch (_) {
      if (mounted && !_done && revision == _pageRevision) {
        setState(() {
          _webViewReady = false;
          _preparationError = 'WebView Cookie 清理失败，请重试';
        });
      }
    } finally {
      _preparingLogin = false;
    }
  }

  /// 检测出口地区（在 WebView 里执行脚本）。返回 true 表示可以继续加载登录页；
  /// 返回 false 表示已被拦下（大陆出口，已显示提示）或页面状态已变化。
  Future<bool> _checkRegion(int revision) async {
    if (mounted && !_done) setState(() => _regionChecking = true);
    LoginRegion region;
    try {
      region = await _probeRegion();
    } catch (_) {
      region = const LoginRegion.unknown();
    }
    if (!mounted || _done) return false;
    if (revision != _pageRevision) {
      setState(() => _regionChecking = false);
      return false;
    }
    setState(() {
      _regionChecking = false;
      _region = region;
      if (region.isMainlandChina) {
        _webViewReady = false;
        _controller = null;
      }
    });
    return !region.isMainlandChina;
  }

  /// 登录期间的静默复查：检测到切换成大陆出口就立刻销毁登录 WebView（从树里移除即销毁）并提示。
  Future<void> _watchRegion() async {
    if (_done ||
        _regionSkipped ||
        _regionChecking ||
        _preparingLogin ||
        !_webViewReady ||
        _flow.stage != WebLoginStage.webSignIn) {
      return;
    }
    final revision = _pageRevision;
    LoginRegion region;
    try {
      region = await _probeRegion();
    } catch (_) {
      return;
    }
    if (!mounted ||
        _done ||
        _regionSkipped ||
        revision != _pageRevision ||
        !region.isMainlandChina) {
      return;
    }
    setState(() {
      _region = region;
      _webViewReady = false;
      _controller = null;
    });
  }

  void _enterWebView() {
    setState(() {
      _sessionRejected = false;
      _webViewReady = true;
      _preparationError = null;
    });
  }

  /// 「重新检测」：只重跑地区检测，通过后再创建登录 WebView。
  Future<void> _recheckRegion() async {
    if (_regionChecking || _preparingLogin || _done) return;
    if (!await _checkRegion(_pageRevision)) return;
    if (!mounted || _done) return;
    _enterWebView();
    await _flow.poll();
  }

  /// 「强制跳过」：本次打开都不再检测，直接创建登录 WebView。
  ///
  /// 和「本次打开跳过检测」一样只在内存里生效：下次启动重新检测。
  void _skipRegionCheck() {
    if (!mounted || _done) return;
    LoginRegionCheck.skipForThisRun();
    _regionSkipped = true;
    _enterWebView();
    unawaited(_flow.poll());
  }

  /// 「本次打开跳过检测」：在检测阶段让用户不等结果直接进去；之后的复查也一起放过。
  Future<void> _skipRegionForThisRun() async {
    if (!mounted || _done) return;
    LoginRegionCheck.skipForThisRun();
    _regionSkipped = true;
    _regionChecking = false;
    if (!_webViewReady && !_preparingLogin) unawaited(_prepareLoginPage());
    if (mounted && !_done) setState(() {});
  }

  /// 读 sp_dc：多来源各试一遍（cookie 域绑定可能落在 accounts 或 open 上）。
  Future<String?> _readSpDc() async {
    if (!_webViewReady || _sessionRejected || !mounted || _done) return null;
    final manager = CookieManager.instance(
      webViewEnvironment: EmePlayer.cachedEnvironment,
    );
    for (final url in const [
      'https://open.spotify.com',
      'https://accounts.spotify.com',
    ]) {
      try {
        final cookie = await manager.getCookie(url: WebUri(url), name: 'sp_dc');
        final value = cookie?.value?.toString() ?? '';
        if (value.isNotEmpty) return value;
      } catch (_) {
        // 环境未就绪 / 登录未完成：换下一个来源或下个轮询周期
      }
    }
    return null;
  }

  /// 同意页自动点击（登录跳转链里偶尔出现的账号授权确认页）。
  Future<void> _tryAutoApprove() async {
    final controller = _controller;
    if (controller == null || _done || _flow.stage != WebLoginStage.webSignIn) {
      return;
    }
    if (!isSpotifyAccountsPageUrl(_currentUrl)) return;
    try {
      await controller.evaluateJavascript(source: kConsentAutoApproveScript);
    } catch (_) {
      // 页面正处在跳转中，下个周期再试
    }
  }

  void _onNav(String? url) {
    if (url == null || _done || _sessionRejected || !_webViewReady) return;
    _currentUrl = url;
    _tryAutoApprove();
  }

  // ---------------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final stage = _flow.stage;
    final showOverlay =
        !_regionBlocked && stage == WebLoginStage.preparing;

    final media = MediaQuery.of(context);
    final macInset = DesktopWindow.macNativeWindow ? 28.0 : 0.0;
    final scaffold = Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.webLoginTitle),
        flexibleSpace: macInset > 0
            ? const WindowDragArea(child: SizedBox.expand())
            : null,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: context.l10n.commonClose,
          onPressed: () => _finish(null),
        ),
      ),
      body: Column(
        children: [
          if (stage != WebLoginStage.done)
            const FlutifyLinearProgress(thickness: 4),
          if (stage == WebLoginStage.webSignIn) const _GoogleAccountHint(),
          if (_flow.notice != null)
            _NoticeBar(text: _flow.notice!, icon: Icons.info_outline_rounded),
          if (stage == WebLoginStage.failed || _preparationError != null)
            _NoticeBar(
              text:
                  _preparationError ?? _flow.error ?? context.l10n.loginFailed,
              icon: Icons.error_outline_rounded,
              actionLabel: context.l10n.commonRetry,
              onAction: _retry,
            ),
          Expanded(
            child: Stack(
              children: [
                if (_webViewReady && !_sessionRejected)
                  InAppWebView(
                    // 复用 EME 的自定义环境：同一用户数据目录只允许一个环境实例，
                    // 不传会触发插件再建环境（ERROR_INVALID_STATE）导致 WebView 创建失败
                    webViewEnvironment: EmePlayer.cachedEnvironment,
                    initialUrlRequest: URLRequest(
                      url: WebUri(
                        'https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F',
                      ),
                    ),
                    initialSettings: InAppWebViewSettings(
                      disableContextMenu: true,
                      supportZoom: false,
                      // 伪装成纯 Chrome（去掉 WebView2 的 Edg 标识）：Google 按 UA 封嵌入
                      // WebView（disallowed_useragent），伪装后有概率直接放行 Google 登录
                      userAgent:
                          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36',
                    ),
                    onWebViewCreated: (controller) => _controller = controller,
                    onUpdateVisitedHistory: (_, url, _) =>
                        _onNav(url?.toString()),
                    onLoadStop: (_, url) => _onNav(url?.toString()),
                  ),
                if (showOverlay)
                  _ProgressOverlay(
                    stage: stage,
                    checkingRegion: _regionChecking,
                    onSkipRegion: _skipRegionForThisRun,
                  ),
                if (_regionBlocked)
                  _RegionBlockedView(
                    code: _region?.code ?? '',
                    checking: _regionChecking,
                    onRecheck: _recheckRegion,
                    onSkip: _skipRegionCheck,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (macInset == 0) return scaffold;
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(top: media.padding.top + macInset),
      ),
      child: scaffold,
    );
  }
}

/// 后台收尾阶段盖住 WebView 的进度浮层：用户只看到「登录完成，正在收尾」。
class _ProgressOverlay extends StatelessWidget {
  final WebLoginStage stage;

  /// 正在检测出口地区（登录页加载之前）。
  final bool checkingRegion;

  /// 检测期间放弃等待：本次打开不再检测，直接加载登录页。
  final VoidCallback? onSkipRegion;
  const _ProgressOverlay({
    required this.stage,
    this.checkingRegion = false,
    this.onSkipRegion,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final text = checkingRegion
        ? context.l10n.webLoginRegionChecking
        : switch (stage) {
            WebLoginStage.preparing => context.l10n.webLoginPreparing,
            _ => context.l10n.webLoginFinishing,
          };
    return Positioned.fill(
      child: ColoredBox(
        color: colorScheme.surface,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const FlutifyLoadingIndicator(),
            const SizedBox(height: 24),
            Text(
              text,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              checkingRegion
                  ? context.l10n.webLoginRegionCheckingHint
                  : context.l10n.webLoginBackgroundHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (checkingRegion && onSkipRegion != null) ...[
              const SizedBox(height: 20),
              M3EButton.text(
                onPressed: onSkipRegion,
                child: Text(context.l10n.webLoginRegionSkipThisRun),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 检测到大陆出口后盖住整个页面的提示（此时登录 WebView 已销毁）。
class _RegionBlockedView extends StatelessWidget {
  final String code;
  final bool checking;
  final VoidCallback onRecheck;
  final VoidCallback onSkip;
  const _RegionBlockedView({
    required this.code,
    required this.checking,
    required this.onRecheck,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    return Positioned.fill(
      child: ColoredBox(
        color: colorScheme.surface,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.public_off_rounded,
                    size: 56,
                    color: colorScheme.error,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.webLoginRegionBlockedTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    code,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colorScheme.error,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.webLoginRegionBlockedBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  M3EButton.icon(style: M3EButtonStyle.filled,
                    onPressed: checking ? null : onRecheck,
                    icon: checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: FlutifySpinner(size: 16),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: Text(
                      checking
                          ? l10n.webLoginRegionChecking
                          : l10n.webLoginRegionRecheck,
                    ),
                  ),
                  const SizedBox(height: 8),
                  M3EButton.text(
                    onPressed: checking ? null : onSkip,
                    child: Text(l10n.webLoginRegionForceSkip),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Google 账号提示：Google 注册的账号在本页用「邮箱 + 密码」登录。
class _GoogleAccountHint extends StatelessWidget {
  const _GoogleAccountHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.secondaryContainer.withAlpha(120),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.l10n.webLoginGoogleHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部信息条（非致命提示 / 错误 + 动作）。
class _NoticeBar extends StatelessWidget {
  final String text;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _NoticeBar({
    required this.text,
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.errorContainer.withAlpha(90),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (actionLabel != null)
            M3EButton.text(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
