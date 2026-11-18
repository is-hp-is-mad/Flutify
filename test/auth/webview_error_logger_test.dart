import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutify_app/services/auth/webview_error_logger.dart';

void main() {
  test('sanitizeUrl preserves path and redacts sensitive query params', () {
    final sanitized = WebViewErrorLogger.sanitizeUrl(
      'https://accounts.spotify.com/login/v2?code=secret_auth_code&state=xyz&continue=https%3A%2F%2Fopen.spotify.com%2F&lang=zh',
    );
    expect(sanitized, startsWith('https://accounts.spotify.com/login/v2?'));
    expect(sanitized, contains('code=<redacted>'));
    expect(sanitized, contains('state=<redacted>'));
    expect(sanitized, contains('lang=zh'));
    expect(sanitized, isNot(contains('secret_auth_code')));
    expect(sanitized, isNot(contains('xyz')));
  });

  test('sanitizeBody strips cookies, bearer tokens, and json secrets', () {
    final raw = utf8.encode(
      'Cookie: sp_dc=AQB_SECRET; sp_key=123 | sp_dc=AQB_OTHER | Authorization: Bearer abc.def.ghi '
      '{"error":"invalid_grant","access_token":"tok123","email":"user@example.com"}',
    );
    final sanitized = WebViewErrorLogger.sanitizeBody(Uint8List.fromList(raw));
    expect(sanitized, contains('Cookie=<redacted>'));
    expect(sanitized, contains('sp_dc=<redacted>'));
    expect(sanitized, contains('Authorization=<redacted>'));
    expect(sanitized, contains('"access_token":"<redacted>"'));
    expect(sanitized, contains('"email":"<redacted>"'));
    expect(sanitized, contains('"error":"invalid_grant"'));
    expect(sanitized, isNot(contains('AQB_SECRET')));
    expect(sanitized, isNot(contains('AQB_OTHER')));
    expect(sanitized, isNot(contains('abc.def.ghi')));
    expect(sanitized, isNot(contains('tok123')));
    expect(sanitized, isNot(contains('user@example.com')));
  });

  test('sanitizeBody truncates oversized payloads', () {
    final raw = Uint8List.fromList(utf8.encode('x' * 800));
    final sanitized = WebViewErrorLogger.sanitizeBody(raw, maxChars: 100);
    expect(sanitized, startsWith('x' * 100));
    expect(sanitized, contains('truncated 800B'));
  });
}
