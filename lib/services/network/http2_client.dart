import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;
import 'direct_route.dart';
import 'network_proxy.dart';

/// Spotify API 请求经 Rust HTTP/2 客户端发送（一条连接多路复用），其余照旧走 [inner]。
///
/// 只接管「直连、不走网关」的 Spotify API 请求：网关 / 代理（含 PAC、认证代理）、证书诊断都在
/// Dart 网络层（[ProxyHttpOverrides]）里，这里不重做一遍。Rust 侧建连 / TLS 失败（请求尚未发出）
/// 时改走 [inner] 重试，最坏情况就是现在的行为；同一主机连续失败后本次运行不再尝试。
class Http2Client extends http.BaseClient {
  final http.Client inner;
  final NetworkProxy _proxy;

  /// 测试注入：替代 Rust 调用（null 时用 [rust.httpSend]）。
  @visibleForTesting
  final Future<rust.HttpResponseData> Function(
    String method,
    String url,
    List<rust.HttpHeaderEntry> headers,
    Uint8List body,
  )?
  sendOverride;

  /// 测试注入：视为 Rust 核心可用。
  @visibleForTesting
  final bool? enabledOverride;

  Http2Client(
    this.inner, {
    NetworkProxy? proxy,
    this.sendOverride,
    this.enabledOverride,
  }) : _proxy = proxy ?? NetworkProxy.instance;

  static const Duration timeout = Duration(seconds: 30);

  /// 同一主机连续建连失败达到此数后，本次运行不再走 Rust。
  static const int maxConnectFailures = 3;
  static final Map<String, int> _connectFailures = {};

  @visibleForTesting
  static void resetFailures() => _connectFailures.clear();

  /// 走 Rust 的主机：返回 JSON / protobuf 的 Spotify API。登录（accounts / open）与图片 CDN 不在内。
  static bool isApiHost(String host) {
    const exact = {
      'spclient.wg.spotify.com',
      'api-partner.spotify.com',
      'api.spotify.com',
      'clienttoken.spotify.com',
      'apresolve.spotify.com',
    };
    if (exact.contains(host)) return true;
    // apresolve 下发的接入点，如 gae2-spclient.spotify.com / guc3-spclient.spotify.com
    return host.endsWith('-spclient.spotify.com');
  }

  bool get _enabled => enabledOverride ?? RustCore.ready;

  Future<bool> _eligible(Uri url) async {
    if (!_enabled || url.scheme != 'https' || !isApiHost(url.host)) return false;
    if ((_connectFailures[url.host] ?? 0) >= maxConnectFailures) return false;
    return isDirectRoute(url, proxy: _proxy);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!await _eligible(request.url)) return inner.send(request);

    // 请求体只能读一次：先读出来，Rust 失败需要改走 inner 时用副本重发
    final body = await request.finalize().toBytes();
    final headers = [
      for (final e in request.headers.entries)
        rust.HttpHeaderEntry(name: e.key, value: e.value),
    ];
    final rust.HttpResponseData response;
    try {
      final send = sendOverride;
      response = await (send != null
          ? send(request.method, request.url.toString(), headers, body)
          : rust.httpSend(
              method: request.method,
              url: request.url.toString(),
              headers: headers,
              body: body,
              timeoutMs: BigInt.from(timeout.inMilliseconds),
            ));
    } catch (e) {
      final message = e.toString();
      if (message.contains('connect:')) {
        _connectFailures.update(request.url.host, (n) => n + 1, ifAbsent: () => 1);
        debugPrint('[HTTP/2] 建连失败，改走 Dart：${request.url.host} $message');
        return inner.send(_copy(request, body));
      }
      throw http.ClientException(message, request.url);
    }
    _connectFailures.remove(request.url.host);
    // Rust 端不跟随重定向；调用方要求跟随时交给 inner 照原样处理
    if (response.status >= 300 &&
        response.status < 400 &&
        request.followRedirects) {
      return inner.send(_copy(request, body));
    }

    final responseHeaders = <String, String>{};
    for (final h in response.headers) {
      final name = h.name.toLowerCase();
      // 与 package:http 一致：同名头以逗号合并
      responseHeaders.update(name, (v) => '$v,${h.value}', ifAbsent: () => h.value);
    }
    return http.StreamedResponse(
      Stream.value(response.body),
      response.status,
      contentLength: response.body.length,
      request: request,
      headers: responseHeaders,
      isRedirect: response.status >= 300 && response.status < 400,
      reasonPhrase: null,
    );
  }

  static http.Request _copy(http.BaseRequest original, Uint8List body) {
    final copy = http.Request(original.method, original.url)
      ..headers.addAll(original.headers)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection;
    if (body.isNotEmpty) copy.bodyBytes = body;
    return copy;
  }

  @override
  void close() => inner.close();
}
