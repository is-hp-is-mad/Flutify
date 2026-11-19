import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust_backend;
import '../../src/rust/api/protocol.dart' as rust;
import '../network/http2_client.dart';
import '../rust_backend_bridge.dart';
import '../storage/auth_session_store.dart';
import 'auth_constants.dart';
import 'web_token_exception.dart';
import 'session_http_client.dart';
import 'session_token_source.dart';

/// Web 播放器 access_token 铸造服务。
///
/// 为什么需要它：Spotify 的 Widevine license 服务器按 access_token 身份发真/假密钥——
/// 桌面 client_id（65b708…）的 token 只给假密钥，**Web 播放器 token 才给真密钥**。
/// 本服务复刻 Web 播放器的令牌获取：sp_dc cookie + TOTP → `/api/token`。
///
/// TOTP secret 来自 web-player.js（版本 61），见 [_webPlayerTotp]。
/// 会话续期（[mintAccessToken] / [ensureWebAccessToken]）优先交给 Rust 会话核心（[SessionTokenSource]）。
/// sp_dc 由一次性 Web 登录（WebView2 登录页）捕获，见 `web_login.dart`。
class WebTokenService {
  final AuthSessionStore _storage;
  final http.Client _client;

  /// 登录第一次铸造专用：401 不触发 [SessionHttpClient] 的清除登录态，见 [mintForLogin]。
  final http.Client _loginClient;

  /// 令牌续期来源（生产为 Rust 会话核心）；为 null 时只用 Dart HTTP。
  final SessionTokenSource? _tokens;

  Future<String>? _inFlightEnsure;
  int _inFlightEnsureEpoch = -1;

  WebTokenService(
    this._storage, [
    http.Client? client,
    SessionTokenSource? tokens,
  ]) : _client = SessionHttpClient(_storage, client ?? http.Client()),
       _loginClient = Http2Client(client ?? http.Client()),
       // 与其他服务一致：注入自定义 http.Client（测试）时不走 Rust
       _tokens =
           tokens ?? (client == null ? const RustSessionTokenSource() : null);

  static const String _tokenEndpoint = 'https://open.spotify.com/api/token';
  static const String _serverTimeEndpoint =
      'https://open.spotify.com/api/server-time';

  // --- sp_dc 存取 ---

  String get spDc => _storage.spDc;
  bool get hasSpDc => _storage.spDc.isNotEmpty;
  ValueListenable<int> get sessionInvalidated => _storage.sessionInvalidated;
  Future<void> prepareForLogin() => _storage.prepareForLogin();
  void addCookieCleanupHook(Future<void> Function() hook) =>
      _storage.beforeCookieCleanup.add(hook);
  void removeCookieCleanupHook(Future<void> Function() hook) =>
      _storage.beforeCookieCleanup.remove(hook);
  Future<void> setSpDc(String value) async {
    final epoch = await _storage.beginLoginSession(
      expectedEpoch: _storage.sessionEpoch,
    );
    await _storage.writeSession(epoch, [
      () => _storage.setSpDc(value),
      () => _storage.setWebAccessToken('', 0),
    ]);
  }

  /// 清除 Web 登录态（登出时调用）。
  Future<void> clear() => _storage.clearWebSession();

  // --- TOTP ---

  /// 当前有效的 TOTP secret 版本（与 web-player.js 的 totpVer 对应）。
  static const int totpVersion = 61;

  /// 当前时刻的 6 位 Web 播放器 TOTP：生产由 Rust（`generate_web_player_totp_v61`，内置 V61 secret）生成，
  /// 未加载 Rust 核心时（单元测试）用 Dart 实现。
  static String _webPlayerTotp(int timestampMs) {
    if (RustCore.ready) {
      return rust.generateWebPlayerTotpV61(timestampMs: timestampMs);
    }
    return _dartTotpV61(timestampMs);
  }

  /// 版本 61 的混淆 secret 原文（web-player.js 内嵌）。
  static const String _obfuscatedSecretV61 = ',7/*F("rLJ2oxaKL^f+E1xvP@N';

  /// Dart 版 TOTP（SHA1 / 30s / 6 位），与 Rust `web_totp` 一致。
  /// secret 还原：逐字符 `charCode ^ ((i % 33) + 9)`，结果数字 join 成十进制串，取其 UTF-8 字节。
  static String _dartTotpV61(int timestampMs) {
    final codes = <int>[
      for (var i = 0; i < _obfuscatedSecretV61.length; i++)
        _obfuscatedSecretV61.codeUnitAt(i) ^ ((i % 33) + 9),
    ];
    final secret = utf8.encode(codes.join());
    final counter = timestampMs ~/ 1000 ~/ 30;
    final msg = ByteData(8)..setUint64(0, counter, Endian.big);
    final h = Hmac(sha1, secret).convert(msg.buffer.asUint8List()).bytes;
    final off = h[h.length - 1] & 0x0F;
    final code =
        (ByteData.sublistView(
              Uint8List.fromList(h),
              off,
              off + 4,
            ).getUint32(0, Endian.big) &
            0x7FFFFFFF) %
        1000000;
    return code.toString().padLeft(6, '0');
  }

  // --- token 铸造 ---

  /// 用给定的 [spDc] 独立铸造一个 Web access_token（不改动主账号存储，供多账号歌单备份复用）。
  static Future<({String token, int expiryMs})> mintTokenForSpDc(
    String spDc, {
    http.Client? client,
  }) async {
    if (spDc.isEmpty) {
      throw WebSignInRequiredException();
    }
    if (client == null && RustCore.ready) {
      try {
        final proxy = await RustBackendBridge.proxyForUrl(_tokenEndpoint);
        if (proxy != null) {
          final minted = await rust_backend.rustMintWebToken(
            spDc: spDc,
            proxy: proxy,
          );
          return (token: minted.token, expiryMs: minted.expiryMs.toInt());
        }
      } catch (e) {
        final msg = e.toString();
        final httpMatch = RegExp(r'http:(\d+):').firstMatch(msg);
        if (httpMatch != null) {
          final status = int.parse(httpMatch.group(1)!);
          debugPrint('[web-token] /api/token HTTP $status (rust)');
          throw WebTokenHttpException(status);
        }
        // connect:/timeout: 等传输错误回退到 Dart HTTP 客户端
      }
    }
    final httpClient = client ?? http.Client();
    try {
      final uri = await _tokenUri(httpClient);
      final res = await httpClient
          .get(
            uri,
            headers: {
              'Cookie': 'sp_dc=$spDc',
              'User-Agent': SpotifyAuthConstants.webUserAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));
      return _parseToken(res.statusCode, utf8.decode(res.bodyBytes));
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// 带 TOTP 的令牌地址。
  static Future<Uri> _tokenUri(http.Client httpClient) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final totpNow = _webPlayerTotp(nowMs);

    // 服务器时间对齐（可选，失败则 unavailable）
    String totpServer = 'unavailable';
    try {
      final st = await httpClient
          .get(
            Uri.parse(_serverTimeEndpoint),
            headers: {'User-Agent': SpotifyAuthConstants.webUserAgent},
          )
          .timeout(const Duration(seconds: 4));
      final serverTime = jsonDecode(st.body)['serverTime'];
      if (serverTime is num) {
        totpServer = _webPlayerTotp(serverTime.toInt() * 1000);
      }
    } catch (_) {}

    return Uri.parse(_tokenEndpoint).replace(
      queryParameters: {
        'reason': 'transport',
        'productType': 'web-player',
        'totp': totpNow,
        'totpVer': '$totpVersion',
        'totpServer': totpServer,
      },
    );
  }

  static ({String token, int expiryMs}) _parseToken(int status, String text) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (status != 200) {
      // 只记状态码：响应体可能含账号信息，不进日志
      debugPrint('[web-token] /api/token HTTP $status');
      throw WebTokenHttpException(status);
    }
    final body = jsonDecode(text) as Map<String, dynamic>;
    final token = body['accessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw StateError('铸造 Web token 失败：响应无 accessToken');
    }
    final expiryMs =
        (body['accessTokenExpirationTimestampMs'] as num?)?.toInt() ??
        (nowMs + 3600 * 1000);
    return (token: token, expiryMs: expiryMs);
  }

  /// 铸造一个 Web 播放器 access_token。需要 [spDc] 已设置。
  /// 返回 (token, expiryEpochMs)。失败抛异常。
  Future<({String token, int expiryMs})> mintAccessToken() async {
    final epoch = _storage.sessionEpoch;
    _storage.checkSession(epoch);
    final dc = _storage.spDc;
    if (dc.isEmpty) {
      throw WebSignInRequiredException();
    }
    final tokens = _tokens;
    final minted =
        (tokens == null ? null : await refreshWebTokenVia(tokens, _storage)) ??
        await mintTokenForSpDc(dc, client: _client);
    _storage.checkSession(epoch);
    await _storage.writeSession(epoch, [
      () => _storage.setWebAccessToken(minted.token, minted.expiryMs),
    ]);
    return minted;
  }

  /// 登录页拿到 `sp_dc` 后的第一次铸造。
  ///
  /// 这时的 cookie 是 Spotify 刚发的，401 不代表会话被吊销，更多是这次请求本身被拒绝
  /// （代理、VPN 出口、风控）。所以不走 [SessionHttpClient]：否则一次 401 就清空登录态和
  /// 全部 WebView cookie，用户明明登录成功却被踢回登录页，再登录还是一样（issue #53）。
  ///
  /// 被拒绝时隔一会儿重试一次，再不行就用登录页 WebView 自己发请求（[fetchInPage]，浏览器的
  /// 网络栈和 cookie）。都失败才把 [WebTokenHttpException] 抛给调用方。
  Future<({String token, int expiryMs})> mintForLogin({
    Future<({int status, String body})?> Function(Uri uri)? fetchInPage,
  }) async {
    final epoch = _storage.sessionEpoch;
    _storage.checkSession(epoch);
    final dc = _storage.spDc;
    if (dc.isEmpty) throw WebSignInRequiredException();
    Future<({String token, int expiryMs})> attempt() async {
      try {
        return await mintTokenForSpDc(dc, client: _loginClient);
      } on WebTokenHttpException catch (e) {
        debugPrint('[web-token] 登录铸造被拒绝：HTTP ${e.statusCode}，${loginRetryDelay.inMilliseconds} ms 后重试');
        await Future<void>.delayed(loginRetryDelay);
        _storage.checkSession(epoch);
        return mintTokenForSpDc(dc, client: _loginClient);
      }
    }

    ({String token, int expiryMs}) minted;
    try {
      minted = await attempt();
    } on WebTokenHttpException {
      final page = await fetchInPage?.call(await _tokenUri(_loginClient));
      if (page == null) rethrow;
      debugPrint('[web-token] 改用登录页 WebView 铸造：HTTP ${page.status}');
      minted = _parseToken(page.status, page.body);
    }
    _storage.checkSession(epoch);
    await _storage.writeSession(epoch, [
      () => _storage.setWebAccessToken(minted.token, minted.expiryMs),
    ]);
    return minted;
  }

  /// 登录页认定这份会话确实无效（重试后 Spotify 仍然拒绝）：清除登录态和 cookie，回到全新的登录。
  Future<void> rejectSession() =>
      _storage.invalidateSession(_storage.sessionEpoch);

  /// 取一个可用的 Web access_token：缓存未过期直接用，否则重新铸造。
  ///
  /// 手机网络下 `open.spotify.com` 的 TLS 握手偶发被掐（HandshakeException），
  /// 连接失败时按 [retries] 隔 [retryDelay] 重试；HTTP 拒绝、缺少登录态及
  /// 无效响应直接交给调用方。过期令牌不能兜底，否则会把连接错误变成下游 403。
  Future<String> ensureWebAccessToken({int retries = 2}) async {
    final epoch = _storage.sessionEpoch;
    _storage.checkSession(epoch);
    if (retries < 0) {
      throw ArgumentError.value(retries, 'retries', 'must be non-negative');
    }
    final cached = _storage.webAccessToken;
    final expiry = _storage.webAccessTokenExpiry;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (cached.isNotEmpty && expiry > nowMs + 60 * 1000) {
      return cached;
    }
    final existing = _inFlightEnsure;
    if (existing != null && _inFlightEnsureEpoch == epoch) {
      return await existing;
    }
    final future = _ensureWebAccessTokenUncached(
      epoch: epoch,
      cached: cached,
      expiry: expiry,
      retries: retries,
    );
    _inFlightEnsure = future;
    _inFlightEnsureEpoch = epoch;
    try {
      return await future;
    } finally {
      if (identical(_inFlightEnsure, future)) {
        _inFlightEnsure = null;
      }
    }
  }

  Future<String> _ensureWebAccessTokenUncached({
    required int epoch,
    required String cached,
    required int expiry,
    required int retries,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelay);
      _storage.checkSession(epoch);
      try {
        final minted = await mintAccessToken();
        return minted.token;
      } on StateError {
        rethrow;
      } on FormatException {
        rethrow;
      } catch (e, stack) {
        lastError = e;
        lastStack = stack;
        debugPrint('[web-token] 铸造失败（第 ${attempt + 1}/${retries + 1} 次）：$e');
      }
    }
    _storage.checkSession(epoch);
    if (cached.isNotEmpty && expiry > DateTime.now().millisecondsSinceEpoch) {
      debugPrint('[web-token] 铸造不可达，暂用仍有效的缓存 token');
      return cached;
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  /// 重试间隔（手机网络握手被掐通常是瞬时的，稍等即可恢复）。
  static const Duration retryDelay = Duration(seconds: 2);

  /// 登录铸造被拒绝后的重试间隔（新 cookie 偶尔要等片刻才在服务端生效）。
  @visibleForTesting
  static Duration loginRetryDelay = const Duration(milliseconds: 800);
}
