import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'web_token_exception.dart';

/// 统一登录流程：**Web 登录 → 自动取所需凭据 → 后台无感完成桌面 OAuth**。
///
/// 三段全自动，用户只在第一段（WebView 里登录）有感知：
/// 1. `webSignIn`：轮询 WebView cookie，读到 `sp_dc`（Web 会话凭据，httpOnly，只有
///    Cookie API 能读到）；登录跳转链里 Set-Cookie 有先后，读不到就继续等；
/// 2. `preparing`：保存 sp_dc 并铸 Web token（`sp_dc + TOTP → open.spotify.com/api/token`），
///    顺带验证 sp_dc 有效——这就是「自动获取需要的内容」；
/// 3. `desktopAuthorize`：若桌面 OAuth 还没做，后台无感补上——同一个 WebView 会话里
///    打开授权页（已登录会自动过），回环收 code、换令牌，全程不需要用户操作。
///
/// 与 UI 解耦：cookie 读取、凭据保存、桌面授权的发起均由调用方注入；
/// 界面只负责按 [stage] 渲染、把 WebView 事件转进来（[onDesktopAuthorized] 等）。
class WebLoginFlow extends ChangeNotifier {
  WebLoginFlow({
    required this.readSpDc,
    required this.saveSpDc,
    required this.prepareWebToken,
    required this.desktopSignedIn,
    required this.beginDesktopOAuth,
    this.cancelDesktopOAuth,
    this.onAuthorizeUrl,
    this.onFinished,
    this.now,
  });

  /// 从 WebView cookie 存储读 `sp_dc`；读不到返回 null。
  /// 注意：必须用与 WebView **同一个 WebViewEnvironment** 的 CookieManager，
  /// 否则默认环境与自定义环境冲突（ERROR_INVALID_STATE），读 cookie 永远抛异常。
  final Future<String?> Function() readSpDc;

  /// 保存 sp_dc（经插件持久化）。
  final Future<void> Function(String spDc) saveSpDc;

  /// 铸 Web token（顺带验证 sp_dc）；401 终止登录，其他失败提示后继续。
  final Future<void> Function() prepareWebToken;

  /// 桌面 OAuth 是否已完成（实时查询，不缓存）。
  final bool Function() desktopSignedIn;

  /// 开始桌面 OAuth（起本机回环监听），返回授权页地址；
  /// 返回 null 表示已登录或无法开始。
  final Future<Uri?> Function() beginDesktopOAuth;

  /// 取消进行中的桌面授权（关页清理，可选）。
  final Future<void> Function()? cancelDesktopOAuth;

  /// 拿到授权页地址后回调（UI 装载进 WebView / 隐藏 WebView）。
  final void Function(Uri authorizeUrl)? onAuthorizeUrl;

  /// 全部完成后的回调（UI 关页）。
  final void Function(WebLoginFlow flow)? onFinished;

  /// 可注入时钟（测试用）。
  final DateTime Function()? now;

  WebLoginStage _stage = WebLoginStage.webSignIn;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _desktopDone = false;
  bool _finished = false;
  int _revision = 0;
  DateTime? _desktopStartedAt;

  WebLoginStage get stage => _stage;

  /// 需要展示的错误（[WebLoginStage.failed] 时有值）。
  String? get error => _error;

  /// 非致命提示（如 Web token 铸造失败，sp_dc 已保存仍可继续）。
  String? get notice => _notice;

  /// 已捕获的 sp_dc。
  String? spDc;

  /// 桌面授权页地址（[WebLoginStage.desktopAuthorize] 期间有值）。
  Uri? desktopAuthorizeUrl;

  bool get webSignedIn => spDc != null && spDc!.isNotEmpty;
  bool get desktopAuthorized => _desktopDone;
  bool get isDone => _stage == WebLoginStage.done;

  /// 正在等桌面授权完成（UI 据此决定何时兜底露出 WebView）。
  bool get waitingForDesktop => _stage == WebLoginStage.desktopAuthorize;

  /// 桌面授权阶段已持续时长（UI 据此决定兜底露出）。
  Duration get desktopElapsed {
    final started = _desktopStartedAt;
    if (started == null) return Duration.zero;
    return (now?.call() ?? DateTime.now()).difference(started);
  }

  // ---------------------------------------------------------------------------

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    ++_revision;
    _disposed = true;
    _finished = true;
    super.dispose();
  }

  /// 定时 / 事件触发，推进流程。重入安全。
  Future<void> poll() async {
    if (_busy || _finished) return;
    switch (_stage) {
      case WebLoginStage.webSignIn:
        await _captureWebSession();
      case WebLoginStage.preparing:
      case WebLoginStage.desktopAuthorize:
      case WebLoginStage.done:
      case WebLoginStage.failed:
        break;
    }
  }

  /// 第一段：轮询 sp_dc。读到即保存并进入取凭据阶段。
  Future<void> _captureWebSession() async {
    final revision = _revision;
    _busy = true;
    try {
      final value = await readSpDc();
      if (_finished ||
          revision != _revision ||
          _stage != WebLoginStage.webSignIn) {
        return;
      }
      if (value == null || value.isEmpty) return; // 登录未完成，下个周期再试
      spDc = value;
      notifyListeners();
      await saveSpDc(value);
      if (_finished ||
          revision != _revision ||
          _stage != WebLoginStage.webSignIn) {
        return;
      }
      await _prepare();
    } catch (e) {
      if (_finished ||
          revision != _revision ||
          _stage == WebLoginStage.failed) {
        return;
      }
      _fail('保存 Web 会话失败：$e');
    } finally {
      _busy = false;
    }
  }

  /// 第二段：铸 Web token（sp_dc + TOTP → /api/token）。401 丢弃会话；
  /// 其他失败降级为提示，token 可以稍后重新获取。
  Future<void> _prepare() async {
    final revision = _revision;
    _stage = WebLoginStage.preparing;
    notifyListeners();
    try {
      await prepareWebToken();
      if (_finished || revision != _revision) return;
      _notice = null;
    } catch (e) {
      if (_finished || revision != _revision) return;
      if (e is WebTokenHttpException && e.statusCode == 401) {
        invalidateSession();
        return;
      }
      _notice = webTokenMintNotice(e);
    }
    if (_finished ||
        revision != _revision ||
        _stage != WebLoginStage.preparing) {
      return;
    }
    await _startDesktop();
  }

  /// 第三段：桌面 OAuth 没做就后台无感补上。
  Future<void> _startDesktop() async {
    final revision = _revision;
    if (_finished || _stage == WebLoginStage.failed) return;
    if (desktopSignedIn()) {
      _desktopDone = true;
      _complete();
      return;
    }
    _stage = WebLoginStage.desktopAuthorize;
    _desktopStartedAt = now?.call() ?? DateTime.now();
    notifyListeners();
    Uri? url;
    try {
      url = await beginDesktopOAuth();
    } catch (e) {
      if (_finished || revision != _revision) return;
      _fail('无法开始桌面授权：$e');
      return;
    }
    if (_finished ||
        revision != _revision ||
        _stage != WebLoginStage.desktopAuthorize) {
      return;
    }
    if (desktopSignedIn()) {
      _desktopDone = true;
      _complete();
      return;
    }
    if (url == null) {
      _fail('无法开始桌面授权，请重试');
      return;
    }
    desktopAuthorizeUrl = url;
    notifyListeners();
    onAuthorizeUrl?.call(url);
  }

  /// UI 通知：桌面 OAuth 已完成（AuthProvider 转为已登录）。
  void onDesktopAuthorized() {
    if (_finished || _stage != WebLoginStage.desktopAuthorize) return;
    _desktopDone = true;
    _complete();
  }

  /// UI 通知：桌面 OAuth 失败（回环超时 / 用户拒绝 / 令牌换取失败）。
  void onDesktopFailed(String message) {
    if (_finished || _stage != WebLoginStage.desktopAuthorize) return;
    _fail(message);
  }

  /// 失败后重试：Web 会话已到手时直接重发桌面授权（先取消上一次挂着的回环）。
  Future<void> retry() async {
    if (_busy || _finished) return;
    final revision = _revision;
    _busy = true;
    try {
      _error = null;
      if (webSignedIn) {
        try {
          await cancelDesktopOAuth?.call();
        } catch (_) {}
        if (_finished || revision != _revision) return;
        desktopAuthorizeUrl = null;
        _stage = WebLoginStage.preparing;
        notifyListeners();
        await _startDesktop();
      } else {
        _stage = WebLoginStage.webSignIn;
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  /// 关页清理：取消进行中的桌面授权。
  Future<void> cancel() async {
    ++_revision;
    if (_finished) return;
    _finished = true;
    try {
      await cancelDesktopOAuth?.call();
    } catch (_) {}
  }

  void _complete() {
    if (_finished) return;
    _finished = true;
    _stage = WebLoginStage.done;
    notifyListeners();
    onFinished?.call(this);
  }

  void _fail(String message) {
    if (_finished) return;
    // 不置 _finished：失败态可 retry；poll / 授权回调只在对应阶段才推进
    _stage = WebLoginStage.failed;
    _error = message;
    notifyListeners();
  }

  /// A rejected account session must return to Web login, never continue with
  /// the captured cookie or a late OAuth completion.
  void invalidateSession() {
    ++_revision;
    spDc = null;
    _desktopDone = false;
    desktopAuthorizeUrl = null;
    _notice = null;
    _fail('登录已失效，已清除登录状态，请重新登录');
  }
}

/// 铸造失败的非致命提示：TLS 证书被拦截时给出可行动的说明，其余原样展示。
/// 证书详情（issuer 等）由 ProxyHttpOverrides 的日志钩子写进诊断日志。
String webTokenMintNotice(Object error) {
  if (error is HandshakeException) {
    return 'TLS 证书验证失败，无法连接 Spotify（$error）。'
        '若有代理 / 安全软件在拦截 HTTPS，请为其配置公共证书或先关闭。';
  }
  return 'Web token 暂未取到（$error），稍后会自动重试';
}

/// 统一登录流程所处阶段。
enum WebLoginStage {
  /// 等 WebView 里的 Web 登录完成（轮询 sp_dc）。
  webSignIn,

  /// sp_dc 已到手：保存 + 铸 Web token。
  preparing,

  /// 后台桌面授权中（授权页已装载，等回环回调）。
  desktopAuthorize,

  /// 全部完成。
  done,

  /// 出错（[WebLoginFlow.error] 有值），可 [WebLoginFlow.retry]。
  failed,
}

/// 自动确认仅限 Spotify 的 HTTPS 账号页面。
bool isSpotifyAccountsPageUrl(String? url) {
  final uri = Uri.tryParse(url ?? '');
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'accounts.spotify.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;
}

/// 「同意」仅在授权页匹配；登录后明确的「继续使用应用」可在账号站的中间页匹配。
bool isConsentPageUrl(String? url) {
  final uri = Uri.tryParse(url ?? '');
  if (uri == null || !isSpotifyAccountsPageUrl(url)) return false;
  return uri.pathSegments.any((s) => s == 'authorize' || s == 'consent');
}

/// 回环回调判定：`http://127.0.0.1:<port><path>?code=…`（授权码已在路上）。
bool isLoopbackRedirect(
  String? url, {
  int port = 8898,
  String path = '/login',
}) {
  final uri = Uri.tryParse(url ?? '');
  if (uri == null) return false;
  return uri.scheme == 'http' &&
      uri.userInfo.isEmpty &&
      (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
      uri.port == port &&
      uri.path == path;
}

/// 多语言授权确认：匹配完整文字，检查可见 / 可点击状态；同一节点只点击一次。
/// React 异步渲染由限时 MutationObserver 处理，每次点击前重新校验地址。
const String kConsentAutoApproveScript = r'''
(() => {
  const trusted = () => location.protocol === 'https:' && location.hostname === 'accounts.spotify.com' &&
    (!location.port || location.port === '443') && !location.username && !location.password;
  if (!trusted()) return '';
  const consentPage = () => location.pathname.split('/').some(p => p === 'authorize' || p === 'consent');
  const agree = ['agree', 'agree and continue', 'agree & continue', 'agree to continue', 'allow access',
    '同意', '同意并继续', '同意並繼續', '允许访问', '允許存取', '授权', '授權',
    'zustimmen', 'j’accepte', "j'accepte", 'accepter', 'aceptar', 'acepto', 'concordo', 'aceitar',
    'accetto', 'accetta', 'akkoord', 'godkänn', 'godta', 'accepterer', 'hyväksyn',
    'zgadzam się', 'souhlasím', 'elfogadom', 'kabul et', 'согласен', '同意する', '동의', 'setuju'];
  const proceed = ['continue to app', 'continue to the app', 'continue using the app',
    '继续使用应用', '继续使用此应用', '继续前往应用', '繼續使用應用程式', '繼續使用應用', '繼續前往應用程式',
    'weiter zur app', 'zur app', 'continuer vers l’application', "continuer vers l'application",
    'continuer sur l’application', "continuer sur l'application", 'accéder à l’application', "accéder à l'application",
    'continuar a la aplicación', 'continuar en la aplicación', 'ir a la aplicación',
    'continuar para o aplicativo', 'continuar para a aplicação', 'continuar no aplicativo',
    'continua nell’app', "continua nell'app", 'vai all’app', "vai all'app", 'doorgaan naar app',
    'doorgaan naar de app', 'fortsätt till appen', 'fortsett til appen', 'fortsæt til appen',
    'jatka sovellukseen', 'przejdź do aplikacji', 'pokračovat do aplikace', 'tovább az alkalmazáshoz',
    'uygulamaya devam et', 'перейти в приложение', 'продовжити в застосунку',
    'アプリに進む', 'アプリの使用を続行', '앱으로 계속', '앱으로 이동', 'lanjutkan ke aplikasi',
    'teruskan ke aplikasi', 'tiếp tục đến ứng dụng', 'ดำเนินการต่อไปยังแอป', 'المتابعة إلى التطبيق'];
  const norm = (s) => (s || '').normalize('NFKC').replace(/\s+/g, ' ').trim().toLowerCase();
  const state = window.__flutifyConsentState ||= { clicked: new WeakSet(), observer: null };
  const click = () => {
    if (!trusted()) return '';
    const nodes = document.querySelectorAll('button, [role="button"], input[type="submit"], a[href]');
    for (const n of nodes) {
      if (state.clicked.has(n) || n.disabled || n.getAttribute('aria-disabled') === 'true' ||
          n.closest('[hidden], [inert], [aria-hidden="true"]') || !n.getClientRects().length) continue;
      const style = getComputedStyle(n);
      if (style.visibility !== 'visible' || style.display === 'none' || style.opacity === '0') continue;
      const t = norm(n.innerText || n.value || n.getAttribute('aria-label'));
      if (!t) continue;
      if (proceed.includes(t) || (consentPage() && agree.includes(t))) {
        state.clicked.add(n);
        n.click();
        return t;
      }
    }
    return '';
  };
  const stop = () => {
    state.observer?.disconnect();
    state.observer = null;
    clearTimeout(state.timer);
  };
  const hit = click();
  if (hit) { stop(); return hit; }
  if (state.observer) return '';
  state.observer = new MutationObserver(() => {
    if (!trusted() || click()) stop();
  });
  state.observer.observe(document.documentElement, { childList: true, subtree: true,
    characterData: true, attributes: true, attributeFilter: ['disabled', 'aria-disabled', 'hidden', 'style', 'class'] });
  state.timer = setTimeout(stop, 12000);
  return '';
})()
''';
