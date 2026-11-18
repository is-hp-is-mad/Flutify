import 'dart:async';
import 'dart:convert';

import 'package:flutify_app/services/auth/web_token_exception.dart';
import 'package:flutify_app/services/auth/web_token_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    await storage.auth.setSpDc('test-cookie');
  });

  for (final status in [401, 403, 429, 503]) {
    test(
      'HTTP $status is preserved without retry or stale-token fallback',
      () async {
        await storage.auth.setWebAccessToken('expired', 1);
        var requests = 0;
        final service = WebTokenService(storage.auth,
          MockClient((request) async {
            if (request.url.path == '/api/server-time') {
              return http.Response('{"serverTime": 1}', 200);
            }
            requests++;
            return http.Response('sensitive-response-body', status);
          }),
        );
        await expectLater(
          service.ensureWebAccessToken(),
          throwsA(
            isA<WebTokenHttpException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.toString(),
                  'message',
                  isNot(contains('sensitive')),
                ),
          ),
        );
        expect(requests, 1);
        expect(storage.auth.spDc, status == 401 ? '' : 'test-cookie');
      },
    );
  }

  test('network failure does not send an expired token downstream', () async {
    await storage.auth.setWebAccessToken('expired', 1);
    final error = TimeoutException('test timeout');
    final service = WebTokenService(storage.auth,
      MockClient((_) async => throw error),
    );
    await expectLater(
      service.ensureWebAccessToken(retries: 0),
      throwsA(same(error)),
    );
  });

  test(
    'network failure can reuse a token within the refresh margin but still valid',
    () async {
      await storage.auth.setWebAccessToken(
        'valid',
        DateTime.now().millisecondsSinceEpoch + 30000,
      );
      final service = WebTokenService(storage.auth,
        MockClient((_) async => throw TimeoutException('test')),
      );
      expect(await service.ensureWebAccessToken(retries: 0), 'valid');
    },
  );

  test('missing login and malformed responses do not retry', () async {
    var requests = 0;
    final service = WebTokenService(storage.auth,
      MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    await storage.auth.setSpDc('');
    await expectLater(
      service.ensureWebAccessToken(),
      throwsA(isA<WebSignInRequiredException>()),
    );
    expect(requests, 0);
    await storage.auth.setSpDc('test-cookie');
    await expectLater(
      service.ensureWebAccessToken(),
      throwsA(isA<StateError>()),
    );
    expect(
      requests,
      2,
      reason: 'one server-time request and one token request',
    );
  });

  test('a successful response is persisted and reused', () async {
    var requests = 0;
    final service = WebTokenService(storage.auth,
      MockClient((request) async {
        if (request.url.path == '/api/server-time')
          return http.Response('{}', 200);
        requests++;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'accessToken': 'fresh',
              'accessTokenExpirationTimestampMs':
                  DateTime.now().millisecondsSinceEpoch + 3600000,
            }),
          ),
          200,
        );
      }),
    );
    expect(await service.ensureWebAccessToken(), 'fresh');
    expect(await service.ensureWebAccessToken(), 'fresh');
    expect(requests, 1);
    expect(storage.auth.webAccessToken, 'fresh');
  });
}
