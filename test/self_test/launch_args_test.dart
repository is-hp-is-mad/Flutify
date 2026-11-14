import 'package:flutify_app/core/constants/app_info.dart';
import 'package:flutify_app/core/self_test/launch_args.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppInfo.isSelfTestTag', () {
    test('matches only -selftest release tags', () {
      expect(AppInfo.isSelfTestTag('v0.18.1-selftest'), isTrue);
      expect(AppInfo.isSelfTestTag('v0.18.999-selftest'), isTrue);

      expect(AppInfo.isSelfTestTag('v0.18'), isFalse);
      expect(AppInfo.isSelfTestTag('v0.18.1'), isFalse);
      expect(AppInfo.isSelfTestTag('v0.18.1-beta.2'), isFalse);
      expect(AppInfo.isSelfTestTag(''), isFalse);
    });
  });

  group('LaunchArgs.parse', () {
    test('ignores all mock and E2E flags on non-self-test builds', () {
      for (final args in const [
        ['--mock'],
        ['--mock=true'],
        ['--flutify-mock'],
        ['--self-test-e2e=/tmp/e2e'],
        ['--mock', '--self-test-e2e', 'D:/out'],
      ]) {
        final parsed = LaunchArgs.parse(args, isSelfTest: false);
        expect(parsed.mockMode, isFalse, reason: 'Failed for args=$args');
        expect(parsed.e2eOutputDir, isNull, reason: 'Failed for args=$args');
      }
    });

    test('activates mockMode on self-test builds for supported flags', () {
      expect(LaunchArgs.parse(const ['--mock'], isSelfTest: true).mockMode, isTrue);
      expect(
        LaunchArgs.parse(const ['--mock=true'], isSelfTest: true).mockMode,
        isTrue,
      );
      expect(
        LaunchArgs.parse(const ['--flutify-mock'], isSelfTest: true).mockMode,
        isTrue,
      );
    });

    test('parses --self-test-e2e=<dir> and spaced form and enables mockMode', () {
      final eq = LaunchArgs.parse(
        const ['--self-test-e2e=/tmp/flutify_out'],
        isSelfTest: true,
      );
      expect(eq.mockMode, isTrue);
      expect(eq.e2eOutputDir, '/tmp/flutify_out');

      final spaced = LaunchArgs.parse(
        const ['--mock', '--self-test-e2e', r'C:\temp\e2e'],
        isSelfTest: true,
      );
      expect(spaced.mockMode, isTrue);
      expect(spaced.e2eOutputDir, r'C:\temp\e2e');
    });

    test('ignores macOS system args while honoring --mock', () {
      final parsed = LaunchArgs.parse(
        const [
          '-psn_0_123456',
          '-NSDocumentRevisionsDebugMode',
          'YES',
          '--mock',
        ],
        isSelfTest: true,
      );
      expect(parsed.mockMode, isTrue);
      expect(parsed.e2eOutputDir, isNull);
    });

    test('returns LaunchArgs.none for empty or unrelated flags on self-test', () {
      final none = LaunchArgs.parse(
        const ['-psn_0_1', '--unknown-flag'],
        isSelfTest: true,
      );
      expect(none.mockMode, isFalse);
      expect(none.e2eOutputDir, isNull);
    });
  });
}
