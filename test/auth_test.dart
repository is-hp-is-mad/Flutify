import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutify_app/providers/auth_provider.dart';
import 'package:flutify_app/services/auth/auth_constants.dart';
import 'package:flutify_app/services/auth/proto_codec.dart';
import 'package:flutify_app/services/auth/session_expired_exception.dart';
import 'package:flutify_app/services/auth/spotify_auth_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按 client-token 线协议与资料接口模拟服务端，验证唯一的登录方式「Web 登录」：
/// Web 会话建立登录态、桌面身份 client-token、资料拉取，以及旧版本会话的处理。
void main() {
  late StorageService storage;
  late List<http.Request> clientTokenRequests;
  late List<http.Request> accountsRequests;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    clientTokenRequests = [];
    accountsRequests = [];
  });

  Uint8List grantedClientToken() {
    final granted = ProtoWriter()
      ..string(1, 'fake-client-token')
      ..int32(2, 1209600);
    return (ProtoWriter()..message(2, granted)).toBytes();
  }

  MockClient fakeServer() {
    return MockClient((request) async {
      final url = request.url;
      if (url.host == 'clienttoken.spotify.com') {
        clientTokenRequests.add(request);
        if (request.headers['Content-Type']?.contains('json') ?? false) {
          // Web 播放器格式：JSON 响应 granted_token
          return http.Response(
            jsonEncode({
              'response_type': 'RESPONSE_GRANTED_TOKEN_RESPONSE',
              'granted_token': {
                'token': 'fake-client-token',
                'expires_after_seconds': 1209600,
                'refresh_after_seconds': 1209600,
                'domains': [{'domain': 'spotify.com'}],
              },
            }),
            200,
          );
        }
        return http.Response.bytes(grantedClientToken(), 200);
      }
      if (url.host == 'spclient.wg.spotify.com') {
        // 真实服务端行为：profile/me 是用户名为 "me" 的另一个账号，只有按本人用户名请求才是本人资料
        if (url.path == '/user-profile-view/v3/profile/me') {
          return http.Response(jsonEncode({'name': 'Someone Else', 'image_url': 'https://i.scdn.co/other'}), 200);
        }
        if (url.path == '/user-profile-view/v3/profile/web-user') {
          return http.Response(jsonEncode({'name': 'Web User', 'image_url': 'https://i.scdn.co/me'}), 200);
        }
        return http.Response('', 200); // /api/logout/v1
      }
      if (url.host == 'accounts.spotify.com') {
        // 桌面 OAuth 已移除：任何令牌端点请求都不应再出现
        accountsRequests.add(request);
        return http.Response('gone', 410);
      }
      return http.Response('not found', 404);
    });
  }

  SpotifyAuthService webAuth({void Function(String token)? onResolve}) =>
      SpotifyAuthService(storage, fakeServer(), (token, _) async {
        onResolve?.call(token);
        return 'web-user';
      });

  Future<void> seedWebSession() async {
    await storage.setSpDc('sp-dc-cookie');
    await storage.setWebAccessToken(
      'web-access',
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
  }

  group('Web 登录', () {
    test('Web 会话 → 全局登录态 → Web 播放器身份 client-token → 按用户名拉资料', () async {
      await seedWebSession();
      final resolverTokens = <String>[];
      final auth = webAuth(onResolve: resolverTokens.add);

      await auth.completeWebSignIn();
      expect(auth.isLoggedIn, isTrue);
      expect(await auth.ensureAccessToken(), 'web-access');

      // 令牌不含用户名：用令牌向 AP 查询 canonical username（媒体库按它寻址）
      expect(resolverTokens, ['web-access']);
      expect(auth.username, 'web-user');

      // client-token：与令牌同属 Web 播放器（JSON 请求，对齐 open.spotify.com 前端）
      final body = jsonDecode(clientTokenRequests.single.body) as Map<String, dynamic>;
      final clientData = body['client_data'] as Map<String, dynamic>;
      expect(clientData['client_id'], SpotifyAuthConstants.webClientId);
      expect(clientData['client_version'], SpotifyAuthConstants.webClientVersion);
      expect((clientData['js_sdk_data'] as Map)['device_type'], 'computer');
      expect(storage.clientTokenProfile, 'web');
      expect(storage.clientToken, 'fake-client-token');
      expect(auth.clientHeaders['app-platform'], 'WebPlayer');

      expect(auth.displayName, 'Web User', reason: '资料来自内部 profile-view/{用户名}，不能用 profile/me');
      expect(auth.avatarUrl, 'https://i.scdn.co/me');
      expect(accountsRequests, isEmpty);

      await auth.logout();
      expect(auth.isLoggedIn, isFalse);
      expect(auth.clientHeaders, isEmpty);
    });
  });

  group('旧版本会话', () {
    test('Login5 / 开发者应用登录的会话视为未登录，并清除残留凭据', () async {
      SharedPreferences.setMockInitialValues({
        'sp_auth_method': 'login5',
        'sp_access_token': 'old-access',
        'sp_refresh_token': 'old-refresh',
        'sp_stored_credential': 'blob',
        'sp_client_id': '0123456789abcdef0123456789abcdef',
      });
      final legacy = await StorageService.init();
      expect(legacy.isLoggedIn, isFalse);
      expect(legacy.accessToken, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('sp_stored_credential'), isFalse);
      expect(prefs.containsKey('sp_client_id'), isFalse);
    });

    test('旧版桌面授权会话（无 sp_dc）：续期时标记登录过期，不再请求令牌端点', () async {
      SharedPreferences.setMockInitialValues({
        'sp_auth_method': 'desktop',
        'sp_access_token': 'desktop-access',
        'sp_access_token_expiry': 0,
        'sp_refresh_token': 'desktop-refresh',
      });
      storage = await StorageService.init();
      final auth = webAuth();

      await expectLater(auth.ensureAccessToken(), throwsA(isA<SessionExpiredException>()));
      expect(auth.sessionExpired.value, isTrue);
      await expectLater(auth.ensureAccessToken(), throwsA(isA<SessionExpiredException>()));
      expect(accountsRequests, isEmpty, reason: '桌面 OAuth 已移除，不再请求令牌端点');

      await auth.logout();
      expect(auth.sessionExpired.value, isFalse);
      expect(auth.isLoggedIn, isFalse);
    });
  });

  group('AuthProvider', () {
    test('会话缺用户名：启动时补齐用户名、改正昵称并重新加载媒体库', () async {
      // 旧版本登录后只按 profile/me 存了别人的昵称，用户名为空
      await storage.markDesktopSession();
      await seedWebSession();
      await storage.setAccessToken('web-access');
      await storage.setAccessTokenExpiry(DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch);
      await storage.setDisplayName('Someone Else');
      expect(storage.isLoggedIn, isTrue);

      final provider = AuthProvider(webAuth());
      final reloaded = Completer<void>();
      provider.onSessionChanged = reloaded.complete;
      await reloaded.future.timeout(const Duration(seconds: 5));

      expect(provider.username, 'web-user');
      expect(provider.displayName, 'Web User');
    });

    test('错误翻译', () {
      expect(AuthProvider.describeError(const SocketException('x')), contains('网络'));
      expect(AuthProvider.describeError(const SessionExpiredException()), contains('过期'));
    });
  });
}
