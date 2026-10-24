import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;
import '../storage_service.dart';
import 'web_token_exception.dart';
import 'session_http_client.dart';

/// Web 播放器 access_token 铸造服务。
///
/// 为什么需要它：Spotify 的 Widevine license 服务器按 access_token 身份发真/假密钥——
/// 桌面 client_id（65b708…）的 token 只给假密钥，**Web 播放器 token 才给真密钥**。
/// 本服务复刻 Web 播放器的令牌获取：sp_dc cookie + TOTP → `/api/token`。
///
/// TOTP secret 来自 web-player.js（版本 61），还原算法见 [_deobfuscateSecret]。
/// sp_dc 由一次性 Web 登录（WebView2 登录页）捕获，见 `web_login.dart`。
class WebTokenService {
  final StorageService _storage;
  final http.Client _client;

  WebTokenService(this._storage, [http.Client? client])
    : _client = SessionHttpClient(_storage, client ?? http.Client());

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

  /// 版本 61 的混淆 secret 原文（web-player.js 内嵌）。
  static const String _obfuscatedSecretV61 = ',7/*F("rLJ2oxaKL^f+E1xvP@N';

  /// 还原 TOTP secret：逐字符 `charCode ^ ((i % 33) + 9)`，结果数字 join 成十进制串，
  /// 该串的 UTF-8 字节即 secret（对应 JS 里 `Buffer.from(joined,'utf8')` 后 fromHex 的等价物）。
  static List<int> _deobfuscateSecret(String obfuscated) {
    if (RustCore.ready) {
      try {
        return rust.deobfuscateTotpSecret(obfuscated: obfuscated);
      } catch (_) {}
    }
    final codes = <int>[];
    for (var i = 0; i < obfuscated.length; i++) {
      codes.add(obfuscated.codeUnitAt(i) ^ ((i % 33) + 9));
    }
    final joined = codes.join();
    return utf8.encode(joined);
  }

  /// 标准 TOTP（SHA1 / 30s / 6 位），与 OTPAuth 一致。
  static String totp(
    List<int> secret,
    int timestampMs, {
    int period = 30,
    int digits = 6,
  }) {
    if (RustCore.ready) {
      try {
        return rust.generateTotp(
          secret: secret,
          timestampMs: timestampMs,
          period: period,
          digits: digits,
        );
      } catch (_) {}
    }
    final counter = timestampMs ~/ 1000 ~/ period;
    final msg = ByteData(8)..setUint64(0, counter, Endian.big);
    final h = Hmac(sha1, secret).convert(msg.buffer.asUint8List()).bytes;
    final off = h[h.length - 1] & 0x0F;
    final code =
        ((ByteData.sublistView(
              Uint8List.fromList(h),
              off,
              off + 4,
            ).getUint32(0, Endian.big)) &
            0x7FFFFFFF) %
        _pow10(digits);
    return code.toString().padLeft(digits, '0');
  }

  static int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) r *= 10;
    return r;
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
    final httpClient = client ?? http.Client();
    final secret = _deobfuscateSecret(_obfuscatedSecretV61);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final totpNow = totp(secret, nowMs);

    // 服务器时间对齐（可选，失败则 unavailable）
    String totpServer = 'unavailable';
    try {
      final st = await httpClient
          .get(Uri.parse(_serverTimeEndpoint))
          .timeout(const Duration(seconds: 4));
      final serverTime = jsonDecode(st.body)['serverTime'];
      if (serverTime is num) {
        totpServer = totp(secret, serverTime.toInt() * 1000);
      }
    } catch (_) {}

    final uri = Uri.parse(_tokenEndpoint).replace(
      queryParameters: {
        'reason': 'transport',
        'productType': 'web-player',
        'totp': totpNow,
        'totpVer': '$totpVersion',
        'totpServer': totpServer,
      },
    );
    final res = await httpClient
        .get(
          uri,
          headers: {
            'Cookie': 'sp_dc=$spDc',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw WebTokenHttpException(res.statusCode);
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
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
    final minted = await mintTokenForSpDc(dc, client: _client);
    _storage.checkSession(epoch);
    await _storage.writeSession(epoch, [
      () => _storage.setWebAccessToken(minted.token, minted.expiryMs),
    ]);
    return minted;
  }

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
}
