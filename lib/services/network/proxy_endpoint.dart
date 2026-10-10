/// 代理协议：HTTP 代理（dart:io 可直接用）或 SOCKS5（由 [ProxyTunnel] 自建握手）。
enum ProxyType { http, socks5 }

/// HTTP / SOCKS5 代理地址（主机 + 端口 + 协议）。
///
/// 保持纯 Dart（不引入 Flutter）：命令行探针经 network_proxy → 本文件联网。
class ProxyEndpoint {
  final String host;
  final int port;
  final ProxyType type;

  const ProxyEndpoint(this.host, this.port, {this.type = ProxyType.http});

  /// 宽松解析「host:port」「http://host:port/」「socks5://host:port」「[::1]:port」；
  /// 无效时返回 null。带 scheme 时 scheme 决定协议（默认 HTTP）。
  /// 不用 [Uri]：它会把 http 的 80、https 的 443 当默认端口丢掉。
  static ProxyEndpoint? tryParse(String raw) {
    var s = raw.trim();
    var type = ProxyType.http;
    final scheme = s.indexOf('://');
    if (scheme >= 0) {
      final name = s.substring(0, scheme).trim().toLowerCase();
      if (name == 'socks' || name == 'socks5') type = ProxyType.socks5;
      s = s.substring(scheme + 3);
    }
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    final m = RegExp(
      r'^(?:\[([^\]]+)\]|([^:\s\[\]]+)):(\d{1,5})$',
    ).firstMatch(s);
    if (m == null) return null;
    final port = int.parse(m.group(3)!);
    if (port <= 0 || port > 65535) return null;
    return ProxyEndpoint(m.group(1) ?? m.group(2)!, port, type: type);
  }

  /// HttpClient.findProxy 的写法（IPv6 需要方括号）。
  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is ProxyEndpoint &&
      other.host == host &&
      other.port == port &&
      other.type == type;

  @override
  int get hashCode => Object.hash(host, port, type);
}
