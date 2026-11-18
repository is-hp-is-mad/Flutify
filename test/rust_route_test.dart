import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/models/proxy_mode.dart';
import 'package:flutify_app/services/network/rust_route.dart';
import 'package:flutify_app/models/spotify_gateway.dart';
import 'package:flutify_app/services/network/system_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late NetworkProxy proxy;
  const gateway = SpotifyGateway(
    enabled: true,
    baseUrl: 'https://gateway.example/prefix',
    username: 'user',
    password: 'pass',
  );

  setUp(() {
    proxy = NetworkProxy(systemReader: () async => SystemProxySettings.none);
  });

  test('未开网关：原地址直连，无额外请求头', () async {
    final route = await rustRouteFor(
      Uri.parse('wss://dealer.spotify.com/?access_token=t'),
      proxy: proxy,
    );
    expect(route!.proxy, '');
    expect(route.url.toString(), 'wss://dealer.spotify.com/?access_token=t');
    expect(route.headers, isEmpty);
    expect(route.viaGateway, isFalse);
  });

  test('开网关：dealer WebSocket 改写为网关 wss 地址并带网关头', () async {
    proxy.gateway = gateway;
    final route = await rustRouteFor(
      Uri.parse('wss://dealer.spotify.com/?access_token=t'),
      proxy: proxy,
    );
    expect(
      route!.url.toString(),
      'wss://gateway.example/prefix/dealer.spotify.com/?access_token=t',
    );
    expect(route.headers, {'X-Proxy-User': 'user', 'X-Proxy-Pass': 'pass'});
  });

  test('开网关：签名 CDN 地址逐字保留', () async {
    proxy.gateway = gateway;
    const cdn =
        'https://audio-ak.spotifycdn.com/audio/abc?__token__=exp=1~hmac=a%2Fb';
    final route = await rustRouteFor(Uri.parse(cdn), proxy: proxy);
    expect(
      route!.url.toString(),
      'https://gateway.example/prefix/audio-ak.spotifycdn.com/audio/abc?__token__=exp=1~hmac=a%2Fb',
    );
  });

  test('开网关：网关范围外的地址不改写、不带凭据', () async {
    proxy.gateway = gateway;
    final route = await rustRouteFor(
      Uri.parse('https://example.com/a'),
      proxy: proxy,
    );
    expect(route!.url.toString(), 'https://example.com/a');
    expect(route.headers, isEmpty);
  });

  test('网关配置无效：返回 null（交给 Dart）', () async {
    proxy.gateway = const SpotifyGateway(
      enabled: true,
      baseUrl: 'https://gateway.example/prefix',
    );
    expect(
      await rustRouteFor(Uri.parse('https://spclient.wg.spotify.com/'), proxy: proxy),
      isNull,
    );
  });

  test('开网关 + 手动代理：代理按网关主机选取', () async {
    await proxy.configure(
      mode: ProxyMode.manual,
      proxyHost: '127.0.0.1',
      proxyPort: 7890,
      gateway: gateway,
    );
    final route = await rustRouteFor(
      Uri.parse('https://spclient.wg.spotify.com/'),
      proxy: proxy,
    );
    expect(route!.proxy, 'http://127.0.0.1:7890');
  });

  test('mergeHeaders：路线头覆盖同名头（不区分大小写）', () {
    final route = RustRoute(
      proxy: '',
      url: Uri.parse('https://gateway.example/'),
      headers: const {'X-Proxy-User': 'user'},
    );
    expect(route.mergeHeaders({'x-proxy-user': 'spoofed', 'A': '1'}), {
      'A': '1',
      'X-Proxy-User': 'user',
    });
  });
}
