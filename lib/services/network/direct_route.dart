import 'network_proxy.dart';

/// [url] 是否直连：不经网关改写、代理（含 PAC 求值）结果为直连。
///
/// Rust 网络栈（HTTP/2、音频下载、WebSocket）只接管直连请求；网关 / 代理 / 认证隧道 /
/// 证书诊断都在 Dart 网络层（ProxyHttpOverrides）里，非直连时照旧走 Dart。
Future<bool> isDirectRoute(Uri url, {NetworkProxy? proxy}) async {
  final p = proxy ?? NetworkProxy.instance;
  try {
    if (p.gateway.route(url) != url) return false;
  } on FormatException {
    return false;
  }
  return await p.endpointForAsync(url) == null;
}
