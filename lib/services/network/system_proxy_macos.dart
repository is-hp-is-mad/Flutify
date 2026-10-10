import 'proxy_endpoint.dart';
import 'system_proxy.dart';

/// 解析 macOS 原生通道返回的系统代理快照。
///
/// 原生端（macos/Runner/SystemProxyChannel.swift，MethodChannel
/// `flutify/system_proxy`）把 `CFNetworkCopySystemProxySettings` 的结果拍平成
/// 只含简单类型（Bool / Int / String / String 数组）的 map 传过来：
///
/// - `httpEnabled` / `httpHost` / `httpPort`：Web 代理（HTTP）；
/// - `httpsEnabled` / `httpsHost` / `httpsPort`：安全 Web 代理（HTTPS）；
/// - `socksEnabled` / `socksHost` / `socksPort`：SOCKS 代理；
/// - `pacEnabled` / `pacUrl`：自动代理配置（PAC）；
/// - `exceptions`：不走代理的主机 / 域名规则数组；
/// - `excludeSimpleHostnames`：绕过不带点的主机名（映射为 Windows 同款 `<local>`）；
/// - `ftpPassive`：FTP 被动模式（与本类无关，透传给上一层调试用）。
///
/// 与 Windows（[SystemProxySettings.fromWindows]）保持同一套取舍：
/// - HTTPS 未单独开代理时回退用 HTTP 代理（同 [SystemProxySettings.fromEnvironment]）；
/// - SOCKS 由 [ProxyTunnel] 自建握手；
/// - PAC 暂不支持，按直连处理（Clash 等工具通常同时填 HTTP/HTTPS，实际不受影响）。
///
/// 纯 Dart、不依赖 Flutter：命令行探针（tool/）可复用，单元测试直接喂 map。
SystemProxySettings systemProxySettingsFromMacOS(Map<dynamic, dynamic> map) {
  bool flag(String key) {
    final v = map[key];
    if (v is bool) return v;
    // 原生端 NSNumber 可能桥接成 Int
    if (v is num) return v != 0;
    return false;
  }

  String host(String key) {
    final v = map[key];
    return v is String ? v.trim() : '';
  }

  int port(String key) {
    final v = map[key];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  ProxyEndpoint? endpoint(String enabledKey, String hostKey, String portKey) {
    if (!flag(enabledKey)) return null;
    final h = host(hostKey);
    final p = port(portKey);
    if (h.isEmpty || p <= 0 || p > 65535) return null;
    return ProxyEndpoint(h, p);
  }

  final http = endpoint('httpEnabled', 'httpHost', 'httpPort');
  final https = endpoint('httpsEnabled', 'httpsHost', 'httpsPort') ?? http;
  final socksEndpoint = endpoint('socksEnabled', 'socksHost', 'socksPort');
  final socks = socksEndpoint == null
      ? null
      : ProxyEndpoint(
          socksEndpoint.host,
          socksEndpoint.port,
          type: ProxyType.socks5,
        );

  final bypass = <String>[];
  final exceptions = map['exceptions'];
  if (exceptions is List) {
    for (final item in exceptions) {
      if (item is String && item.trim().isNotEmpty) bypass.add(item);
    }
  }
  if (flag('excludeSimpleHostnames')) bypass.add('<local>');

  return SystemProxySettings(
    http: http,
    https: https,
    socks: socks,
    bypass: bypass,
  );
}
