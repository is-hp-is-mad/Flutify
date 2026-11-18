import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/services/network/gateway_http_client.dart';
import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/services/network/proxy_tunnel.dart';
import 'package:flutify_app/models/spotify_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

const gateway = SpotifyGateway(
  enabled: true,
  baseUrl: 'https://gateway.example/assets-test',
  username: 'test-user',
  password: 'test-pass',
);

// Use real sockets, HTTP redirects and WebSocket upgrade handling on loopback.
class LocalTransport implements HttpClient {
  final HttpClient inner = HttpClient();
  final int port;
  final targets = <Uri>[];
  LocalTransport(this.port);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    targets.add(url);
    return inner.openUrl(
      method,
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  set findProxy(String Function(Uri)? value) => inner.findProxy = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'routes API, signed media and provisioning but leaves browser pages direct',
    () {
      for (final url in [
        'https://api.spotify.com/v1/me',
        'https://open.spotify.com/api/token',
        'https://open.spotify.com/api/server-time',
        'https://accounts.spotify.com/api/token',
        'https://gew1-spclient.spotify.com/widevine-license/v1/audio/license',
        'https://www.googleapis.com/certificateprovisioning/v1/devicecertificates/create?key=x',
        'https://provisioning.googleapis.com/v1/devicecertificates/create',
      ]) {
        expect(
          gateway.route(Uri.parse(url)).host,
          'gateway.example',
          reason: url,
        );
      }
      for (final url in [
        'https://accounts.spotify.com/authorize',
        'https://open.spotify.com/',
        'https://open.spotify.com/show/123',
        'https://www.googleapis.com/drive/v3/files',
        'https://api.spotify.com.evil.example/v1/me',
        'https://api.spotify.com:444/v1/me',
        'https://u:p@api.spotify.com/v1/me',
        'http://127.0.0.1:123/audio.m3u8',
      ]) {
        final uri = Uri.parse(url);
        expect(gateway.route(uri), uri, reason: url);
      }
      expect(
        gateway
            .route(
              Uri.parse(
                'http://audio-fa.scdn.co/a%2Fb?sig=a%2Fb%2B%3D&x=1&x=2',
              ),
            )
            .toString(),
        'https://gateway.example/assets-test/audio-fa.scdn.co/a%2Fb?sig=a%2Fb%2B%3D&x=1&x=2',
      );
      expect(
        gateway.tunnel('ap-gew4.spotify.com', 4070).toString(),
        'wss://gateway.example/assets-test/__tunnel/ap-gew4.spotify.com:4070',
      );
      expect(() => gateway.tunnel('example.org', 443), throwsFormatException);
    },
  );

  late HttpServer server;
  late LocalTransport transport;
  late GatewayHttpClient client;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    transport = LocalTransport(server.port);
    client = GatewayHttpClient(transport, () => gateway);
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  test('streams POST bytes and forwards Range/206 through gateway', () async {
    server.listen((request) async {
      expect(request.headers.value('x-proxy-user'), 'test-user');
      expect(request.headers.value('x-proxy-pass'), 'test-pass');
      expect(request.headers.value('authorization'), 'Bearer token');
      expect(request.headers.value('range'), 'bytes=0-3');
      expect(await request.fold<List<int>>([], (a, b) => a..addAll(b)), [
        0,
        1,
        255,
      ]);
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-3/100');
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final request = await client.postUrl(
      Uri.parse('https://audio-fa.scdn.co/track'),
    );
    request.headers.set('authorization', 'Bearer token');
    request.headers.set('range', 'bytes=0-3');
    request.add([0, 1, 255]);
    final response = await request.close();
    expect(response.statusCode, 206);
    expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
      1,
      2,
      3,
      4,
    ]);
  });

  test(
    'relative redirects stay routed; cross-origin redirects drop credentials',
    () async {
      final seen = <Map<String, String?>>[];
      server.listen((request) async {
        seen.add({
          for (final key in [
            'authorization',
            'cookie',
            'x-proxy-user',
            'x-proxy-pass',
          ])
            key: request.headers.value(key),
        });
        if (seen.length < 3) {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            seen.length == 1 ? 'next?x=1' : 'https://unrelated.example/final',
          );
        } else {
          request.response.write('ok');
        }
        await request.response.close();
      });
      final request = await client.getUrl(
        Uri.parse('https://api.spotify.com/v1/start'),
      );
      request.headers.set('authorization', 'Bearer token');
      request.cookies.add(Cookie('session', 'value'));
      expect(await utf8.decoder.bind(await request.close()).join(), 'ok');
      expect(
        transport.targets[1].toString(),
        'https://gateway.example/assets-test/api.spotify.com/v1/next?x=1',
      );
      expect(seen[1]['authorization'], 'Bearer token');
      expect(seen[1]['cookie'], contains('session=value'));
      expect(seen[2].values, everyElement(isNull));
    },
  );

  test('redirect loops are bounded and HTTPS downgrade is rejected', () async {
    server.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set(
        'location',
        request.uri.path.endsWith('downgrade')
            ? 'http://api.spotify.com/insecure'
            : '/loop',
      );
      await request.response.close();
    });
    final loop = await client.getUrl(Uri.parse('https://api.spotify.com/loop'));
    loop.maxRedirects = 2;
    await expectLater(loop.close(), throwsA(isA<RedirectException>()));
    final downgrade = await client.getUrl(
      Uri.parse('https://api.spotify.com/downgrade'),
    );
    await expectLater(downgrade.close(), throwsA(isA<HttpException>()));
  });

  test('dealer WebSocket upgrades through shared gateway client', () async {
    String? receivedPath;
    String? receivedUser;
    server.listen((request) async {
      receivedPath = request.uri.path;
      receivedUser = request.headers.value('x-proxy-user');
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) => socket.add(data));
    });
    final socket = await WebSocket.connect(
      'wss://gew1-dealer.spotify.com/?access_token=test',
      customClient: client,
    );
    socket.add('ping');
    expect(await socket.first, 'ping');
    await socket.close();
    expect(
      receivedPath,
      '/assets-test/gew1-dealer.spotify.com/',
      reason: transport.targets.toString(),
    );
    expect(receivedUser, 'test-user');
  });

  test(
    'access point tunnel carries binary bytes and authenticates once',
    () async {
      String? receivedPath;
      String? receivedUser;
      server.listen((request) async {
        receivedPath = request.uri.path;
        receivedUser = request.headers.value('x-proxy-user');
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((data) => socket.add(data));
      });
      final proxy = NetworkProxy()..gateway = gateway;
      final conn = await HttpOverrides.runZoned(
        () => ProxyTunnel.connect(
          'ap-gew4.spotify.com',
          4070,
          timeout: const Duration(seconds: 3),
          proxy: proxy,
        ),
        createHttpClient: (_) => client,
      );
      addTearDown(conn.socket.destroy);
      conn.socket.add([0, 128, 255, 13, 10]);
      expect(await conn.input.first.timeout(const Duration(seconds: 3)), [
        0,
        128,
        255,
        13,
        10,
      ]);
      expect(receivedPath, '/assets-test/__tunnel/ap-gew4.spotify.com:4070');
      expect(receivedUser, 'test-user');
    },
  );
}
