import 'dart:convert';
import 'dart:typed_data';

import 'package:flutify_app/services/network/http2_client.dart';
import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/services/network/proxy_endpoint.dart';
import 'package:flutify_app/models/proxy_mode.dart';
import 'package:flutify_app/models/spotify_gateway.dart';
import 'package:flutify_app/services/network/system_proxy.dart';
import 'package:flutify_app/src/rust/api/protocol.dart' as rust;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Spotify API 直连请求走 Rust HTTP/2；网关 / 代理 / 非 API 主机走 Dart；建连失败安全回退。
void main() {
  late NetworkProxy proxy;
  late List<String> viaDart;
  late List<String> viaRust;
  late List<String> proxies;

  setUp(() {
    Http2Client.resetFailures();
    proxy = NetworkProxy(systemReader: () async => SystemProxySettings.none);
    viaDart = [];
    viaRust = [];
    proxies = [];
  });

  http.Client dart() => MockClient((request) async {
    viaDart.add('${request.method} ${request.url.host} ${request.body}');
    return http.Response('dart', 200);
  });

  Http2Client client({
    Future<rust.HttpResponseData> Function(
      String proxy,
      String method,
      String url,
      List<rust.HttpHeaderEntry> headers,
      Uint8List body,
    )?
    rustSend,
  }) => Http2Client(
    dart(),
    proxy: proxy,
    enabledOverride: true,
    sendOverride:
        rustSend ??
        (proxy, method, url, headers, body) async {
          viaRust.add('$method ${Uri.parse(url).host} ${utf8.decode(body)}');
          proxies.add(proxy);
          return rust.HttpResponseData(
            status: 200,
            headers: [
              const rust.HttpHeaderEntry(name: 'Content-Type', value: 'application/json'),
              const rust.HttpHeaderEntry(name: 'set-cookie', value: 'a=1'),
              const rust.HttpHeaderEntry(name: 'set-cookie', value: 'b=2'),
            ],
            body: utf8.encode('{"ok":true}'),
            version: 'HTTP/2.0',
          );
        },
  );

  test('直连的 Spotify API 走 Rust（代理参数为空），响应头 / 体原样交回', () async {
    final response = await client().post(
      Uri.parse('https://spclient.wg.spotify.com/collection/v2/write'),
      body: 'payload',
    );
    expect(viaRust, ['POST spclient.wg.spotify.com payload']);
    expect(proxies, ['']);
    expect(viaDart, isEmpty);
    expect(response.statusCode, 200);
    expect(response.body, '{"ok":true}');
    expect(response.headers['content-type'], 'application/json');
    expect(response.headers['set-cookie'], 'a=1,b=2');
  });

  test('接入点主机（xxx-spclient）也走 Rust；登录、CDN、第三方走 Dart', () async {
    final c = client();
    await c.get(Uri.parse('https://gae2-spclient.spotify.com/x'));
    await c.get(Uri.parse('https://accounts.spotify.com/api/token'));
    await c.get(Uri.parse('https://open.spotify.com/get_access_token'));
    await c.get(Uri.parse('https://audio-fa.scdn.co/audio/abc'));
    await c.get(Uri.parse('https://lrclib.net/api/get'));
    await c.get(Uri.parse('http://spclient.wg.spotify.com/plain'));
    expect(viaRust, ['GET gae2-spclient.spotify.com ']);
    expect(viaDart.map((e) => e.split(' ')[1]), [
      'accounts.spotify.com',
      'open.spotify.com',
      'audio-fa.scdn.co',
      'lrclib.net',
      'spclient.wg.spotify.com',
    ]);
  });

  test('开了手动代理：仍走 Rust，带上代理地址（含百分号编码的用户名密码）', () async {
    await proxy.configure(
      mode: ProxyMode.manual,
      proxyHost: '127.0.0.1',
      proxyPort: 8888,
      proxyUsername: 'u@x',
      proxyPassword: 'p:w',
    );
    await client().get(Uri.parse('https://spclient.wg.spotify.com/x'));
    expect(viaDart, isEmpty);
    expect(proxies, ['http://u%40x:p%3Aw@127.0.0.1:8888']);
  });

  test('系统代理（如 Clash 127.0.0.1:7890）：走 Rust 并带上代理；绕过列表里的主机直连', () async {
    proxy = NetworkProxy(
      systemReader: () async => const SystemProxySettings(
        https: ProxyEndpoint('127.0.0.1', 7890),
        bypass: ['api.spotify.com'],
      ),
    );
    await proxy.configure(mode: ProxyMode.system);
    await proxy.refreshSystem();
    final c = client();
    await c.get(Uri.parse('https://spclient.wg.spotify.com/x'));
    await c.get(Uri.parse('https://api.spotify.com/v1/me'));
    expect(viaDart, isEmpty);
    expect(proxies, ['http://127.0.0.1:7890', '']);
  });

  test('系统 SOCKS5 代理：socks5h 地址（域名交给代理解析）', () async {
    proxy = NetworkProxy(
      systemReader: () async => const SystemProxySettings(
        socks: ProxyEndpoint('10.0.0.2', 1080, type: ProxyType.socks5),
      ),
    );
    await proxy.configure(mode: ProxyMode.system);
    await proxy.refreshSystem();
    await client().get(Uri.parse('https://spclient.wg.spotify.com/x'));
    expect(proxies, ['socks5h://10.0.0.2:1080']);
  });

  test('网关配置无效（缺账号密码）：交给 Dart，由它报出配置错误', () async {
    proxy.gateway = const SpotifyGateway(
      enabled: true,
      baseUrl: 'https://gateway.example/prefix',
    );
    await client().get(Uri.parse('https://spclient.wg.spotify.com/x'));
    expect(viaRust, isEmpty);
    expect(viaDart, hasLength(1));
  });

  group('启用了有效网关', () {
    const gateway = SpotifyGateway(
      enabled: true,
      baseUrl: 'https://gateway.example/prefix',
      username: 'user',
      password: 'pass',
    );
    late List<String> urls;
    late List<Map<String, String>> sentHeaders;

    Http2Client gatewayClient({int status = 200}) => client(
      rustSend: (p, method, url, headers, body) async {
        urls.add(url);
        proxies.add(p);
        sentHeaders.add({for (final h in headers) h.name: h.value});
        return rust.HttpResponseData(
          status: status,
          headers: [
            if (status >= 300)
              const rust.HttpHeaderEntry(name: 'Location', value: '/y'),
          ],
          body: utf8.encode('rust'),
          version: 'HTTP/2.0',
        );
      },
    );

    setUp(() {
      urls = [];
      sentHeaders = [];
      proxy.gateway = gateway;
    });

    test('经 Rust 发往改写后的网关地址，带网关头，原请求头保留', () async {
      final r = await gatewayClient().get(
        Uri.parse('https://spclient.wg.spotify.com/x/y?a=1%2B2'),
        headers: {'Authorization': 'Bearer t', 'X-Proxy-User': 'spoofed'},
      );
      expect(r.body, 'rust');
      expect(viaDart, isEmpty);
      expect(urls, [
        'https://gateway.example/prefix/spclient.wg.spotify.com/x/y?a=1%2B2',
      ]);
      expect(sentHeaders.single['Authorization'], 'Bearer t');
      // 网关头以配置为准，调用方传入的同名头不能覆盖
      expect(sentHeaders.single['X-Proxy-User'], 'user');
      expect(sentHeaders.single['X-Proxy-Pass'], 'pass');
      expect(
        sentHeaders.single.keys.where((k) => k.toLowerCase() == 'x-proxy-user'),
        hasLength(1),
      );
    });

    test('代理按网关主机选取', () async {
      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '127.0.0.1',
        proxyPort: 7890,
        gateway: gateway,
      );
      await gatewayClient().get(Uri.parse('https://spclient.wg.spotify.com/x'));
      expect(proxies, ['http://127.0.0.1:7890']);
    });

    test('重定向交回 Dart（相对原地址解析并重新经网关，凭据不跟到别处）', () async {
      final r = await gatewayClient(status: 302).get(
        Uri.parse('https://spclient.wg.spotify.com/x'),
      );
      expect(urls, hasLength(1));
      expect(viaDart, ['GET spclient.wg.spotify.com ']);
      expect(r.body, 'dart');
    });  });

  test('建连失败（请求未发出）：改走 Dart 重发，请求体不丢；连续失败后该主机不再尝试', () async {
    var attempts = 0;
    final c = client(
      rustSend: (_, _, _, _, _) async {
        attempts++;
        throw 'connect:tls handshake failed';
      },
    );
    for (var i = 0; i < Http2Client.maxConnectFailures + 2; i++) {
      final r = await c.post(
        Uri.parse('https://spclient.wg.spotify.com/x'),
        body: 'p$i',
      );
      expect(r.body, 'dart');
    }
    expect(attempts, Http2Client.maxConnectFailures);
    expect(viaDart.first, 'POST spclient.wg.spotify.com p0');
    expect(viaDart, hasLength(Http2Client.maxConnectFailures + 2));
  });

  test('请求已发出后失败（超时）：不自动重发，避免重复写入', () async {
    final c = client(rustSend: (_, _, _, _, _) async => throw 'timeout:operation timed out');
    await expectLater(
      c.post(Uri.parse('https://spclient.wg.spotify.com/x'), body: 'once'),
      throwsA(isA<http.ClientException>()),
    );
    expect(viaDart, isEmpty);
  });

  test('3xx 且调用方要求跟随重定向：交给 Dart 照原样处理', () async {
    final c = client(
      rustSend: (_, _, _, _, _) async => rust.HttpResponseData(
        status: 302,
        headers: const [rust.HttpHeaderEntry(name: 'location', value: '/y')],
        body: Uint8List(0),
        version: 'HTTP/2.0',
      ),
    );
    final r = await c.get(Uri.parse('https://api.spotify.com/v1/x'));
    expect(r.body, 'dart');
  });

  test('未加载 Rust 核心（单元测试 / 加载失败）：全部原样交给 Dart', () async {
    final c = Http2Client(dart(), proxy: proxy);
    await c.get(Uri.parse('https://spclient.wg.spotify.com/x'));
    expect(viaDart, hasLength(1));
  });
}
