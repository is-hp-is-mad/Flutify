import 'package:flutify_app/services/auth/web_token_exception.dart';
import 'package:flutify_app/services/auth/web_token_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// issue #53：刚登录成功时的第一次铸造被拒绝，不能清掉登录态和 cookie。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late int cookieClears;

  setUp(() async {
    WebTokenService.loginRetryDelay = Duration.zero;
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    cookieClears = 0;
    storage.clearWebViewCookies = () async => cookieClears++;
    await storage.setSpDc('fresh-cookie');
  });

  WebTokenService service(List<int> statuses) {
    var i = 0;
    return WebTokenService(
      storage,
      MockClient((request) async {
        if (request.url.path == '/api/server-time') {
          return http.Response('{"serverTime": 1}', 200);
        }
        final status = statuses[i++ % statuses.length];
        return http.Response(
          status == 200 ? '{"accessToken":"web-token"}' : 'denied',
          status,
        );
      }),
    );
  }

  test('第一次被拒绝时重试，成功后不动登录态', () async {
    final minted = await service([401, 200]).mintForLogin();
    expect(minted.token, 'web-token');
    expect(storage.spDc, 'fresh-cookie');
    expect(storage.webAccessToken, 'web-token');
    expect(cookieClears, 0);
  });

  test('原生请求一直被拒绝时改用登录页 WebView 铸造', () async {
    Uri? asked;
    final minted = await service([401]).mintForLogin(
      fetchInPage: (uri) async {
        asked = uri;
        return (status: 200, body: '{"accessToken":"page-token"}');
      },
    );
    expect(minted.token, 'page-token');
    expect(asked?.path, '/api/token');
    expect(asked?.queryParameters['totp'], isNotEmpty);
    expect(storage.webAccessToken, 'page-token');
    expect(cookieClears, 0);
  });

  test('页面也拿不到时抛出 401，但 cookie 留着，重试不用重新登录', () async {
    await expectLater(
      service([401]).mintForLogin(fetchInPage: (_) async => null),
      throwsA(
        isA<WebTokenHttpException>().having(
          (e) => e.statusCode,
          'status',
          401,
        ),
      ),
    );
    expect(storage.spDc, 'fresh-cookie');
    expect(cookieClears, 0);
  });

  test('页面请求也被拒绝时同样抛出，由登录页决定是否清除', () async {
    await expectLater(
      service([401]).mintForLogin(
        fetchInPage: (_) async => (status: 401, body: 'denied'),
      ),
      throwsA(isA<WebTokenHttpException>()),
    );
    expect(cookieClears, 0);
  });

  test('rejectSession 才真正清除登录态和 cookie', () async {
    await service([401]).rejectSession();
    await pumpEventQueue();
    expect(storage.spDc, isEmpty);
    expect(cookieClears, 1);
  });
}
