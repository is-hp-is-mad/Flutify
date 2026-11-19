import 'package:flutify_app/services/auth/session_token_source.dart';
import 'package:flutify_app/services/auth/spotify_auth_service.dart';
import 'package:flutify_app/services/auth/web_token_exception.dart';
import 'package:flutify_app/services/auth/web_token_service.dart';
import 'package:flutify_app/services/storage/auth_session_store.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 令牌续期交给 [SessionTokenSource]（生产为 Rust 会话核心）时，结果按 epoch 写回 Dart 存储，
/// 401 清除登录态；来源不处理（返回 null）时回到 Dart HTTP。
class _FakeTokens implements SessionTokenSource {
  SessionToken? Function(AuthSessionStore storage)? web;
  SessionToken? Function(AuthSessionStore storage)? client;
  int webCalls = 0;
  int clientCalls = 0;

  @override
  Future<SessionToken?> refreshWebAccessToken(AuthSessionStore storage) async {
    webCalls++;
    return web?.call(storage);
  }

  @override
  Future<SessionToken?> refreshClientToken(AuthSessionStore storage) async {
    clientCalls++;
    return client?.call(storage);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late List<Uri> httpRequests;
  late _FakeTokens tokens;
  late int cookieClears;

  final future = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'sp_auth_method': 'desktop',
      'sp_access_token': 'old-token',
      'sp_access_token_expiry': 1,
      'sp_username': 'test-user',
      'sp_client_token': 'old-client',
      'sp_client_token_expiry': 1,
      'sp_client_token_profile': 'desktop',
      'sp_dc': 'cookie',
      'sp_web_access_token': 'old-web',
      'sp_web_access_token_expiry': 1,
      'sp_device_id': 'installation',
    });
    storage = await StorageService.init();
    cookieClears = 0;
    storage.auth.clearWebViewCookies = () async => cookieClears++;
    httpRequests = [];
    tokens = _FakeTokens();
  });

  MockClient server() => MockClient((request) async {
    httpRequests.add(request.url);
    if (request.url.path == '/api/server-time') {
      return http.Response('{"serverTime": 1}', 200);
    }
    if (request.url.path == '/api/token') {
      return http.Response(
        '{"accessToken":"dart-token","accessTokenExpirationTimestampMs":$future}',
        200,
      );
    }
    if (request.url.host == 'clienttoken.spotify.com') {
      return http.Response(
        '{"granted_token":{"token":"dart-client","expires_after_seconds":1209600}}',
        200,
      );
    }
    return http.Response('', 404);
  });

  SpotifyAuthService auth() => SpotifyAuthService(
    storage.auth,
    server(),
    (token, deviceId) async => 'test-user',
    tokens,
  );

  test('access token refresh is written back from the source', () async {
    tokens.web = (s) {
      expect(s.spDc, 'cookie');
      return (token: 'rust-token', expiryMs: future);
    };
    expect(await auth().refreshAccessToken(), 'rust-token');
    expect(tokens.webCalls, 1);
    expect(storage.auth.accessToken, 'rust-token');
    expect(storage.auth.accessTokenExpiry, future);
    expect(storage.auth.webAccessToken, 'rust-token');
    expect(storage.auth.webAccessTokenExpiry, future);
    expect(httpRequests, isEmpty);
  });

  test('source returning null falls back to Dart HTTP', () async {
    expect(await auth().refreshAccessToken(), 'dart-token');
    expect(tokens.webCalls, 1);
    expect(httpRequests.map((u) => u.path), contains('/api/token'));
    expect(storage.auth.accessToken, 'dart-token');
  });

  test('source 401 clears the session like SessionHttpClient', () async {
    tokens.web = (_) => throw WebTokenHttpException(401);
    await expectLater(
      auth().refreshAccessToken(),
      throwsA(isA<WebTokenHttpException>()),
    );
    expect(storage.auth.isLoggedIn, isFalse);
    expect(storage.auth.spDc, isEmpty);
    expect(storage.auth.accessToken, isEmpty);
    expect(cookieClears, 1);
    expect(httpRequests, isEmpty);
  });

  test('source 403 keeps the session', () async {
    tokens.web = (_) => throw WebTokenHttpException(403);
    await expectLater(
      auth().refreshAccessToken(),
      throwsA(isA<WebTokenHttpException>()),
    );
    expect(storage.auth.isLoggedIn, isTrue);
    expect(cookieClears, 0);
  });

  test('late source result cannot restore a cleared session', () async {
    tokens.web = (s) {
      // 续期途中会话被清除：结果不得写回
      s.invalidateSession(s.sessionEpoch);
      return (token: 'late', expiryMs: future);
    };
    await expectLater(auth().refreshAccessToken(), throwsStateError);
    await storage.auth.prepareForLogin();
    expect(storage.auth.accessToken, isEmpty);
    expect(storage.auth.webAccessToken, isEmpty);
  });

  test('client token from the source is stored as the web profile', () async {
    tokens.client = (s) {
      expect(s.deviceId, 'installation');
      return (token: 'rust-client', expiryMs: future);
    };
    expect(await auth().ensureClientToken(), 'rust-client');
    expect(tokens.clientCalls, 1);
    expect(storage.auth.clientToken, 'rust-client');
    expect(storage.auth.clientTokenExpiry, future);
    expect(storage.auth.clientTokenProfile, 'web');
    expect(httpRequests, isEmpty);
  });

  test('client token falls back to Dart HTTP when the source declines', () async {
    expect(await auth().ensureClientToken(), 'dart-client');
    expect(storage.auth.clientTokenProfile, 'web');
    expect(httpRequests.single.host, 'clienttoken.spotify.com');
  });

  test('WebTokenService mints through the source', () async {
    tokens.web = (_) => (token: 'rust-web', expiryMs: future);
    final service = WebTokenService(storage.auth, server(), tokens);
    expect(await service.ensureWebAccessToken(), 'rust-web');
    expect(storage.auth.webAccessToken, 'rust-web');
    expect(storage.auth.webAccessTokenExpiry, future);
    // 只更新 Web token，不动业务 access_token
    expect(storage.auth.accessToken, 'old-token');
    expect(httpRequests, isEmpty);
  });

  test('WebTokenService source 401 clears the session without retry', () async {
    tokens.web = (_) => throw WebTokenHttpException(401);
    final service = WebTokenService(storage.auth, server(), tokens);
    await expectLater(
      service.ensureWebAccessToken(),
      throwsA(isA<WebTokenHttpException>()),
    );
    expect(tokens.webCalls, 1);
    expect(storage.auth.spDc, isEmpty);
    expect(httpRequests, isEmpty);
  });
}
