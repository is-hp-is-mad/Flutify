import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/services/lyrics/netease_translation_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NeteaseTranslationSource split-line alignment', () {
    test(
      'splits the two Korean clauses shown in the missing-translation report',
      () {
        const originals = [
          LyricLine(startTimeMs: 10000, words: '니 목소릴 들으면'),
          LyricLine(startTimeMs: 14000, words: '꿈 꾸는 것 만 같아'),
        ];

        final aligned = NeteaseTranslationSource.align(
          '[00:10.000]니 목소릴 들으면 꿈 꾸는 것 만 같아',
          '[00:10.000]听见你的声音 似做梦般',
          originals,
        );

        expect(aligned?.map((line) => (line.startTimeMs, line.words)), [
          (10000, '听见你的声音'),
          (14000, '似做梦般'),
        ]);
      },
    );

    test(
      'normalizes case, punctuation and spacing before joining originals',
      () {
        const originals = [
          LyricLine(startTimeMs: 10000, words: 'Wait for me'),
          LyricLine(startTimeMs: 14000, words: 'Come home!'),
        ];

        final aligned = NeteaseTranslationSource.align(
          '[00:10.000]WAIT,  FOR ME! — come home.',
          '[00:10.000]等着我　 回到家',
          originals,
        );

        expect(aligned?.map((line) => line.words), ['等着我', '回到家']);
      },
    );

    test('removes a copied English tail without labeling it a translation', () {
      const originals = [
        LyricLine(startTimeMs: 10000, words: '함께라면'),
        LyricLine(startTimeMs: 14000, words: 'Stay with me!'),
      ];

      final aligned = NeteaseTranslationSource.align(
        '[00:10.000]함께라면 stay with me',
        '[00:10.000]只要一起 STAY  with me!',
        originals,
      );

      expect(aligned?.map((line) => line.words), ['只要一起', '']);
    });

    test('keeps an English echo and its Chinese gloss on their own line', () {
      const originals = [
        LyricLine(startTimeMs: 10000, words: 'Oh'),
        LyricLine(startTimeMs: 14000, words: 'Stay with me'),
      ];

      final aligned = NeteaseTranslationSource.align(
        '[00:10.000]Oh Stay with me',
        '[00:10.000]Oh（哦） 留在我身边',
        originals,
      );

      expect(aligned?.map((line) => line.words), ['Oh（哦）', '留在我身边']);
    });

    test(
      'does not mistake a digit inside a larger number for a copied tail',
      () {
        const originals = [
          LyricLine(startTimeMs: 10000, words: '같이'),
          LyricLine(startTimeMs: 14000, words: '2'),
        ];

        final aligned = NeteaseTranslationSource.align(
          '[00:10.000]같이 2',
          '[00:10.000]我要12',
          originals,
        );

        expect(aligned?.map((line) => line.words), ['我要12', '']);
      },
    );

    test(
      'copied standalone English is not returned as Chinese translation',
      () {
        const originals = [
          LyricLine(startTimeMs: 10000, words: 'Stay with me'),
          LyricLine(startTimeMs: 20000, words: 'Walk away'),
        ];

        final aligned = NeteaseTranslationSource.align(
          '[00:10.000]Stay with me\n[00:20.000]Walk away',
          '[00:10.000]STAY WITH ME!\n[00:20.000]走向远方',
          originals,
        );

        expect(aligned?.map((line) => line.words), ['', '走向远方']);
      },
    );

    test(
      'copied English alone cannot satisfy the translation coverage gate',
      () {
        const originals = [
          LyricLine(startTimeMs: 10000, words: 'Stay with me'),
          LyricLine(startTimeMs: 20000, words: 'Walk away'),
        ];

        expect(
          NeteaseTranslationSource.align(
            '[00:10.000]Stay with me\n[00:20.000]Walk away',
            '[00:10.000]STAY WITH ME!\n[00:20.000]walk away.',
            originals,
          ),
          isNull,
        );
      },
    );

    test(
      'a repeated joined chorus uses the nearest offset-corrected occurrence',
      () {
        const originals = [
          LyricLine(startTimeMs: 20000, words: 'First verse'),
          LyricLine(startTimeMs: 30000, words: 'Hold me'),
          LyricLine(startTimeMs: 34000, words: 'Stay here'),
          LyricLine(startTimeMs: 40000, words: 'Second verse'),
          LyricLine(startTimeMs: 50000, words: 'Hold me'),
          LyricLine(startTimeMs: 54000, words: 'Stay here'),
          LyricLine(startTimeMs: 60000, words: 'Outro'),
        ];
        // Unique anchors establish +8 seconds. Only the second chorus has a
        // translation, so neither of its clauses may fill the first chorus.
        const lrc =
            '[00:12.000]First verse\n'
            '[00:22.000]Hold me Stay here\n'
            '[00:32.000]Second verse\n'
            '[00:42.000]Hold me Stay here\n'
            '[00:52.000]Outro';
        const translated =
            '[00:12.000]第一段\n'
            '[00:32.000]第二段\n'
            '[00:42.000]抱紧我 留在这里\n'
            '[00:52.000]尾声';

        final aligned = NeteaseTranslationSource.align(
          lrc,
          translated,
          originals,
        );

        expect(aligned?.map((line) => line.words), [
          '第一段',
          '',
          '',
          '第二段',
          '抱紧我',
          '留在这里',
          '尾声',
        ]);
      },
    );

    test('retains blank slots and original timestamps around a split pair', () {
      const originals = [
        LyricLine(startTimeMs: 0, words: ''),
        LyricLine(startTimeMs: 10000, words: 'Wait for me'),
        LyricLine(startTimeMs: 14000, words: 'Come home'),
        LyricLine(startTimeMs: 18000, words: '  '),
        LyricLine(startTimeMs: 20000, words: 'Outro'),
      ];

      final aligned = NeteaseTranslationSource.align(
        '[00:10.000]Wait for me Come home\n[00:20.000]Outro',
        '[00:10.000]等着我 回到家\n[00:20.000]尾声',
        originals,
      );

      expect(aligned?.map((line) => (line.startTimeMs, line.words)), [
        (0, ''),
        (10000, '等着我'),
        (14000, '回到家'),
        (18000, ''),
        (20000, '尾声'),
      ]);
    });

    test('does not join original lines across an interlude', () {
      const originals = [
        LyricLine(startTimeMs: 10000, words: 'Wait for me'),
        LyricLine(startTimeMs: 12000, words: ''),
        LyricLine(startTimeMs: 14000, words: 'Come home'),
        LyricLine(startTimeMs: 20000, words: 'Outro'),
      ];

      final aligned = NeteaseTranslationSource.align(
        '[00:10.000]Wait for me Come home\n[00:20.000]Outro',
        '[00:10.000]等着我 回到家\n[00:20.000]尾声',
        originals,
      );

      expect(aligned?.map((line) => line.words), ['等着我 回到家', '', '', '尾声']);
    });

    test('does not join originals more than ten seconds apart', () {
      const originals = [
        LyricLine(startTimeMs: 10000, words: 'Wait for me'),
        LyricLine(startTimeMs: 22000, words: 'Come home'),
      ];

      final aligned = NeteaseTranslationSource.align(
        '[00:10.000]Wait for me Come home',
        '[00:10.000]等着我 回到家',
        originals,
      );

      expect(aligned?.map((line) => line.words), ['等着我 回到家', '']);
    });

    test(
      'keeps an unsplittable sentence intact instead of guessing a boundary',
      () {
        const originals = [
          LyricLine(startTimeMs: 10000, words: 'Wait for me'),
          LyricLine(startTimeMs: 14000, words: 'Come home'),
        ];

        final aligned = NeteaseTranslationSource.align(
          '[00:10.000]Wait for me Come home',
          '[00:10.000]等着我直到回家',
          originals,
        );

        expect(aligned?.map((line) => line.words), ['等着我直到回家', '']);
      },
    );
  });
}
