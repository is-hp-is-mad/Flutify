import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'proxy_endpoint.dart';
import 'proxy_mode.dart';
import 'proxy_tunnel.dart';
import 'system_proxy.dart';
import 'spotify_gateway.dart';
import 'gateway_http_client.dart';

/// 全局网络代理策略（设置 →「网络」）：所有 HTTP / WebSocket 请求与接入点的 TCP 连接都按它选路。
///
/// - [ProxyMode.system]：跟随系统代理（[SystemProxyReader]），读到的结果缓存 [systemTtl]，
///   过期后在后台重读，所以在 Clash 等工具里开关系统代理，几十秒内就会生效，不必重启；
/// - [ProxyMode.none]：一律直连；
/// - [ProxyMode.manual]：一律走手动填写的 HTTP 代理（地址无效时直连）。
///
/// 本机回环地址（localhost / 127.x / ::1）始终直连：播放器经本机端口读取解密后的音频；
/// 网易云音乐（[alwaysDirectDomains]）也始终直连，原因见该常量。
class NetworkProxy {
  NetworkProxy({
    Future<SystemProxySettings> Function()? systemReader,
    Future<String> Function()? countryReader,
    this.autoProxyResolver,
  }) : _systemReader = systemReader ?? SystemProxyReader.read,
       _countryReader = countryReader;

  /// App 使用的唯一实例（main 里按偏好配置，设置页修改时更新）。
  static final NetworkProxy instance = NetworkProxy();

  static const Duration systemTtl = Duration(seconds: 30);

  /// 无论哪种代理模式都直连的域名（连同其子域名）：网易云音乐（歌词译文）。
  ///
  /// 国内用户为了 Spotify 通常开着海外代理（Clash 等系统代理，或这里的手动代理），网易云的请求
  /// 跟着从海外出口出去会被风控拒绝（业务码 -460 / -462 等）。网易云在国内本来就能直连，走用户
  /// 自己的网络即可，不必伪造来源 IP。只认 music.163.com，163.com 的其他服务照常按代理设置选路。
  static const Set<String> alwaysDirectDomains = {'music.163.com'};

  /// [host] 是否命中 [alwaysDirectDomains]（域名本身或其子域名）。
  static bool isAlwaysDirect(String host) {
    final h = host.toLowerCase();
    return alwaysDirectDomains.any((d) => h == d || h.endsWith('.$d'));
  }

  final Future<SystemProxySettings> Function() _systemReader;
  final Future<String> Function()? _countryReader;

  /// Windows 自动配置（PAC / 自动检测）的逐 URL 求值；测试可注入。
  /// 为空时退回 [SystemProxyReader.windowsProxyResolver]（原生通道注入）。
  final Future<String> Function(String url)? autoProxyResolver;

  /// 自动配置结果按主机缓存：PAC 求值要走原生通道，连接前不宜每个请求都打一次。
  final Map<String, ({ProxyEndpoint? endpoint, DateTime at, Duration ttl})>
  _autoRoutes = {};

  /// 自动配置成功结果的缓存时长；PRX 求值失败 / 直连结果用更短 [autoProxyFailureTtl]，
  /// 免得 PAC 服务器一时不可达后整段时间都按直连走。
  static const Duration autoProxyTtl = Duration(minutes: 5);
  static const Duration autoProxyFailureTtl = Duration(seconds: 30);
  final _gatewayChanges = StreamController<void>.broadcast(sync: true);
  Stream<void> get gatewayChanges => _gatewayChanges.stream;
  String? gatewayCountry;
  bool gatewayChecking = false;
  bool gatewayLookupFailed = false;
  SpotifyGateway _gatewaySettings = const SpotifyGateway();
  int _generation = 0;
  Future<void>? _countryCheck;
  bool _configured = false;

  ProxyMode _mode = ProxyMode.system;
  ProxyEndpoint? _manual;
  SpotifyGateway gateway = const SpotifyGateway();
  String _manualUsername = '';
  String _manualPassword = '';
  SystemProxySettings _system = SystemProxySettings.none;
  DateTime? _systemReadAt;
  Future<void>? _refreshing;

  ProxyMode get mode => _mode;
  ProxyEndpoint? get manual => _manual;

  /// 手动代理的认证用户名 / 密码（[ProxyMode.manual] 的代理要求认证时才用，空表示无认证）。
  /// 由 [configure] 配置，密码本身不持久化在本类，来自 StorageService。
  String get manualUsername => _manualUsername;
  String get manualPassword => _manualPassword;

  /// 手动代理是否配置了凭据（用户名或密码任填一项即生效：有的代理只用用户名当令牌）。
  bool get manualHasCredentials =>
      _manualUsername.isNotEmpty || _manualPassword.isNotEmpty;

  /// 最近一次读到的系统代理（设置页展示用）。
  SystemProxySettings get system => _system;

  /// 按偏好更新策略；切到「跟随系统」时立即重读一次系统代理。
  ///
  /// 参数取自 AppPreferences + StorageService（本类不直接依赖 models / 存储，保持纯 Dart
  /// 以便命令行探针复用）；[proxyUsername] / [proxyPassword] 是手动代理的 Basic 认证凭据，可留空。
  Future<void> configure({
    required ProxyMode mode,
    String proxyHost = '',
    int proxyPort = 0,
    SpotifyGateway gateway = const SpotifyGateway(),
    String proxyUsername = '',
    String proxyPassword = '',
  }) {
    final changed =
        _gatewaySettings != gateway ||
        _mode != mode ||
        _manual?.toString() !=
            (proxyPort > 0 ? '$proxyHost:$proxyPort' : null) ||
        _manualUsername != proxyUsername ||
        _manualPassword != proxyPassword;
    if (changed) {
      _generation++;
      _countryCheck = null;
      gatewayChecking = false;
      gatewayLookupFailed = false;
      _autoRoutes.clear();
    }
    // The stored manual choice is not overwritten by an automatic decision.
    final enabled = gateway.automatic && _configured
        ? this.gateway.enabled
        : gateway.enabled;
    _configured = true;
    _gatewaySettings = gateway;
    this.gateway = gateway.copyWith(enabled: enabled);
    _mode = mode;
    _manual = proxyPort > 0
        ? ProxyEndpoint.tryParse('$proxyHost:$proxyPort')
        : null;
    _manualUsername = proxyUsername;
    _manualPassword = proxyPassword;
    _gatewayChanges.add(null);
    return () async {
      if (_mode == ProxyMode.system) await refreshSystem();
      if (changed) await refreshGatewayCountry();
    }();
  }

  /// Recheck on startup, network change, resume and a periodic timer.
  /// Failed/obsolete lookups never change the last effective route.
  Future<void> refreshGatewayCountry({bool networkChanged = false}) {
    if (!_gatewaySettings.automatic || !_gatewaySettings.isValid) {
      return Future.value();
    }
    if (networkChanged) {
      _generation++;
      _countryCheck = null;
    }
    final generation = _generation;
    // Defer execution so even an immediately throwing reader clears the future.
    return _countryCheck ??= Future<void>(() => _checkCountry(generation));
  }

  Future<void> _checkCountry(int generation) async {
    if (generation != _generation) return;
    gatewayChecking = true;
    _gatewayChanges.add(null);
    try {
      if (_mode == ProxyMode.system) await refreshSystem();
      final country = await (_countryReader?.call() ?? _readCountry()).timeout(
        const Duration(seconds: 8),
      );
      if (!RegExp(r'^[A-Z]{2}$').hasMatch(country) || country == 'XX') {
        throw const FormatException('Invalid country');
      }
      if (generation != _generation) return;
      final enabled = _gatewaySettings.enabledForCountry(country);
      gatewayCountry = country;
      gatewayLookupFailed = false;
      gateway = _gatewaySettings.copyWith(enabled: enabled);
    } catch (_) {
      if (generation == _generation) gatewayLookupFailed = true;
    } finally {
      if (generation == _generation) {
        gatewayChecking = false;
        _countryCheck = null;
        _gatewayChanges.add(null);
      }
    }
  }

  static String countryFromTrace(String trace) {
    final matches = RegExp(
      r'^loc=([A-Z]{2})\r?$',
      multiLine: true,
    ).allMatches(trace).toList();
    if (matches.length != 1 || matches.single.group(1) == 'XX') {
      throw const FormatException('Missing or invalid trace country');
    }
    return matches.single.group(1)!;
  }

  Future<String> _readCountry() async {
    // Bypass the Spotify gateway while honoring the selected forward proxy.
    final client = HttpClient()..findProxy = findProxy;
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      return await (() async {
        final request = await client.getUrl(
          Uri.parse('https://cloudflare.com/cdn-cgi/trace'),
        );
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw const HttpException('Country lookup failed');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 16384)
            throw const FormatException('Trace too large');
        }
        return countryFromTrace(utf8.decode(bytes));
      })().timeout(const Duration(seconds: 8));
    } finally {
      client.close(force: true);
    }
  }

  /// 重新读取系统代理（并发调用合并为一次）。
  Future<void> refreshSystem() => _refreshing ??= () async {
    try {
      _system = await _systemReader();
      _systemReadAt = DateTime.now();
    } finally {
      _refreshing = null;
    }
  }();

  /// [uri] 应经过的代理（静态配置）；null 表示直连。
  /// 自动配置（PAC / 自动检测）无法同步求值，见 [endpointForAsync]。
  ProxyEndpoint? endpointFor(Uri uri) {
    final host = uri.host;
    if (_isLoopback(host) || isAlwaysDirect(host)) return null;
    switch (_mode) {
      case ProxyMode.none:
        return null;
      case ProxyMode.manual:
        return _manual;
      case ProxyMode.system:
        final readAt = _systemReadAt;
        if (readAt == null || DateTime.now().difference(readAt) > systemTtl) {
          unawaited(refreshSystem());
        }
        if (_system.bypasses(host)) return null;
        return (uri.scheme == 'http' || uri.scheme == 'ws'
                ? _system.http
                : _system.https) ??
            _system.socks;
    }
  }

  Future<String> Function(String url)? get _autoResolver =>
      autoProxyResolver ?? SystemProxyReader.windowsProxyResolver;

  /// 是否必须由 [ProxyHttpOverrides] 自建隧道（dart:io 处理不了）：
  /// 自动配置（PAC / 自动检测）与 SOCKS5 代理。连接前同步判断（不触发原生解析）。
  bool usesSelfTunnel(Uri uri) {
    final host = uri.host;
    if (_isLoopback(host) || isAlwaysDirect(host)) return false;
    if (_mode == ProxyMode.system && _system.autoProxy) {
      if (_autoResolver != null) return !_system.bypasses(host);
    }
    return endpointFor(uri)?.type == ProxyType.socks5;
  }

  /// 按 URI 解析代理：[uri] 命中自动配置时用原生 WinHTTP 求值 PAC / 自动检测
  /// （结果按主机缓存），其余情况与 [endpointFor] 一致。
  Future<ProxyEndpoint?> endpointForAsync(Uri uri) async {
    final host = uri.host;
    if (_isLoopback(host) || isAlwaysDirect(host)) return null;
    if (_mode != ProxyMode.system || !_system.autoProxy) {
      return endpointFor(uri);
    }
    if (_system.bypasses(host)) return null;
    final resolver = _autoResolver;
    if (resolver == null) return endpointFor(uri);
    final now = DateTime.now();
    final cached = _autoRoutes[host];
    if (cached != null && now.difference(cached.at) < cached.ttl) {
      return cached.endpoint;
    }
    ProxyEndpoint? endpoint;
    Duration ttl = autoProxyTtl;
    try {
      endpoint = parseAutoProxyResult(await resolver(uri.toString()));
      if (endpoint == null) ttl = autoProxyFailureTtl;
    } catch (_) {
      // PAC 求值失败：退回静态配置（通常为直连），短缓存等下次重试
      endpoint = endpointFor(uri);
      ttl = autoProxyFailureTtl;
    }
    _autoRoutes[host] = (endpoint: endpoint, at: now, ttl: ttl);
    return endpoint;
  }

  /// WinHTTP / PAC 的代理串：`host:port`、`http://host:port`，可能带 `PROXY` /
  /// `SOCKS5` 前缀，也可能是空格 / 分号分隔的列表；`DIRECT` 跳过，全直连返回 null。
  static ProxyEndpoint? parseAutoProxyResult(String raw) {
    var type = ProxyType.http;
    for (final token in raw.split(RegExp(r'[;\s]+'))) {
      final t = token.trim();
      if (t.isEmpty) continue;
      final upper = t.toUpperCase();
      if (upper == 'DIRECT') continue;
      if (upper == 'PROXY' || upper == 'HTTP' || upper == 'HTTPS') {
        type = ProxyType.http;
        continue;
      }
      if (upper == 'SOCKS' || upper == 'SOCKS5' || upper == 'SOCKS4') {
        type = ProxyType.socks5;
        continue;
      }
      final parsed = ProxyEndpoint.tryParse(t);
      if (parsed != null) {
        return ProxyEndpoint(parsed.host, parsed.port, type: type);
      }
    }
    return null;
  }

  /// HTTPS / WSS 经需要认证的手动代理时，由 [ProxyHttpOverrides] 装的 connectionFactory
  /// 自建 CONNECT 隧道，dart:io 只当它是直连（[findProxy] 返回 DIRECT）。
  ///
  /// 凭据不能交给 dart:io：无论 `PROXY user:pass@…` 还是 addProxyCredentials，它都会把
  /// Proxy-Authorization 也加到隧道**里面**发给目标服务器的请求上，等于把代理密码发给
  /// Spotify、网易云等第三方。自建隧道时凭据只出现在发给代理的 CONNECT 上。
  bool tunnelsSecure(Uri uri) =>
      _mode == ProxyMode.manual &&
      manualHasCredentials &&
      (uri.isScheme('https') || uri.isScheme('wss')) &&
      endpointFor(uri)?.type == ProxyType.http;

  /// 供 [HttpClient.findProxy] 使用，须与 [ProxyHttpOverrides] 的 connectionFactory 配套：
  /// 需要认证的 HTTPS、SOCKS 与自动配置（PAC）在这里返回 DIRECT，
  /// 实际由 [ProxyHttpOverrides] 异步解析并自建隧道（见 [usesSelfTunnel] / [tunnelsSecure]）。
  String findProxy(Uri uri) {
    if (usesSelfTunnel(uri)) return 'DIRECT';
    final endpoint = endpointFor(uri);
    if (endpoint == null ||
        endpoint.type != ProxyType.http ||
        tunnelsSecure(uri)) {
      return 'DIRECT';
    }
    // 明文 HTTP 经认证代理：凭据嵌进代理串（`PROXY user:pass@host:port`），dart:io 随请求带上
    // Proxy-Authorization。明文请求本来就是发给代理的，代理消费这个逐跳头，不会到达目标；
    // 也省掉每个请求先吃一次 407 质询的往返。
    // 不用 authenticateProxy + addProxyCredentials：dart:io 的 Basic 代理凭据
    // 永不置 used 标记，密码错误时 407 → 自动重试会无限循环（实测 5 秒 2.8 万个请求）；
    // 嵌入凭据在密码错误时代理回 407，错误直接抛给调用方，清晰可查。
    if (_mode == ProxyMode.manual &&
        manualHasCredentials &&
        _embeddableInProxyString(_manualUsername, _manualPassword)) {
      return 'PROXY $_manualUsername:$_manualPassword@$endpoint';
    }
    return 'PROXY $endpoint';
  }

  /// 用户名是否可用于 Basic 认证：按 RFC 7617 不能含 `:`（它是用户名与密码的分隔符）。
  static bool isValidUsername(String user) => !user.contains(':');

  /// 凭据能否无损嵌入 findProxy 的代理串（只影响明文 HTTP；HTTPS 走自建隧道，任意字符都行）。
  ///
  /// 按 dart:io 的解析：整串按 `;` 分段，最后一个 `@` 之前是身份，按第一个 `:` 拆出用户名与密码
  /// 并各自 trim，两者都不能为空。不满足时明文 HTTP 退化为不带凭据；HTTPS / WSS 仍由自建
  /// CONNECT 隧道带上原始凭据。
  static bool _embeddableInProxyString(String user, String pass) {
    bool clean(String s) =>
        s.isNotEmpty &&
        s.trim() == s &&
        !s.contains(';') &&
        !s.contains(RegExp(r'[\x00-\x1f\x7f]'));
    return clean(user) && clean(pass) && isValidUsername(user);
  }

  static bool _isLoopback(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '[::1]') return true;
    return InternetAddress.tryParse(h)?.isLoopback ?? false;
  }
}

/// 让进程内所有 [HttpClient]（package:http、WebSocket）都按 [NetworkProxy] 选路。
class ProxyHttpOverrides extends HttpOverrides {
  final NetworkProxy proxy;

  ProxyHttpOverrides(this.proxy);

  /// 自建隧道（CONNECT 加 TLS 握手）在客户端没设 connectionTimeout 时的上限。
  static const Duration tunnelTimeout = Duration(seconds: 30);

  /// 在创建任何网络客户端之前调用。
  static void install(NetworkProxy proxy) =>
      HttpOverrides.global = ProxyHttpOverrides(proxy);

  /// 证书验证失败时的日志钩子（不改变校验结果，只为定位拦截来源）。
  /// 纯 Dart 文件不能引入 Flutter 的 debugPrint，由 main 注入。
  static void Function(String message)? certificateRejectionLogger;

  /// 记录被拒绝的对端证书；始终返回 false（证书依旧被拒绝）。
  static bool _logRejectedCertificate(
    X509Certificate certificate,
    String host,
    int port,
  ) {
    final log = certificateRejectionLogger;
    if (log != null) {
      final sha1 = certificate.sha1
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      log(
        '[TLS] 证书验证失败 $host:$port：subject="${certificate.subject}" '
        'issuer="${certificate.issuer}" sha1=$sha1',
      );
    }
    return false;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // 只记录、不改变结论：证书依旧被拒绝，日志能指出是哪个 CA 在拦截。
    // 自建 TLS 的连接（直连 / 自建隧道）由下面各自传入同一回调，不经这里。
    client.badCertificateCallback = _logRejectedCertificate;
    return GatewayHttpClient(
      client
        ..findProxy = proxy.findProxy
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            _connect(client, context, uri, proxyHost, proxyPort),
      () => proxy.gateway,
    );
  }

  /// 装了 connectionFactory 后 dart:io 不再自己建连，其余情况照它原来的方式建：
  /// - 经代理（dart:io 自己发 CONNECT / 明文代理请求）：只连到代理；
  /// - 直连：明文 TCP，HTTPS 在这里完成 TLS（与 dart:io 默认路径一样用客户端的 SecurityContext）；
  /// - [NetworkProxy.tunnelsSecure] / SOCKS / 自动配置（PAC）：先经 [ProxyTunnel] 自建隧道，再在隧道上做 TLS。
  Future<ConnectionTask<Socket>> _connect(
    HttpClient client,
    SecurityContext? context,
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    // findProxy 对 SOCKS / PAC 统一报 DIRECT，这里的异步解析才是实际选路
    if (proxy.usesSelfTunnel(uri)) {
      final endpoint = await proxy.endpointForAsync(uri);
      if (endpoint == null) return _directConnect(uri, context);
      return _tunnelConnect(endpoint, uri, context, client);
    }
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    if (proxy.tunnelsSecure(uri)) {
      return _tunnelConnect(proxy.endpointFor(uri), uri, context, client);
    }
    return _directConnect(uri, context);
  }

  Future<ConnectionTask<Socket>> _directConnect(
    Uri uri,
    SecurityContext? context,
  ) {
    final secure = uri.isScheme('https') || uri.isScheme('wss');
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
    if (!secure) return Socket.startConnect(host, port);
    return SecureSocket.startConnect(
      host,
      port,
      context: context,
      onBadCertificate: (cert) => _logRejectedCertificate(cert, host, port),
    );
  }

  Future<ConnectionTask<Socket>> _tunnelConnect(
    ProxyEndpoint? endpoint,
    Uri uri,
    SecurityContext? context,
    HttpClient client,
  ) async {
    final secure = uri.isScheme('https') || uri.isScheme('wss');
    if (!secure) {
      // 自建隧道只能透明转发；明文 HTTP 需要绝对地址形式，dart:io 做不到经 SOCKS/PAC 的代理
      throw const SocketException('暂不支持通过 SOCKS / PAC 代理的明文 HTTP 连接');
    }
    final host = uri.host;
    final port = uri.hasPort ? uri.port : 443;
    Socket? tunnelSocket;
    var cancelled = false;
    final socket = () async {
      final tunnel = await ProxyTunnel.connect(
        host,
        port,
        timeout: client.connectionTimeout ?? tunnelTimeout,
        proxy: proxy,
        endpoint: endpoint,
        useGateway: false,
      );
      final tcpSocket = tunnel.socket.tcpSocket;
      if (tcpSocket == null) {
        tunnel.socket.destroy();
        throw const ProxyTunnelException('Expected a TCP proxy tunnel');
      }
      tunnelSocket = tcpSocket;
      if (cancelled) {
        tunnel.socket.destroy();
        throw const SocketException('连接已取消');
      }
      // 隧道建立后目标服务器在 ClientHello 之前不会发数据，ProxyTunnel 没有缓冲任何属于 TLS 的字节
      return SecureSocket.secure(
        tcpSocket,
        host: host,
        context: context,
        onBadCertificate: (cert) => _logRejectedCertificate(cert, host, port),
      );
    }();
    return ConnectionTask.fromSocket(socket, () {
      cancelled = true;
      tunnelSocket?.destroy();
    });
  }
}
