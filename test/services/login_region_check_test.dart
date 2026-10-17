import 'package:flutify_app/services/auth/login_region_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseTraceCountry 从 trace 文本里取出 loc', () {
    const trace =
        'fl=1\nh=www.cloudflare.com\nip=203.0.113.9\nts=1\nvisit_scheme=https\n'
        'loc=CN\ntls=TLSv1.3\n';
    expect(parseTraceCountry(trace), 'CN');
    expect(parseTraceCountry('loc=us\r\n'), 'US');
    expect(parseTraceCountry('a=1\nloc=JP'), 'JP');
  });

  test('parseTraceCountry 取不到时返回 null', () {
    expect(parseTraceCountry(null), isNull);
    expect(parseTraceCountry(''), isNull);
    expect(parseTraceCountry('nothing here'), isNull);
    // Tor 出口是 T1，不是国家代码
    expect(parseTraceCountry('loc=T1\n'), isNull);
    // 必须是整行的 loc=，不能是别的键名的结尾
    expect(parseTraceCountry('xloc=CN\n'), isNull);
  });

  test('只有中国大陆算被拦截，港澳台和未知都放行', () {
    expect(const LoginRegion('CN').isMainlandChina, isTrue);
    for (final code in ['HK', 'MO', 'TW', 'US', 'JP']) {
      expect(LoginRegion(code).isMainlandChina, isFalse, reason: code);
    }
    expect(const LoginRegion.unknown().isMainlandChina, isFalse);
    expect(const LoginRegion.unknown().detected, isFalse);
    expect(const LoginRegion('US').detected, isTrue);
  });

  test('测试环境里不创建 WebView，按未知处理', () async {
    final region = await LoginRegionCheck.detect();
    expect(region.detected, isFalse);
  });
}
