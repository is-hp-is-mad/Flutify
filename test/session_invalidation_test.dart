import 'dart:async';
import 'dart:convert';

import 'package:flutify_app/providers/auth_provider.dart';
import 'package:flutify_app/services/auth/session_http_client.dart';
import 'package:flutify_app/services/auth/spotify_auth_service.dart';
import 'package:flutify_app/services/auth/web_token_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late int cookieClears;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'sp_auth_method': 'desktop',
      'sp_access_token': 'desktop-token',
      'sp_access_token_expiry': 1,
      'sp_refresh_token': 'refresh-token',
      'sp_username': 'test-user',
      'sp_display_name': 'Test User',
      'sp_avatar_url': 'avatar',
      'sp_client_token': 'client-token',
      'sp_client_token_expiry': 1,
      'sp_client_token_profile': 'desktop',
      'sp_spclient_token': 'legacy-client-token',
      'sp_dc': 'cookie',
      'sp_web_access_token': 'web-token',
      'sp_web_access_token_expiry': 1,
      'sp_device_id': 'installation',
      'sp_proxy_password': 'proxy-password',
      'app_prefs': '{}',
      'update_mode': 'manual',
    });
    storage = await StorageService.init();
    cookieClears = 0;
    storage.clearWebViewCookies = () async {
      cookieClears++;
    };
  });

  void expectCleared() {
    for (final value in [
      storage.accessToken,
      storage.refreshToken,
      storage.username,
      storage.displayName,
      storage.avatarUrl,
      storage.clientToken,
      storage.clientTokenProfile,
      storage.spClientToken,
      storage.spDc,
      storage.webAccessToken,
    ]) {
      expect(value, isEmpty);
    }
    expect(storage.isLoggedIn, isFalse);
    expect(storage.accessTokenExpiry, 0);
    expect(storage.clientTokenExpiry, 0);
    expect(storage.webAccessTokenExpiry, 0);
  }

  test(
    'account 401 clears every credential and cookies, signs UI out',
    () async {
      final auth = SpotifyAuthService(
        storage,
        MockClient((_) async => http.Response('', 200)),
      );
      final provider = AuthProvider(auth);
      addTearDown(provider.dispose);
      var changes = 0;
      provider.onSessionChanged = () => changes++;
      final order = <String>[];
      storage.beforeCookieCleanup.add(() async {
        order.add('stop-page');
      });
      storage.clearWebViewCookies = () async {
        order.add('cookies');
        expect(provider.isSignedIn, isFalse);
        expectCleared();
        cookieClears++;
      };
      final client = SessionHttpClient(
        storage,
        MockClient((_) async => http.Response('rejected', 401)),
      );
      final response = await client.get(
        Uri.parse('https://spclient.wg.spotify.com/metadata'),
        headers: {'Authorization': 'Bearer desktop-token'},
      );
      expect(response.statusCode, 401);
      expect(response.body, 'rejected');
      expectCleared();
      expect(order, ['stop-page', 'cookies']);
      expect(cookieClears, 1);
      expect(changes, 1);
      expect(storage.cookieCleanupPending, isFalse);
      expect(storage.deviceId, 'installation');
      expect(storage.proxyPassword, 'proxy-password');
      expect(storage.preferencesJson, '{}');
      expect(storage.updateMode, 'manual');
    },
  );

  for (final status in [403, 429, 503]) {
    test('account HTTP $status preserves session', () async {
      final client = SessionHttpClient(
        storage,
        MockClient((_) async => http.Response('', status)),
      );
      await client.get(
        Uri.parse('https://api.spotify.com/v1/me'),
        headers: {'Authorization': 'Bearer desktop-token'},
      );
      expect(storage.isLoggedIn, isTrue);
      expect(cookieClears, 0);
    });
  }

  for (final request in [
    ('https://audio.scdn.co/file', {'Authorization': 'Bearer desktop-token'}),
    (
      'https://spotify.com.example.org/api',
      {'Authorization': 'Bearer desktop-token'},
    ),
    (
      'https://spclient.wg.spotify.com/widevine-license/v1/application-certificate',
      {'client-token': 'client-token'},
    ),
    ('https://open.spotify.com/api/server-time', <String, String>{}),
    (
      'https://api.spotify.com/v1/me',
      {'Authorization': 'Bearer previous-account-token'},
    ),
  ]) {
    test(
      'unrelated or anonymous 401 preserves login: ${request.$1} ${request.$2.keys}',
      () async {
        final client = SessionHttpClient(
          storage,
          MockClient((_) async => http.Response('', 401)),
        );
        await client.get(Uri.parse(request.$1), headers: request.$2);
        expect(storage.isLoggedIn, isTrue);
        expect(cookieClears, 0);
      },
    );
  }

  test(
    'concurrent 401 responses share cleanup; new login waits for it',
    () async {
      final releaseCookies = Completer<void>();
      final clearing = Completer<void>();
      storage.clearWebViewCookies = () async {
        cookieClears++;
        clearing.complete();
        await releaseCookies.future;
      };
      final client = SessionHttpClient(
        storage,
        MockClient((_) async => http.Response('', 401)),
      );
      final requests = List.generate(
        3,
        (_) => client.get(
          Uri.parse('https://api.spotify.com/v1/me'),
          headers: {'Authorization': 'Bearer desktop-token'},
        ),
      );
      await clearing.future;
      expectCleared();
      var loginReady = false;
      final login = storage.prepareForLogin().then((_) => loginReady = true);
      await Future<void>.delayed(Duration.zero);
      expect(loginReady, isFalse);
      releaseCookies.complete();
      await Future.wait(requests);
      await login;
      expect(cookieClears, 1);
    },
  );

  test('late old 401 does not clear a new login', () async {
    final reply = Completer<http.Response>();
    final sent = Completer<void>();
    final client = SessionHttpClient(
      storage,
      MockClient((_) {
        sent.complete();
        return reply.future;
      }),
    );
    final request = client.get(
      Uri.parse('https://api.spotify.com/v1/me'),
      headers: {'Authorization': 'Bearer desktop-token'},
    );
    await sent.future;
    await storage.invalidateSession(storage.sessionEpoch);
    await storage.beginLoginSession();
    await storage.markDesktopSession();
    await storage.setRefreshToken('new-refresh');
    await storage.setAccessToken('new-access');
    reply.complete(http.Response('', 401));
    await request;
    expect(storage.accessToken, 'new-access');
    expect(storage.refreshToken, 'new-refresh');
    expect(cookieClears, 1);
  });

  test(
    'late successful OAuth refresh cannot restore a cleared session',
    () async {
      final reply = Completer<http.Response>();
      final sent = Completer<void>();
      final auth = SpotifyAuthService(
        storage,
        MockClient((_) {
          sent.complete();
          return reply.future;
        }),
      );
      final refresh = auth.refreshAccessToken();
      final rejected = expectLater(refresh, throwsStateError);
      await sent.future;
      await storage.invalidateSession(storage.sessionEpoch);
      reply.complete(
        http.Response(
          jsonEncode({
            'access_token': 'late',
            'refresh_token': 'late-refresh',
            'expires_in': 3600,
          }),
          200,
        ),
      );
      await rejected;
      expectCleared();
    },
  );

  test('late Web token response cannot restore a cleared session', () async {
    final reply = Completer<http.Response>();
    final sent = Completer<void>();
    final web = WebTokenService(
      storage,
      MockClient((request) {
          if (request.url.path == '/api/server-time') {
            return Future.value(http.Response('{}', 200));
          }
        sent.complete();
        return reply.future;
      }),
    );
    final mint = web.mintAccessToken();
    final rejected = expectLater(mint, throwsStateError);
    await sent.future;
    await storage.invalidateSession(storage.sessionEpoch);
    reply.complete(http.Response('{"accessToken":"late"}', 200));
    await rejected;
    expectCleared();
  });

  test(
    'Web token endpoint 401 resets without remote logout or retry',
    () async {
      var calls = 0;
      final auth = SpotifyAuthService(
        storage,
        MockClient((request) async {
          // 铸造前的服务器时间对齐不算令牌请求
          if (request.url.path == '/api/server-time') {
            return http.Response('{"serverTime":1}', 200);
          }
          calls++;
          expect(request.url.host, 'open.spotify.com');
          expect(request.url.path, '/api/token');
          return http.Response('{"error":"invalid_client"}', 401);
        }),
      );
      await expectLater(auth.refreshAccessToken(), throwsA(anything));
      expectCleared();
      expect(calls, 1);
      expect(cookieClears, 1);
    },
  );

  test(
    'cookie failure keeps credentials cleared and retries across restart',
    () async {
      storage.clearWebViewCookies = () async {
        throw StateError('plugin unavailable');
      };
      await storage.invalidateSession(storage.sessionEpoch);
      expectCleared();
      expect(storage.cookieCleanupPending, isTrue);
      await expectLater(storage.prepareForLogin(), throwsStateError);
      final restored = await StorageService.init();
      expect(restored.cookieCleanupPending, isTrue);
      restored.clearWebViewCookies = () async {
        cookieClears++;
      };
      await restored.prepareForLogin();
      expect(restored.cookieCleanupPending, isFalse);
      expect(cookieClears, 1);
    },
  );

  test('concurrent cookie cleanup retries share one operation', () async {
    storage.clearWebViewCookies = () async => throw StateError('unavailable');
    await storage.invalidateSession(storage.sessionEpoch);
    final release = Completer<void>();
    final started = Completer<void>();
    storage.clearWebViewCookies = () {
      cookieClears++;
      started.complete();
      return release.future;
    };
    final retries = List.generate(3, (_) => storage.prepareForLogin());
    await started.future;
    expect(storage.cookieCleanupPending, isTrue);
    expect(cookieClears, 1);
    release.complete();
    await Future.wait(retries);
    expect(storage.cookieCleanupPending, isFalse);
  });
}
