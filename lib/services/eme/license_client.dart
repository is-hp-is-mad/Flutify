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
  LicenseHttpException(this.statusCode, {required this.isCertificate})
    : super('DRM ${isCertificate ? 'certificate' : 'license'} HTTP $statusCode');

  final int statusCode;
  final bool isCertificate;

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

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';

  List<String> get _hostsOrder => [
    ?lastGoodHost,
    for (final h in hosts)
      if (h != lastGoodHost) h,
  ];

  /// license 反代：POST `<service>/v1/audio/license`，返回 license 响应体。
  /// FairPlay 的请求形态见 [fairPlayLicenseUri]（`?assetId=hex`，体为原样 SPC）。
  Future<Uint8List> postLicense(Uint8List request) async {
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
      debugPrint('[eme] license 反代异常: $e');
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
      debugPrint('[eme] 证书反代异常: $e');
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
          throw LicenseHttpException(
            res.statusCode,
            isCertificate: name == 'application-certificate',
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
