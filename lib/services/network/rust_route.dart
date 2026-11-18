import 'network_proxy.dart';
import 'proxy_endpoint.dart';
import '../../models/proxy_mode.dart';

/// Rust 网络栈（HTTP/2、音频下载、WebSocket）对一个请求应走的路线。
class RustRoute {
  /// 代理地址：`''` 为直连，否则 `http://[user:pass@]host:port` / `socks5h://host:port`。
  final String proxy;

  /// 实际连接的地址：不走网关时就是原地址；走网关时为 [SpotifyGateway.route] 改写后的网关地址。
  final Uri url;

  /// 需要额外加上的请求头（走网关时为网关凭据）。
  final Map<String, String> headers;

  const RustRoute({required this.proxy, required this.url, this.headers = const {}});

  bool get viaGateway => headers.isNotEmpty;

  /// [headers] 与本路线的额外请求头合并（同名以本路线为准，按名称不区分大小写）。
  Map<String, String> mergeHeaders(Map<String, String> headers) {
    if (this.headers.isEmpty) return headers;
    final overridden = {for (final k in this.headers.keys) k.toLowerCase()};
    return {
      for (final e in headers.entries)
        if (!overridden.contains(e.key.toLowerCase())) e.key: e.value,
      ...this.headers,
    };
  }
}

/// [url] 交给 Rust 时的路线；返回 null 表示交给 Dart 网络层（网关配置无效等）。
///
/// 选路（系统代理、PAC 求值、手动代理、绕过列表）仍由 [NetworkProxy] 完成，Rust 只按结果连接。
/// 网关与 Dart 侧（[GatewayHttpClient]）一致：地址按 [SpotifyGateway.route] 改写、带上网关头，
/// 代理按**网关主机**选取。Rust 不自动跟随重定向，网关凭据不会被带到其他服务器；
/// 需要跟随重定向的请求由调用方交回 Dart（它会相对原地址解析并重新经网关路由）。
Future<RustRoute?> rustRouteFor(Uri url, {NetworkProxy? proxy}) async {
  final p = proxy ?? NetworkProxy.instance;
  final Uri target;
  try {
    target = p.gateway.route(url);
  } on FormatException {
    return null;
  }
  final viaGateway = target != url;
  final endpoint = await p.endpointForAsync(target);
  return RustRoute(
    proxy: endpoint == null ? '' : _proxyUrl(p, endpoint),
    url: target,
    headers: viaGateway ? p.gateway.headers : const {},
  );
}

String _proxyUrl(NetworkProxy p, ProxyEndpoint endpoint) {
  final scheme = endpoint.type == ProxyType.socks5 ? 'socks5h' : 'http';
  final host = endpoint.host.contains(':') ? '[${endpoint.host}]' : endpoint.host;
  // 只有手动代理带认证信息（系统代理 / PAC 不提供用户名密码）
  var auth = '';
  if (p.mode == ProxyMode.manual && p.manualHasCredentials) {
    auth =
        '${Uri.encodeComponent(p.manualUsername)}:${Uri.encodeComponent(p.manualPassword)}@';
  }
  return '$scheme://$auth$host:${endpoint.port}';
}
