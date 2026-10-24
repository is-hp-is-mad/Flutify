import 'dart:convert';
import 'dart:typed_data';

import 'package:flutify_app/services/network/http2_client.dart';
import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/services/network/proxy_mode.dart';
import 'package:flutify_app/services/network/spotify_gateway.dart';
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

  setUp(() {
    Http2Client.resetFailures();
    proxy = NetworkProxy(systemReader: () async => SystemProxySettings.none);
    viaDart = [];
    viaRust = [];
  });

  http.Client dart() => MockClient((request) async {
    viaDart.add('${request.method} ${request.url.host} ${request.body}');
    return http.Response('dart', 200);
  });

  Http2Client client({
    Future<rust.HttpResponseData> Function(
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
        (method, url, headers, body) async {
          viaRust.add('$method ${Uri.parse(url).host} ${utf8.decode(body)}');
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

  test('直连的 Spotify API 走 Rust，响应头 / 体原样交回', () async {
    final response = await client().post(
      Uri.parse('https://spclient.wg.spotify.com/collection/v2/write'),
      body: 'payload',
    );
    expect(viaRust, ['POST spclient.wg.spotify.com payload']);
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

  test('开了手动代理：交给 Dart 网络层（代理 / 认证 / 隧道都在那边）', () async {
    await proxy.configure(
      mode: ProxyMode.manual,
      proxyHost: '127.0.0.1',
      proxyPort: 8888,
    );
    await client().get(Uri.parse('https://spclient.wg.spotify.com/x'));
    expect(viaRust, isEmpty);
    expect(viaDart, hasLength(1));
  });

  test('启用了网关：交给 Dart（网关会改写地址并加网关头）', () async {
    proxy.gateway = const SpotifyGateway(
      enabled: true,
      baseUrl: 'https://gateway.example/prefix',
    );
    await client().get(Uri.parse('https://spclient.wg.spotify.com/x'));
    expect(viaRust, isEmpty);
    expect(viaDart, hasLength(1));
  });

  test('建连失败（请求未发出）：改走 Dart 重发，请求体不丢；连续失败后该主机不再尝试', () async {
    var attempts = 0;
    final c = client(
      rustSend: (_, _, _, _) async {
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
    final c = client(rustSend: (_, _, _, _) async => throw 'timeout:operation timed out');
    await expectLater(
      c.post(Uri.parse('https://spclient.wg.spotify.com/x'), body: 'once'),
      throwsA(isA<http.ClientException>()),
    );
    expect(viaDart, isEmpty);
  });

  test('3xx 且调用方要求跟随重定向：交给 Dart 照原样处理', () async {
    final c = client(
      rustSend: (_, _, _, _) async => rust.HttpResponseData(
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
