import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/services/network/network_proxy.dart';
import 'package:flutify_app/services/network/proxy_mode.dart';
import 'package:flutify_app/services/network/spotify_fallback_roots.dart';
import 'package:flutify_app/services/network/windows_trust_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final certFile = File('test/fixtures/tls/localhost.pem');

  tearDown(() {
    messenger.setMockMethodCallHandler(WindowsTrustStore.channel, null);
  });

  test(
    'system root enables TLS through proxy overrides without bypassing host or trust checks',
    () async {
      final pem = await certFile.readAsString();
      final der = base64Decode(
        pem.replaceAll(RegExp(r'-----[^\n]+-----|\s'), ''),
      );
      messenger.setMockMethodCallHandler(WindowsTrustStore.channel, (
        call,
      ) async {
        expect(call.method, 'roots');
        return [
          Uint8List.fromList([1, 2, 3]),
          der,
        ];
      });
      final trusted = SecurityContext();
      expect(await WindowsTrustStore.loadInto(trusted), 1);

      final serverContext = SecurityContext()
        ..useCertificateChain(certFile.path)
        ..usePrivateKey('test/fixtures/tls/localhost-key.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      server.listen((request) async {
        request.response.write('ok');
        await request.response.close();
      }, onError: (Object _) {}); // Rejected handshakes also reach the server.
      addTearDown(() => server.close(force: true));

      final proxy = NetworkProxy();
      await proxy.configure(
        mode: ProxyMode.manual,
        proxyHost: '127.0.0.1',
        proxyPort: 1,
      );
      Future<String> get(SecurityContext context, String host) async {
        // Loopback must still bypass the configured proxy.
        final client = ProxyHttpOverrides(proxy).createHttpClient(context);
        try {
          final request = await client.getUrl(
            Uri.parse('https://$host:${server.port}/'),
          );
          return await (await request.close()).transform(utf8.decoder).join();
        } finally {
          client.close(force: true);
        }
      }

      await expectLater(
        get(SecurityContext(), 'localhost'),
        throwsA(isA<HandshakeException>()),
      );
      expect(await get(trusted, 'localhost'), 'ok');
      await expectLater(
        get(trusted, '127.0.0.1'),
        throwsA(isA<HandshakeException>()),
      );
    },
    // macOS 上 dart:io 的信任评估走 Security.framework，Apple TLS 策略拒绝
    // 有效期 >825 天的自签证书（本测试用 100 年 fixture 避免过期），与 Windows
    // 行为不同，属平台限制而非 trust-store 逻辑回归。
    skip: Platform.isMacOS
        ? 'Apple TLS policy rejects the 100y fixture cert (>825d validity)'
        : false,
  );

  test('native store unavailable preserves existing trust context', () async {
    final context = SecurityContext();
    messenger.setMockMethodCallHandler(WindowsTrustStore.channel, (_) async {
      throw PlatformException(code: 'root_store_unavailable');
    });
    expect(await WindowsTrustStore.loadInto(context), 0);
    messenger.setMockMethodCallHandler(WindowsTrustStore.channel, null);
    expect(await WindowsTrustStore.loadInto(context), 0);
  });

  test(
    'bundled Spotify fallback roots load even when system roots are unavailable',
    () async {
      messenger.setMockMethodCallHandler(WindowsTrustStore.channel, (
        call,
      ) async {
        throw PlatformException(code: 'unavailable');
      });
      expect(await WindowsTrustStore.loadInto(SecurityContext()), 0);
      expect(
        WindowsTrustStore.loadFallbackInto(SecurityContext()),
        spotifyFallbackRootsPem.length,
      );
      expect(spotifyFallbackRootsPem, hasLength(3));
    },
  );
}
