import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/services/network/proxy_endpoint.dart';
import 'package:flutify_app/services/network/proxy_tunnel.dart';
import 'package:flutify_app/services/network/spotify_gateway.dart';
import 'package:flutify_app/services/network/system_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 网络代理：系统代理解析、绕过规则、按模式选路、CONNECT 隧道。
void main() {
  group('ProxyEndpoint.tryParse', () {
    test('accepts host:port, scheme prefix and IPv6', () {
      expect(
        ProxyEndpoint.tryParse('127.0.0.1:7890'),
        const ProxyEndpoint('127.0.0.1', 7890),
      );
      expect(
        ProxyEndpoint.tryParse(' http://proxy.lan:8080/ '),
        const ProxyEndpoint('proxy.lan', 8080),
      );
      expect(ProxyEndpoint.tryParse('[::1]:7890')?.toString(), '[::1]:7890');
      expect(
        ProxyEndpoint.tryParse('http://proxy:80'),
        const ProxyEndpoint('proxy', 80),
      );
      expect(
        ProxyEndpoint.tryParse('socks5://127.0.0.1:1080')?.type,
        ProxyType.socks5,
      );
      expect(
        ProxyEndpoint.tryParse('socks://127.0.0.1:1080')?.type,
        ProxyType.socks5,
      );
    });

    test('rejects missing or invalid port', () {
      expect(ProxyEndpoint.tryParse(''), isNull);
      expect(ProxyEndpoint.tryParse('127.0.0.1'), isNull);
      expect(ProxyEndpoint.tryParse('127.0.0.1:99999'), isNull);
    });
  });

  group('SystemProxySettings', () {
    test('parses reg query output with a single server', () {
      const output =
          '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\r\n'
          '    ProxyEnable    REG_DWORD    0x1\r\n'
          '    ProxyServer    REG_SZ    127.0.0.1:7890\r\n'
          '    ProxyOverride    REG_SZ    localhost;127.*;*.corp.example;<local>\r\n';
      final s = SystemProxyReader.parseRegQuery(output);
      expect(s.http, const ProxyEndpoint('127.0.0.1', 7890));
      expect(s.https, const ProxyEndpoint('127.0.0.1', 7890));
      expect(s.bypasses('git.corp.example'), isTrue);
      expect(s.bypasses('intranet'), isTrue, reason: '<local> = 不带点的主机名');
      expect(s.bypasses('api.spotify.com'), isFalse);
    });

    test('disabled proxy is treated as none', () {
      const output =
          '    ProxyEnable    REG_DWORD    0x0\r\n    ProxyServer    REG_SZ    127.0.0.1:7890\r\n';
      expect(SystemProxyReader.parseRegQuery(output).isEmpty, isTrue);
    });

    test('per-protocol server list parses http / https / socks', () {
      final s = SystemProxySettings.fromWindows(
        enabled: true,
        server: 'http=10.0.0.1:80;https=10.0.0.1:443;socks=10.0.0.1:1080',
      );
      expect(s.http, const ProxyEndpoint('10.0.0.1', 80));
      expect(s.https, const ProxyEndpoint('10.0.0.1', 443));
      expect(
        s.socks,
        const ProxyEndpoint('10.0.0.1', 1080, type: ProxyType.socks5),
      );
      expect(s.isEmpty, isFalse);
    });

    test('socks-only config is routed through the SOCKS proxy', () {
      final s = SystemProxySettings.fromWindows(
        enabled: true,
        server: 'socks=127.0.0.1:1080',
      );
      expect(s.http, isNull);
      expect(s.https, isNull);
      expect(s.socks, const ProxyEndpoint('127.0.0.1', 1080, type: ProxyType.socks5));
      expect(s.primary, s.socks);
      expect(s.isEmpty, isFalse);
    });

    test('environment variables with leading-dot no_proxy', () {
      final s = SystemProxySettings.fromEnvironment({
        'HTTPS_PROXY': 'http://p:3128',
        'no_proxy': '.internal,example.org',
      });
      expect(s.https, const ProxyEndpoint('p', 3128));
      expect(s.http, isNull);
      expect(s.bypasses('a.internal'), isTrue);
      expect(s.bypasses('internal'), isTrue);
      expect(s.bypasses('example.org'), isTrue);
      expect(s.bypasses('spotify.com'), isFalse);
    });
  });

  group('NetworkProxy', () {
    final spotify = Uri.parse('https://api.spotify.com/v1/me');
    final system = SystemProxySettings.fromWindows(
      enabled: true,
      server: '127.0.0.1:7890',
    );

    test(
      'modes route requests accordingly; loopback is always direct',
      () async {
        final proxy = NetworkProxy(systemReader: () async => system);
        await proxy.configure(mode: ProxyMode.system);
        expect(proxy.findProxy(spotify), 'PROXY 127.0.0.1:7890');
        expect(
          proxy.findProxy(Uri.parse('http://127.0.0.1:51234/stream')),
          'DIRECT',
        );
        expect(
          proxy.findProxy(Uri.parse('http://localhost:51234/stream')),
          'DIRECT',
        );

        await proxy.configure(mode: ProxyMode.none);
        expect(proxy.findProxy(spotify), 'DIRECT');

        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '10.1.1.1',
          proxyPort: 8888,
        );
        expect(proxy.findProxy(spotify), 'PROXY 10.1.1.1:8888');
      },
    );

    test('manual mode without a valid address connects directly', () async {
      final proxy = NetworkProxy(systemReader: () async => system);
      await proxy.configure(mode: ProxyMode.manual);
      expect(proxy.findProxy(spotify), 'DIRECT');
    });

    test('concurrent system refreshes share a single read', () async {
      var reads = 0;
      final gate = Completer<void>();
      final proxy = NetworkProxy(
        systemReader: () async {
          reads++;
          await gate.future;
          return system;
        },
      );
      final a = proxy.refreshSystem();
      final b = proxy.refreshSystem();
      gate.complete();
      await Future.wait([a, b]);
      expect(reads, 1);
    });

    test(
      'authenticated HTTPS is tunnelled by us; plain HTTP embeds the credentials',
      () async {
        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '10.1.1.1',
          proxyPort: 8888,
          proxyUsername: 'user',
          proxyPassword: 'pa:ss',
        );
        expect(proxy.manualHasCredentials, isTrue);
        // HTTPS / WSS：dart:io 只看到直连，凭据只在自建隧道的 CONNECT 上（见 ProxyHttpOverrides）
        expect(proxy.tunnelsSecure(spotify), isTrue);
        expect(proxy.findProxy(spotify), 'DIRECT');
        expect(
          proxy.findProxy(Uri.parse('wss://dealer.spotify.com/')),
          'DIRECT',
        );
        // 明文 HTTP 的请求本来就发给代理：凭据嵌进代理串
        final plain = Uri.parse('http://example.com/');
        expect(proxy.tunnelsSecure(plain), isFalse);
        expect(proxy.findProxy(plain), 'PROXY user:pa:ss@10.1.1.1:8888');

        // 只有手动模式的代理才携带凭据
        await proxy.configure(mode: ProxyMode.none);
        expect(proxy.tunnelsSecure(spotify), isFalse);
        expect(proxy.findProxy(spotify), 'DIRECT');
      },
    );

    test(
      'plain HTTP only embeds credentials that dart:io parses back intact',
      () async {
        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        final plain = Uri.parse('http://example.com/');
        Future<void> credentials(String user, String pass) => proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '10.1.1.1',
          proxyPort: 8888,
          proxyUsername: user,
          proxyPassword: pass,
        );

        // dart:io 拒绝空半边的 PROXY user:@host 格式；HTTPS 隧道仍能携带单边凭据，
        // 明文 HTTP 则退化为无凭据，设置界面会明确提示需要补全
        await credentials('user', '');
        expect(proxy.manualHasCredentials, isTrue);
        expect(proxy.findProxy(spotify), 'DIRECT');
        expect(proxy.findProxy(plain), 'PROXY 10.1.1.1:8888');

        // ';' 会把代理串拆断、首尾空白会被 trim 掉：不嵌入，代理回 407 暴露问题
        await credentials('user', 'pa;ss');
        expect(proxy.findProxy(plain), 'PROXY 10.1.1.1:8888');
        await credentials('user', ' pass');
        expect(proxy.findProxy(plain), 'PROXY 10.1.1.1:8888');

        // 中间的空格与 @ 都能被 dart:io 正确拆出来（按最后一个 @ 分隔代理地址）
        await credentials('user', 'pa ss@1');
        expect(proxy.findProxy(plain), 'PROXY user:pa ss@1@10.1.1.1:8888');

        expect(NetworkProxy.isValidUsername('user'), isTrue);
        expect(NetworkProxy.isValidUsername('us:er'), isFalse);
      },
    );

    test('music.163.com always connects directly, in every mode', () async {
      final proxy = NetworkProxy(systemReader: () async => system);
      final netease = [
        Uri.parse('https://music.163.com/api/song/lyric?id=1'),
        Uri.parse('https://interface.music.163.com/api/search/get'),
        Uri.parse('http://music.163.com/'),
      ];
      // 不经代理、也不走自建隧道（ProxyTunnel 与 connectionFactory 都按 endpointFor / tunnelsSecure 选路）
      void expectDirect(String mode) {
        for (final uri in netease) {
          expect(proxy.endpointFor(uri), isNull, reason: '$mode $uri');
          expect(proxy.findProxy(uri), 'DIRECT', reason: '$mode $uri');
          expect(proxy.tunnelsSecure(uri), isFalse, reason: '$mode $uri');
        }
      }

      // 手动代理 + 凭据：Spotify 照常经自建隧道 / 嵌入凭据
      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '10.1.1.1',
        proxyPort: 8888,
        proxyUsername: 'user',
        proxyPassword: 'pass',
      );
      expectDirect('manual + credentials');
      expect(proxy.tunnelsSecure(spotify), isTrue);
      expect(
        proxy.findProxy(Uri.parse('http://api.spotify.com/')),
        'PROXY user:pass@10.1.1.1:8888',
      );

      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '10.1.1.1',
        proxyPort: 8888,
      );
      expectDirect('manual');
      expect(proxy.findProxy(spotify), 'PROXY 10.1.1.1:8888');

      // 系统代理的例外列表里没有网易云，也照样直连
      await proxy.configure(mode: ProxyMode.system);
      expectDirect('system');
      expect(proxy.findProxy(spotify), 'PROXY 127.0.0.1:7890');

      await proxy.configure(mode: ProxyMode.none);
      expectDirect('none');
    });

    test('system SOCKS proxy is routed through our own tunnel', () async {
      final socks = SystemProxySettings.fromWindows(
        enabled: true,
        server: 'socks=127.0.0.1:1080',
      );
      final proxy = NetworkProxy(systemReader: () async => socks);
      await proxy.configure(mode: ProxyMode.system);
      expect(proxy.endpointFor(spotify)?.type, ProxyType.socks5);
      expect(proxy.findProxy(spotify), 'DIRECT');
      expect(proxy.usesSelfTunnel(spotify), isTrue);
    });

    test('PAC resolves per URL through the injected resolver and caches', () async {
      var calls = 0;
      final proxy = NetworkProxy(
        systemReader: () async => const SystemProxySettings(autoProxy: true),
        autoProxyResolver: (url) async {
          calls++;
          return url.contains('spotify') ? '127.0.0.1:7890' : '';
        },
      );
      await proxy.configure(mode: ProxyMode.system);
      // 自动配置无法同步求值：findProxy 一律 DIRECT，实际选路在 endpointForAsync
      expect(proxy.findProxy(spotify), 'DIRECT');
      expect(proxy.usesSelfTunnel(spotify), isTrue);
      expect(
        await proxy.endpointForAsync(spotify),
        const ProxyEndpoint('127.0.0.1', 7890),
      );
      expect(
        await proxy.endpointForAsync(spotify),
        const ProxyEndpoint('127.0.0.1', 7890),
      );
      expect(calls, 1, reason: '同一主机的解析结果应缓存');
      expect(
        await proxy.endpointForAsync(Uri.parse('https://example.com/x')),
        isNull,
        reason: 'PAC 返回直连',
      );
    });

    test('PAC failures fall back to the static proxy', () async {
      final proxy = NetworkProxy(
        systemReader: () async => const SystemProxySettings(
          http: ProxyEndpoint('10.1.1.1', 8888),
          https: ProxyEndpoint('10.1.1.1', 8888),
          autoProxy: true,
        ),
        autoProxyResolver: (_) async => throw StateError('PAC unreachable'),
      );
      await proxy.configure(mode: ProxyMode.system);
      expect(
        await proxy.endpointForAsync(spotify),
        const ProxyEndpoint('10.1.1.1', 8888),
      );
    });

    test('WinHTTP / PAC proxy strings are parsed', () {
      expect(
        NetworkProxy.parseAutoProxyResult('127.0.0.1:7890'),
        const ProxyEndpoint('127.0.0.1', 7890),
      );
      expect(
        NetworkProxy.parseAutoProxyResult('PROXY 10.0.0.1:8080'),
        const ProxyEndpoint('10.0.0.1', 8080),
      );
      expect(
        NetworkProxy.parseAutoProxyResult('a:1 b:2'),
        const ProxyEndpoint('a', 1),
      );
      expect(
        NetworkProxy.parseAutoProxyResult('SOCKS5 1.2.3.4:1080'),
        const ProxyEndpoint('1.2.3.4', 1080, type: ProxyType.socks5),
      );
      expect(NetworkProxy.parseAutoProxyResult('DIRECT'), isNull);
      expect(NetworkProxy.parseAutoProxyResult(''), isNull);
    });

    test('look-alikes of music.163.com are still proxied', () async {
      final proxy = NetworkProxy(systemReader: () async => system);
      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '10.1.1.1',
        proxyPort: 8888,
      );
      for (final host in [
        'music.163.com.evil.example',
        'notmusic.163.com',
        '163.com',
        'www.163.com',
        'music.163.co',
      ]) {
        expect(NetworkProxy.isAlwaysDirect(host), isFalse, reason: host);
        expect(
          proxy.findProxy(Uri.parse('https://$host/')),
          'PROXY 10.1.1.1:8888',
          reason: host,
        );
      }
      expect(NetworkProxy.isAlwaysDirect('music.163.com'), isTrue);
      expect(NetworkProxy.isAlwaysDirect('MUSIC.163.com'), isTrue);
      expect(NetworkProxy.isAlwaysDirect('interface3.music.163.com'), isTrue);
    });
  });

  group('ProxyTunnel', () {
    test(
      'CONNECT through an HTTP proxy, then relays bytes both ways',
      () async {
        // 假代理：回 200 并在同一个包里带上目标服务器的首批字节，之后原样回显
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <String>[];
        server.listen((client) {
          var connected = false;
          client.listen((data) {
            if (!connected) {
              connected = true;
              requests.add(latin1.decode(data));
              client.add(
                latin1.encode(
                  'HTTP/1.1 200 Connection established\r\n\r\nHELLO',
                ),
              );
            } else {
              client.add(data);
            }
          });
        });
        addTearDown(server.close);

        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '127.0.0.1',
          proxyPort: server.port,
        );
        final conn = await ProxyTunnel.connect(
          'ap.spotify.com',
          4070,
          timeout: const Duration(seconds: 5),
          proxy: proxy,
        );
        final received = StringBuffer();
        final done = Completer<void>();
        conn.input.listen((d) {
          received.write(latin1.decode(d));
          if (received.toString() == 'HELLOping') done.complete();
        });
        conn.socket.add(latin1.encode('ping'));
        await done.future.timeout(const Duration(seconds: 5));
        conn.socket.destroy();

        expect(
          requests.single,
          startsWith('CONNECT ap.spotify.com:4070 HTTP/1.1\r\n'),
        );
      },
    );

    test('a non-2xx proxy response fails the connection', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) {
        client.listen(
          (_) => client.add(
            latin1.encode('HTTP/1.1 407 Proxy Authentication Required\r\n\r\n'),
          ),
        );
      });
      addTearDown(server.close);

      final proxy = NetworkProxy(
        systemReader: () async => SystemProxySettings.none,
      );
      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '127.0.0.1',
        proxyPort: server.port,
      );
      await expectLater(
        ProxyTunnel.connect(
          'ap.spotify.com',
          4070,
          timeout: const Duration(seconds: 5),
          proxy: proxy,
        ),
        // 407 要单独提示认证失败，而不是笼统的「代理拒绝连接」
        throwsA(
          isA<ProxyTunnelException>().having(
            (e) => e.toString(),
            'message',
            contains('认证失败'),
          ),
        ),
      );
    });

    test(
      'CONNECT carries Proxy-Authorization when credentials are set',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <String>[];
        server.listen((client) {
          client.listen((data) {
            requests.add(latin1.decode(data));
            client.add(
              latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
            );
          });
        });
        addTearDown(server.close);

        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '127.0.0.1',
          proxyPort: server.port,
          proxyUsername: 'user',
          proxyPassword: 'p@ss word',
        );
        final conn = await ProxyTunnel.connect(
          'ap.spotify.com',
          4070,
          timeout: const Duration(seconds: 5),
          proxy: proxy,
        );
        conn.socket.destroy();

        // 隧道是自己拼头的，任意字符的用户名 / 密码（空格、@、:）都安全
        final expected = base64Encode(utf8.encode('user:p@ss word'));
        expect(
          requests.single,
          contains('Proxy-Authorization: Basic $expected\r\n'),
        );
      },
    );
  });

  group('ProxyTunnel SOCKS5', () {
    test('handshake connects to the requested host and relays bytes', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final handshake = <int>[];
      var relayed = false;
      server.listen((client) {
        final buffer = <int>[];
        var phase = 0;
        client.listen((data) {
          if (relayed) {
            client.add(data);
            return;
          }
          buffer.addAll(data);
          if (phase == 0 && buffer.length >= 3) {
            handshake.addAll(buffer);
            buffer.clear();
            client.add([5, 0]); // 免认证
            phase = 1;
          }
          if (phase == 1 && buffer.length >= 5) {
            final hostLength = buffer[4];
            if (buffer.length >= 5 + hostLength + 2) {
              handshake.addAll(buffer);
              buffer.clear();
              relayed = true;
              client.add([5, 0, 0, 1, 127, 0, 0, 1, 0x1f, 0x90]);
              client.add(utf8.encode('HELLO'));
            }
          }
        });
      });

      final proxy = NetworkProxy(
        systemReader: () async => SystemProxySettings.none,
      );
      await proxy.configure(mode: ProxyMode.system);
      final conn = await ProxyTunnel.connect(
        'api.spotify.com',
        443,
        timeout: const Duration(seconds: 5),
        proxy: proxy,
        endpoint: ProxyEndpoint(
          '127.0.0.1',
          server.port,
          type: ProxyType.socks5,
        ),
      );
      final received = StringBuffer();
      final done = Completer<void>();
      conn.input.listen((d) {
        received.write(latin1.decode(d));
        if (received.toString() == 'HELLOpong') done.complete();
      });
      conn.socket.add(latin1.encode('pong'));
      await done.future.timeout(const Duration(seconds: 5));
      conn.socket.destroy();

      expect(handshake.sublist(0, 3), [5, 1, 0]);
      final request = handshake.sublist(3);
      expect(request[0], 5);
      expect(request[3], 3, reason: '域名寻址');
      final hostLength = request[4];
      expect(
        utf8.decode(request.sublist(5, 5 + hostLength)),
        'api.spotify.com',
      );
      expect(
        (request[5 + hostLength] << 8) | request[6 + hostLength],
        443,
      );
    });

    test('a rejected reply surfaces a readable error', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) {
        final buffer = <int>[];
        var greeted = false;
        client.listen((data) {
          buffer.addAll(data);
          if (!greeted && buffer.length >= 3) {
            greeted = true;
            buffer.clear();
            client.add([5, 0]); // 免认证
          } else if (greeted && buffer.length >= 4) {
            buffer.clear();
            client.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]); // connection refused
          }
        });
      });
      final proxy = NetworkProxy(
        systemReader: () async => SystemProxySettings.none,
      );
      await proxy.configure(mode: ProxyMode.system);
      await expectLater(
        ProxyTunnel.connect(
          'api.spotify.com',
          443,
          timeout: const Duration(seconds: 5),
          proxy: proxy,
          endpoint: ProxyEndpoint(
            '127.0.0.1',
            server.port,
            type: ProxyType.socks5,
          ),
        ),
        throwsA(
          isA<ProxyTunnelException>().having(
            (e) => e.toString(),
            'message',
            contains('connection refused'),
          ),
        ),
      );
    });
  });

  group('ProxyHttpOverrides', () {
    /// 起一台要求认证的假代理：凭据对就回 200，否则回 407（带 Basic 质询头）。
    Future<ServerSocket> startAuthProxy({
      String credentials = 'user:pass',
    }) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) {
        client.listen((data) {
          // dart:io 发出的头名是小写的（比对值一并小写，base64 内容不受影响）
          final request = latin1.decode(data).toLowerCase();
          final token = base64Encode(utf8.encode(credentials)).toLowerCase();
          final ok = request.contains('proxy-authorization: basic $token');
          client.add(
            latin1.encode(
              ok
                  ? 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
                  : 'HTTP/1.1 407 Proxy Authentication Required\r\n'
                        'Proxy-Authenticate: Basic realm="proxy"\r\n'
                        'Content-Length: 0\r\n'
                        'Connection: close\r\n\r\n',
            ),
          );
          client.close();
        });
      });
      return server;
    }

    test('credentials in the proxy string authenticate preemptively', () async {
      final server = await startAuthProxy();
      final proxy = NetworkProxy(
        systemReader: () async => SystemProxySettings.none,
      );
      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '127.0.0.1',
        proxyPort: server.port,
        proxyUsername: 'user',
        proxyPassword: 'pass',
      );
      final client = ProxyHttpOverrides(proxy).createHttpClient(null);
      addTearDown(() => client.close(force: true));

      final request = await client.getUrl(Uri.parse('http://api.spotify.com/'));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      expect(response.statusCode, 200);
      await response.drain<void>();
    });

    test(
      'a wrong password surfaces a 407 instead of retrying forever',
      () async {
        final server = await startAuthProxy();
        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '127.0.0.1',
          proxyPort: server.port,
          proxyUsername: 'user',
          proxyPassword: 'wrong',
        );
        final client = ProxyHttpOverrides(proxy).createHttpClient(null);
        addTearDown(() => client.close(force: true));

        final request = await client.getUrl(
          Uri.parse('http://api.spotify.com/'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        // 关键回归保护：dart:io 的 authenticateProxy 路线在密码错误时会无限重试，
        // 这里必须干脆地拿到 407 响应
        expect(response.statusCode, 407);
        await response.drain<void>();
      },
    );

    test(
      'a password with spaces and @ still authenticates plain HTTP',
      () async {
        final server = await startAuthProxy(credentials: 'user:pa ss@1');
        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '127.0.0.1',
          proxyPort: server.port,
          proxyUsername: 'user',
          proxyPassword: 'pa ss@1',
        );
        final client = ProxyHttpOverrides(proxy).createHttpClient(null);
        addTearDown(() => client.close(force: true));

        final request = await client.getUrl(
          Uri.parse('http://api.spotify.com/'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        expect(response.statusCode, 200);
        await response.drain<void>();
      },
    );

    /// 假的 CONNECT 代理：记下每个 CONNECT 请求头；[target] 非空时把隧道接到本机这个端口，
    /// 否则回 200 后立即断开。
    Future<(ServerSocket, List<String>)> startConnectProxy({
      int? target,
    }) async {
      final connects = <String>[];
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) {
        final head = <int>[];
        Socket? upstream;
        late final StreamSubscription<List<int>> sub;
        sub = client.listen(
          (data) async {
            if (upstream != null) {
              upstream!.add(data);
              return;
            }
            head.addAll(data);
            final text = latin1.decode(head);
            final end = text.indexOf('\r\n\r\n');
            if (end < 0) return;
            connects.add(text.substring(0, end));
            if (target == null) {
              client.add(
                latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
              );
              client.destroy();
              return;
            }
            sub.pause();
            final up = await Socket.connect(
              InternetAddress.loopbackIPv4,
              target,
            );
            upstream = up;
            client.add(
              latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
            );
            if (head.length > end + 4) up.add(head.sublist(end + 4));
            up.listen(
              client.add,
              onDone: client.destroy,
              onError: (_) => client.destroy(),
            );
            sub.resume();
          },
          onDone: () => upstream?.destroy(),
          onError: (_) => upstream?.destroy(),
        );
      });
      return (server, connects);
    }

    test('authenticated HTTPS goes through our own CONNECT tunnel', () async {
      final (server, connects) = await startConnectProxy();
      final proxy = NetworkProxy(
        systemReader: () async => SystemProxySettings.none,
      );
      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '127.0.0.1',
        proxyPort: server.port,
        proxyUsername: 'user',
        proxyPassword: 'pa;ss',
      );
      final client = ProxyHttpOverrides(proxy).createHttpClient(null);
      addTearDown(() => client.close(force: true));

      // 代理回 200 后就断开，TLS 握手随之失败；这里只关心 CONNECT 怎么发的
      await expectLater(
        client
            .getUrl(Uri.parse('https://api.spotify.com/v1/me'))
            .then((r) => r.close()),
        throwsA(anything),
      );
      expect(connects, hasLength(1));
      expect(
        connects.single,
        startsWith('CONNECT api.spotify.com:443 HTTP/1.1\r\n'),
      );
      // 头名大小写出自 ProxyTunnel（dart:io 自己发的 CONNECT 头名是小写的），且 ';' 等任意字符都能带上
      expect(
        connects.single,
        contains(
          'Proxy-Authorization: Basic ${base64Encode(utf8.encode('user:pa;ss'))}',
        ),
      );
    });

    test(
      'HTTPS gateway requests use the forward proxy, not the AP tunnel',
      () async {
        final (server, connects) = await startConnectProxy();
        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '127.0.0.1',
          proxyPort: server.port,
          proxyUsername: 'user',
          proxyPassword: 'pass',
          gateway: const SpotifyGateway(
            enabled: true,
            baseUrl: 'https://gateway.example/api',
            username: 'gateway-user',
            password: 'gateway-pass',
          ),
        );
        final client = ProxyHttpOverrides(proxy).createHttpClient(null);
        addTearDown(() => client.close(force: true));

        await expectLater(
          client
              .getUrl(Uri.parse('https://api.spotify.com/v1/me'))
              .then((request) => request.close())
              .timeout(const Duration(seconds: 5)),
          throwsA(anything),
        );
        expect(connects, hasLength(1));
        expect(
          connects.single,
          startsWith('CONNECT gateway.example:443 HTTP/1.1\r\n'),
        );
        expect(
          connects.single,
          contains(
            'Proxy-Authorization: Basic ${base64Encode(utf8.encode('user:pass'))}',
          ),
        );
      },
    );

    test(
      'the target server never sees Proxy-Authorization through the tunnel',
      () async {
        // 目标：本机明文 HTTP 服务；直接走 ProxyTunnel，避免 macOS 的测试证书策略掩盖回归
        final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(origin.close);
        final originHeaders = <String>[];
        origin.listen((client) {
          final bytes = <int>[];
          client.listen((data) {
            bytes.addAll(data);
            final text = latin1.decode(bytes, allowInvalid: true);
            final end = text.indexOf('\r\n\r\n');
            if (end < 0) return;
            originHeaders.add(text.substring(0, end));
            client.add(
              ascii.encode(
                'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
              ),
            );
            client.close();
          });
        });

        final (server, connects) = await startConnectProxy(target: origin.port);
        final proxy = NetworkProxy(
          systemReader: () async => SystemProxySettings.none,
        );
        await proxy.configure(
          mode: ProxyMode.manual,
          proxyHost: '127.0.0.1',
          proxyPort: server.port,
          proxyUsername: 'user',
          proxyPassword: 'pass',
        );
        final tunnel = await ProxyTunnel.connect(
          'proxy-target.test',
          origin.port,
          timeout: const Duration(seconds: 5),
          proxy: proxy,
        );
        addTearDown(tunnel.socket.destroy);
        tunnel.socket.add(
          ascii.encode(
            'GET /api HTTP/1.1\r\nHost: proxy-target.test\r\nConnection: close\r\n\r\n',
          ),
        );
        final response = await tunnel.input
            .map(utf8.decode)
            .join()
            .timeout(const Duration(seconds: 5));
        expect(response, contains('HTTP/1.1 200 OK'));

        expect(
          connects.single,
          contains(
            'Proxy-Authorization: Basic ${base64Encode(utf8.encode('user:pass'))}',
          ),
        );
        expect(originHeaders, isNotEmpty);
        // 回归保护：dart:io 自带的代理认证会把这个头也发进隧道，交给目标服务器
        expect(
          originHeaders.single.toLowerCase(),
          isNot(contains('proxy-authorization:')),
        );
      },
    );
  });
}
