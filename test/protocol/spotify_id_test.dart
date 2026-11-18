import 'package:flutify_app/core/utils/spotify_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SpotifyId', () {
    test('base62 ↔ base16 黄金向量', () {
      // Python 独立实现生成
      expect(SpotifyId.fromBase62('02zOzC6p81K9r7qBEmFJT9').toBase16(),
          '015db4870e9b1c4ea11c4a3c7c0a3867');
      expect(SpotifyId.fromBase16('015db4870e9b1c4ea11c4a3c7c0a3867').toBase62(),
          '02zOzC6p81K9r7qBEmFJT9');
    });

    test('真实曲目 ID（Blinding Lights）', () {
      expect(SpotifyId.fromBase62('0VjIjW4GlUZAMYd2vXMi3b').toBase16(),
          '1e6028dab84d4a17a1b3fb28ad51df5d');
    });

    test('URI 提取', () {
      expect(SpotifyId.fromUri('spotify:track:0VjIjW4GlUZAMYd2vXMi3b').toBase62(),
          '0VjIjW4GlUZAMYd2vXMi3b');
      expect(SpotifyId.fromUri('track:0VjIjW4GlUZAMYd2vXMi3b').toBase62(),
          '0VjIjW4GlUZAMYd2vXMi3b');
      expect(SpotifyId.fromUri('0VjIjW4GlUZAMYd2vXMi3b').toBase62(),
          '0VjIjW4GlUZAMYd2vXMi3b');
    });

    test('roundtrip 全域', () {
      for (final hexId in [
        '00000000000000000000000000000000',
        'ffffffffffffffffffffffffffffffff',
        '1e6028dab84d4a17a1b3fb28ad51df5d',
        '00000000000000000000000000000001',
      ]) {
        expect(SpotifyId.fromBase16(hexId).toBase62().length, 22);
        expect(SpotifyId.fromBase16(hexId).toBase62().toBase62IdHex(), hexId);
      }
    });

    test('非法输入抛 FormatException', () {
      expect(() => SpotifyId.fromBase62('short'), throwsFormatException);
      expect(() => SpotifyId.fromBase62('!!!!!!!!!!!!!!!!!!!!!!'), throwsFormatException);
      expect(() => SpotifyId.fromBase16('abcd'), throwsFormatException);
    });
  });
}

extension on String {
  String toBase62IdHex() => SpotifyId.fromBase62(this).toBase16();
}
