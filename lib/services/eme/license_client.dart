import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../rust_backend_bridge.dart';
import 'fairplay.dart';

/// 服务的 DRM 体系（同一组入口与身份，按体系换端点与请求形态）。
/// 未显式指定时按平台默认：macOS → [fairplay]，其余 → [widevine]。
enum EmeDrmSystem { widevine, fairplay }

/// Status only: callers can report a server rejection without logging payloads.
class LicenseHttpException extends StateError {
  LicenseHttpException(
    this.statusCode, {
    required this.isCertificate,
    this.retryAfter,
  }) : super('DRM ${isCertificate ? 'certificate' : 'license'} HTTP $statusCode');

  final int statusCode;
  final bool isCertificate;

  /// 服务端 `Retry-After`（仅 429 / 503 时可能有）。
  final Duration? retryAfter;

  /// Spotify 限流（请求过于频繁）。
  bool get isThrottled => statusCode == 429;

  String get code =>
      '${isCertificate ? 'certificate' : 'license'}_http_$statusCode';
}

/// license / application-certificate 反代客户端（CDM 请求体 → Spotify）。
///
/// DRM 体系分两种（同名维护一把客户端，避免装配层分叉）：
/// - [EmeDrmSystem.widevine]：`widevine-license` 端点（Windows / Android）；
/// - [EmeDrmSystem.fairplay]：`fairplay-license` 端点（macOS / iOS，WKWebView 无 Widevine，
///   只能用系统自带 FairPlay CDM；端点语义对齐 Spotify Web 播放器的 FPS 客户端，
///   见 fairplay.dart）。
///
/// 为什么要多入口：手机网络下部分 Spotify 域名会被掐 TLS 握手
/// （`HandshakeException: Connection terminated during handshake`），而同一服务的
/// 其它 spclient 入口可达——协议下载走的 `spclient.wg` 实测最稳，license 也在
/// `spclient.wg.spotify.com/widevine-license/v1/audio/license` 上正常应答
/// （见 `SpotifyApi/api-docs/06-播放与音视频/补充-音频流DRM与连接.md`）。
///
/// 行为：
/// - 每个请求按 [hosts] 顺序换入口尝试；网络类错误（握手被掐 / 超时 / 连接重置）
///   换下一个入口；
/// - HTTP 非 200 直接抛出，不轮换入口重试；403 可能涉及身份、权限或 CDM
///   请求 / 宿主兼容性，仅凭状态码不能确定原因；
/// - 成功过的入口记进 [lastGoodHost]，下次优先用它，避免每次都先撞一次失败的握手。
class WidevineLicenseClient {
  WidevineLicenseClient({
    required this.webToken,
    required this.clientToken,
    http.Client? client,
    this.hosts = defaultHosts,
    this.timeout = const Duration(seconds: 12),
    this.drmSystem,
    this.throttleBackoff = const Duration(seconds: 5),
    this.maxThrottleHold = const Duration(seconds: 15),
  }) : _customClient = client != null,
       _client = client ?? http.Client();

  /// Web 播放器 access_token（Widevine 真密钥的身份凭据，sp_dc + TOTP 铸造）。
  final Future<String> Function() webToken;

  /// client-token（license / 证书都要）。
  final Future<String> Function() clientToken;

  /// spclient 入口，按顺序尝试。`spclient.wg` 是总入口，实测手机网络下最稳。
  static const List<String> defaultHosts = [
    'spclient.wg.spotify.com',
    'gae2-spclient.spotify.com',
    'gew1-spclient.spotify.com',
    'gue1-spclient.spotify.com',
  ];

  final bool _customClient;
  final http.Client _client;
  final List<String> hosts;
  final Duration timeout;

  /// DRM 体系；null 时平台默认（macOS / iOS → fairplay，其余 → widevine，见 [useFairPlay]）。
  final EmeDrmSystem? drmSystem;

  /// 生效的 DRM 体系。
  EmeDrmSystem get effectiveDrmSystem =>
      drmSystem ??
      (useFairPlay ? EmeDrmSystem.fairplay : EmeDrmSystem.widevine);

  bool get _fairPlay => effectiveDrmSystem == EmeDrmSystem.fairplay;

  /// 最近一次成功的入口；下次优先用它。
  String? lastGoodHost;

  /// 被限流（429）后的首次冷却时长；连续限流时逐级翻倍，最长 60 秒。
  final Duration throttleBackoff;

  /// 冷却剩余时间不超过它时，把 license 请求挂起到冷却结束再发（播放只是晚一点开始）；
  /// 否则直接报限流。hls.js 侧的首字节超时要大于它（见 eme_page_html.dart 的 keyLoadPolicy）。
  final Duration maxThrottleHold;

  DateTime? _throttledUntil;
  int _throttleLevel = 0;

  /// 当前是否处于限流冷却期（界面可据此提示「稍后再试」）。
  bool get isThrottled =>
      _throttledUntil != null && DateTime.now().isBefore(_throttledUntil!);

  void _enterThrottle(LicenseHttpException e) {
    final backoff = throttleBackoff * (1 << _throttleLevel.clamp(0, 4));
    var wait = e.retryAfter ?? backoff;
    if (wait > const Duration(seconds: 60)) wait = const Duration(seconds: 60);
    _throttledUntil = DateTime.now().add(wait);
    _throttleLevel++;
    debugPrint('[eme] license 被限流（HTTP 429），${wait.inSeconds}s 内不再请求');
  }

  /// 冷却中：剩余时间短就等过去，长就直接报限流（不打到 Spotify，避免越重试限流越久）。
  Future<void> _awaitThrottle() async {
    final until = _throttledUntil;
    if (until == null) return;
    final remaining = until.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    if (remaining > maxThrottleHold) {
      throw LicenseHttpException(429, isCertificate: false, retryAfter: remaining);
    }
    await Future<void>.delayed(remaining);
  }

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';

  List<String> get _hostsOrder => [
    ?lastGoodHost,
    for (final h in hosts)
      if (h != lastGoodHost) h,
  ];

  /// license 反代：POST `<service>/v1/audio/license`，返回 license 响应体。
  /// FairPlay 的请求形态见 [fairPlayLicenseUri]（`?assetId=hex`，体为原样 SPC）。
  ///
  /// Spotify 返回 429 时进入冷却（见 [throttleBackoff]）：冷却期内不发请求；冷却够短就挂起等过去再试一次。
  Future<Uint8List> postLicense(Uint8List request) async {
    for (var attempt = 0; ; attempt++) {
      await _awaitThrottle();
      try {
        final body = await _postLicenseOnce(request);
        _throttleLevel = 0;
        _throttledUntil = null;
        return body;
      } on LicenseHttpException catch (e) {
        if (!e.isThrottled) rethrow;
        _enterThrottle(e);
        final remaining = _throttledUntil!.difference(DateTime.now());
        if (attempt > 0 || remaining > maxThrottleHold) rethrow;
      }
    }
  }

  Future<Uint8List> _postLicenseOnce(Uint8List request) async {
    try {
      final token = await webToken();
      final ct = await clientToken();
      if (!_customClient && RustCore.ready) {
        final proxy = await RustBackendBridge.proxyForUrl(
          'https://spclient.wg.spotify.com/widevine-license/v1/audio/license',
        );
        if (proxy != null) {
          final path = _fairPlay
              ? '/fairplay-license/v1/audio/license?assetId=hex'
              : '/widevine-license/v1/audio/license';
          try {
            final res = await rust.rustRelayDrmRequest(
              hosts: _hostsOrder,
              method: 'POST',
              pathAndQuery: path,
              bearerToken: token,
              clientToken: ct,
              requestBody: request,
              timeoutMs: BigInt.from(timeout.inMilliseconds),
              proxy: proxy,
            );
            if (res.status != 200) {
              throw LicenseHttpException(res.status, isCertificate: false);
            }
            lastGoodHost = res.host;
            return res.body;
          } on StateError {
            rethrow;
          } catch (_) {}
        }
      }
      return await _request('audio/license', (host) {
        final uri = _fairPlay
            ? fairPlayLicenseUri(host)
            : Uri.parse('https://$host/widevine-license/v1/audio/license');
        return _client.post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'client-token': ct,
            'User-Agent': _ua,
            'Referer': 'https://open.spotify.com/',
            'Content-Type': 'application/octet-stream',
          },
          body: request,
        );
      });
    } catch (e) {
      debugPrint('[eme] license 中转异常: $e');
      rethrow;
    }
  }

  /// application-certificate 反代。
  /// Widevine 只需 client-token；FairPlay 对齐 Web 播放器（播放态证书请求带鉴权，
  /// Authorization + client-token 都发）。
  Future<Uint8List> fetchCert() async {
    try {
      final ct = await clientToken();
      final token = _fairPlay ? await webToken() : null;
      if (!_customClient && RustCore.ready) {
        final proxy = await RustBackendBridge.proxyForUrl(
          'https://spclient.wg.spotify.com/widevine-license/v1/application-certificate',
        );
        if (proxy != null) {
          final path = _fairPlay
              ? '/fairplay-license/v1/application-certificate'
              : '/widevine-license/v1/application-certificate';
          try {
            final res = await rust.rustRelayDrmRequest(
              hosts: _hostsOrder,
              method: 'GET',
              pathAndQuery: path,
              bearerToken: token,
              clientToken: ct,
              requestBody: null,
              timeoutMs: BigInt.from(timeout.inMilliseconds),
              proxy: proxy,
            );
            if (res.status != 200) {
              throw LicenseHttpException(res.status, isCertificate: true);
            }
            lastGoodHost = res.host;
            return res.body;
          } on StateError {
            rethrow;
          } catch (_) {}
        }
      }
      return await _request('application-certificate', (host) {
        final uri = _fairPlay
            ? fairPlayCertUri(host)
            : Uri.parse(
                'https://$host/widevine-license/v1/application-certificate',
              );
        return _client.get(
          uri,
          headers: {
            if (token != null) 'Authorization': 'Bearer $token',
            'client-token': ct,
            'User-Agent': _ua,
            'Referer': 'https://open.spotify.com/',
          },
        );
      });
    } catch (e) {
      debugPrint('[eme] 证书中转异常: $e');
      rethrow;
    }
  }

  /// 按入口顺序发请求；网络错误换入口，业务错误直接抛。
  Future<Uint8List> _request(
    String name,
    Future<http.Response> Function(String host) send,
  ) async {
    final order = [
      ?lastGoodHost,
      for (final h in hosts)
        if (h != lastGoodHost) h,
    ];
    Object? lastError;
    for (final host in order) {
      try {
        final res = await send(host).timeout(timeout);
        debugPrint(
          '[eme] license $name @ $host → HTTP ${res.statusCode} ${res.bodyBytes.length}B',
        );
        if (res.statusCode != 200) {
          final retryAfter = int.tryParse(res.headers['retry-after'] ?? '');
          throw LicenseHttpException(
            res.statusCode,
            isCertificate: name == 'application-certificate',
            retryAfter: retryAfter == null ? null : Duration(seconds: retryAfter),
          );
        }
        lastGoodHost = host;
        return res.bodyBytes;
      } on StateError {
        rethrow; // 业务错误：换入口无益
      } catch (e) {
        lastError = e;
        debugPrint('[eme] license $name @ $host 连接失败，换入口：$e');
      }
    }
    throw StateError('license $name 失败（所有入口均不可达）：$lastError');
  }
}
