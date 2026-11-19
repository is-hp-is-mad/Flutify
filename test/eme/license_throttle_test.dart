import 'dart:typed_data';

import 'package:flutify_app/services/eme/fairplay.dart';
import 'package:flutify_app/services/eme/license_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Spotify license 接口限流（429）时：冷却期内不再请求，冷却短就挂起等过去再试，
/// 避免 CDM / hls.js 密集重试让限流持续下去（实测 1 小时连续播放后出现，每首重试 10 次）。
void main() {
  setUp(() => debugUseFairPlayOverride = false);
  tearDown(() => debugUseFairPlayOverride = null);

  WidevineLicenseClient client(
    List<int> statuses,
    List<DateTime> calls, {
    Duration backoff = const Duration(milliseconds: 80),
    Duration hold = const Duration(seconds: 1),
  }) => WidevineLicenseClient(
    webToken: () async => 'tok',
    clientToken: () async => 'ct',
    hosts: const ['spclient.wg.spotify.com'],
    throttleBackoff: backoff,
    maxThrottleHold: hold,
    client: MockClient((req) async {
      calls.add(DateTime.now());
      final status = statuses.removeAt(0);
      return http.Response.bytes(status == 200 ? [1, 2, 3] : const [], status);
    }),
  );

  test('429 后挂起到冷却结束再试一次，成功即返回', () async {
    final calls = <DateTime>[];
    final c = client([429, 200], calls);
    final body = await c.postLicense(Uint8List.fromList([9]));
    expect(body, [1, 2, 3]);
    expect(calls, hasLength(2));
    expect(calls[1].difference(calls[0]), greaterThanOrEqualTo(const Duration(milliseconds: 70)));
    expect(c.isThrottled, isFalse, reason: '成功后清除冷却');
  });

  test('冷却超过挂起上限：直接报限流，不再打到 Spotify', () async {
    final calls = <DateTime>[];
    final c = client(
      [429, 200],
      calls,
      backoff: const Duration(seconds: 5),
      hold: const Duration(milliseconds: 50),
    );
    await expectLater(
      c.postLicense(Uint8List(1)),
      throwsA(isA<LicenseHttpException>().having((e) => e.isThrottled, 'throttled', isTrue)),
    );
    expect(c.isThrottled, isTrue);
    await expectLater(
      c.postLicense(Uint8List(1)),
      throwsA(isA<LicenseHttpException>().having((e) => e.statusCode, 'status', 429)),
    );
    expect(calls, hasLength(1), reason: '冷却期内的第二次调用不发请求');
  });

  test('非 429 的错误照常抛出、不进入冷却', () async {
    final calls = <DateTime>[];
    final c = client([403], calls);
    await expectLater(
      c.postLicense(Uint8List(1)),
      throwsA(isA<LicenseHttpException>().having((e) => e.statusCode, 'status', 403)),
    );
    expect(c.isThrottled, isFalse);
    expect(calls, hasLength(1));
  });
}
