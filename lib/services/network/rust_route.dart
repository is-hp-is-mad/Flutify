import '../../core/rust_core.dart';
import '../../models/proxy_mode.dart';
import '../../src/rust/api/net_config.dart' as rust;
import 'network_proxy.dart';
import 'proxy_endpoint.dart';

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

/// 当前网络设置对应的 Rust 全局网络配置（Spotify 主机的代理 + 自建网关）。
///
/// Rust 内自行选路的连接（AP 长连接、会话令牌续期）按它连接：网关启用时 AP 经
/// `wss://网关/__tunnel/{host}:{port}` 隧道，连接网关主机用 [RustNetConfig.gatewayProxy]。
/// 网关已启用但配置无效时抛 [StateError]（与 Dart 侧 [SpotifyGateway.route] 一致，不悄悄直连）。
Future<rust.RustNetConfig> rustNetConfigFor({NetworkProxy? proxy}) async {
  final p = proxy ?? NetworkProxy.instance;
  final spotify = await p.endpointForAsync(
    Uri.parse('https://apresolve.spotify.com/'),
  );
  final gateway = p.gateway;
  var gatewayBase = '';
  var gatewayProxy = '';
  if (gateway.enabled) {
    final base = gateway.base;
    if (base == null || !gateway.isValid) {
      throw StateError('自建网关配置无效');
    }
    gatewayBase = base.toString();
    final endpoint = await p.endpointForAsync(base);
    gatewayProxy = endpoint == null ? '' : _proxyUrl(p, endpoint);
  }
  return rust.RustNetConfig(
    proxy: spotify == null ? '' : _proxyUrl(p, spotify),
    gatewayBase: gatewayBase,
    gatewayUsername: gateway.enabled ? gateway.username : '',
    gatewayPassword: gateway.enabled ? gateway.password : '',
    gatewayProxy: gatewayProxy,
  );
}

/// 把当前网络设置推送给 Rust（Rust 核心未加载时什么都不做）。
/// 代理可能随系统设置 / PAC 变化，每次建立 Rust 自行选路的长连接前调用一次。
Future<void> pushRustNetConfig({NetworkProxy? proxy}) async {
  if (!RustCore.ready) return;
  rust.rustNetConfigure(config: await rustNetConfigFor(proxy: proxy));
}

String? _pushedFingerprint;
DateTime _pushedAt = DateTime.fromMillisecondsSinceEpoch(0);

/// 网络设置变了（含关闭网关）、或距上次推送超过 1 分钟（系统代理 / PAC 可能变了）时重新推送给 Rust。
///
/// Rust 的统一出口（`http_client::send`）按推送的网关配置改写请求；网关关掉后若不推送，
/// Rust 会继续把请求发往网关，所以每次交给 Rust 发请求前都经过这里。
Future<void> pushRustNetConfigIfChanged({NetworkProxy? proxy}) async {
  if (!RustCore.ready) return;
  final p = proxy ?? NetworkProxy.instance;
  final g = p.gateway;
  final fingerprint = [
    p.mode.name,
    p.manual?.host,
    p.manual?.port,
    p.manualUsername,
    p.manualPassword.hashCode,
    g.enabled,
    g.baseUrl,
    g.username,
    g.password.hashCode,
  ].join('|');
  final now = DateTime.now();
  if (fingerprint == _pushedFingerprint &&
      now.difference(_pushedAt) < const Duration(minutes: 1)) {
    return;
  }
  await pushRustNetConfig(proxy: p);
  _pushedFingerprint = fingerprint;
  _pushedAt = now;
}
