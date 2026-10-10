import 'dart:async';

import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/services/lyrics/lyrics_disk_cache.dart';
import 'package:flutify_app/services/lyrics/lrclib_client.dart';
import 'package:flutify_app/services/lyrics/lrclib_lyrics_source.dart';
import 'package:flutify_app/services/lyrics/lyrics_resolver.dart';
import 'package:flutify_app/services/lyrics/lyrics_translation.dart';
import 'package:flutify_app/services/lyrics/translation_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

const query = LyricsQuery(
  trackId: 'paper-stars',
  title: 'Paper Stars',
  artist: 'Test Artist',
);
const original = SpotifyLyrics(
  language: 'en',
  lines: [
    LyricLine(
      startTimeMs: 1000,
      words: 'Paper stars',
      syllables: ['Paper', 'stars'],
    ),
    LyricLine(startTimeMs: 2000, words: ''),
    LyricLine(startTimeMs: 4000, words: 'Draw a circle'),
  ],
);

class FakeSource implements TranslationSource {
  @override
  final LyricsProvider provider;
  @override
  LyricsDiskCache? get cache => null;
  TranslationSourceLookup result;
  bool throws = false;
  int calls = 0;
  int forgotten = 0;
  Completer<TranslationSourceLookup>? pending;

  FakeSource(this.provider, String text)
    : result = TranslationSourceLookup([
        LyricLine(startTimeMs: 1000, words: text),
        const LyricLine(startTimeMs: 2000, words: ''),
        const LyricLine(startTimeMs: 4000, words: '画一个圆'),
      ]);

  @override
  Future<TranslationSourceLookup> find(
    LyricsQuery query,
    List<LyricLine> originals,
  ) async {
    calls++;
    if (throws) throw StateError('source unavailable');
    return pending?.future ?? result;
  }

  @override
  Future<void> forget(LyricsQuery query) async {
    forgotten++;
  }
}

class FakeFallback extends LrclibLyricsSource {
  LyricsTranslation? result;
  bool throws = false;
  int calls = 0;

  FakeFallback()
    : super(
        LrclibClient(
          MockClient((_) async => throw StateError('unexpected HTTP')),
        ),
      );

  @override
  Future<LyricsTranslation?> findTranslation(
    LyricsQuery query,
    SpotifyLyrics lyrics,
    String target,
  ) async {
    calls++;
    if (throws) throw StateError('source unavailable');
    return result;
  }
}

void main() {
  late FakeSource qq;
  late FakeSource netease;
  late LyricsResolver resolver;
  setUp(() {
    qq = FakeSource(LyricsProvider.qqMusic, '纸星星');
    netease = FakeSource(LyricsProvider.netease, '纸做的星星');
    resolver = LyricsResolver(
      (_) async => original,
      qqTranslation: qq,
      translation: netease,
    );
  });

  test(
    'preloading selects QQ first and preserves original text, timing and syllables',
    () async {
      final result = await resolver.resolve(query);
      expect(result.lyrics.translationProvider, LyricsProvider.qqMusic);
      expect(result.lyrics.lines.first.translation, '纸星星');
      expect(
        result.lyrics.lines.map((l) => l.words),
        original.lines.map((l) => l.words),
      );
      expect(result.lyrics.lines.map((l) => l.startTimeMs), [1000, 2000, 4000]);
      expect(result.lyrics.lines.first.syllables, ['Paper', 'stars']);
      expect(netease.calls, 0);
    },
  );

  test(
    'translation button uses QQ first, including Traditional Chinese',
    () async {
      final result = await resolver.translate(query, original, 'zh-TW');
      expect(result?.provider, LyricsProvider.qqMusic);
      expect(result?.lines, ['紙星星', '', '畫一個圓']);
      expect(netease.calls, 0);
    },
  );

  for (final preload in [true, false]) {
    test(
      'partial QQ falls back to more complete NetEase (${preload ? 'preload' : 'button'})',
      () async {
        qq.result = const TranslationSourceLookup([
          LyricLine(startTimeMs: 1000, words: '纸星星'),
          LyricLine(startTimeMs: 2000, words: ''),
          LyricLine(startTimeMs: 4000, words: ''),
        ]);
        final found = preload
            ? LyricsTranslationController.official(
                (await resolver.resolve(query)).lyrics,
                'zh-Hans',
              )
            : await resolver.translate(query, original, 'zh-Hans');
        expect(found?.provider, LyricsProvider.netease);
        expect(found?.lines, ['纸做的星星', '', '画一个圆']);
      },
    );

    test(
      'a fallback cannot drop already translated QQ positions (${preload ? 'preload' : 'button'})',
      () async {
        qq.result = const TranslationSourceLookup([
          LyricLine(startTimeMs: 1000, words: '纸星星'),
          LyricLine(startTimeMs: 2000, words: ''),
          LyricLine(startTimeMs: 4000, words: ''),
        ]);
        netease.result = const TranslationSourceLookup([
          LyricLine(startTimeMs: 1000, words: ''),
          LyricLine(startTimeMs: 2000, words: ''),
          LyricLine(startTimeMs: 4000, words: '画一个圆'),
        ]);
        final found = preload
            ? LyricsTranslationController.official(
                (await resolver.resolve(query)).lyrics,
                'zh-Hans',
              )
            : await resolver.translate(query, original, 'zh-Hans');
        expect(found?.provider, LyricsProvider.qqMusic);
        expect(found?.lines, ['纸星星', '', '']);
      },
    );
  }

  test(
    'partial embedded alternatives can be improved by QQ on preload and auto translation',
    () async {
      final embedded = SpotifyLyrics(
        language: 'en',
        lines: original.lines,
        alternatives: const [
          LyricsAlternative(language: 'zh-Hans', lines: ['已有译词', '', '']),
        ],
      );
      resolver = LyricsResolver(
        (_) async => embedded,
        qqTranslation: qq,
        translation: netease,
      );
      final preloaded = (await resolver.resolve(query)).lyrics;
      final selected = LyricsTranslationController.official(
        preloaded,
        'zh-Hans',
      );
      expect(selected?.provider, LyricsProvider.qqMusic);
      expect(selected?.lines, ['纸星星', '', '画一个圆']);
      expect(preloaded.alternatives, same(embedded.alternatives));
      final controller = LyricsTranslationController(
        lookup: resolver.translate,
      );
      addTearDown(controller.dispose);
      controller.configure(
        preloaded,
        AppPreferences.defaults,
        'zh-Hans',
        query: query,
      );
      expect(controller.fromQqMusic, isTrue);
      expect(controller.busy, isFalse);
      expect(
        qq.calls,
        1,
        reason:
            'complete preload should not issue a duplicate automatic request',
      );
    },
  );

  test(
    'partial QQ can use LRCLIB after NetEase without losing existing coverage',
    () async {
      qq.result = const TranslationSourceLookup([
        LyricLine(startTimeMs: 1000, words: '纸星星'),
        LyricLine(startTimeMs: 2000, words: ''),
        LyricLine(startTimeMs: 4000, words: ''),
      ]);
      netease.result = const TranslationSourceLookup(null);
      final fallback = FakeFallback()
        ..result = const LyricsTranslation([
          '完整译词',
          '',
          '画一个圆',
        ], LyricsProvider.lrclib);
      resolver = LyricsResolver(
        (_) async => original,
        fallback: fallback,
        qqTranslation: qq,
        translation: netease,
      );
      final found = (await resolver.resolve(query)).lyrics;
      expect(found.translationProvider, LyricsProvider.lrclib);
      expect(found.lines.map((line) => line.translation), ['完整译词', '', '画一个圆']);
      expect(fallback.calls, 1);
    },
  );

  test(
    'all sources failing keeps readable embedded content and allows retry',
    () async {
      final embedded = SpotifyLyrics(
        language: 'en',
        lines: const [
          LyricLine(
            startTimeMs: 1000,
            words: 'Paper stars',
            translation: '已有译词',
          ),
          LyricLine(startTimeMs: 2000, words: ''),
          LyricLine(startTimeMs: 4000, words: 'Draw a circle'),
        ],
      );
      qq.throws = netease.throws = true;
      final fallback = FakeFallback()..throws = true;
      resolver = LyricsResolver(
        (_) async => embedded,
        fallback: fallback,
        qqTranslation: qq,
        translation: netease,
      );
      final found = await resolver.resolve(query);
      expect(found.lyrics, same(embedded));
      expect(found.cacheable, isFalse);
      expect((await resolver.translate(query, embedded, 'zh-Hans'))?.lines, [
        '已有译词',
        '',
        '',
      ]);
    },
  );

  test(
    'cancelling auto translation cannot be undone by an in-flight QQ lookup',
    () async {
      final controller = LyricsTranslationController(
        lookup: resolver.translate,
      );
      addTearDown(controller.dispose);
      qq.pending = Completer<TranslationSourceLookup>();
      controller.configure(
        original,
        AppPreferences.defaults,
        'zh-Hans',
        query: query,
      );
      expect(controller.busy, isTrue);
      controller.cancel();
      qq.pending!.complete(qq.result);
      await Future<void>.delayed(Duration.zero);
      expect(controller.lines, isNull);
      expect(controller.busy, isFalse);
      expect(controller.failed, isFalse);
    },
  );

  for (final scenario in [
    'missing',
    'empty',
    'wrong length',
    'wrong language',
    'network error',
    'exception',
  ]) {
    for (final preload in [true, false]) {
      test(
        '$scenario falls back to NetEase (${preload ? 'preload' : 'button'})',
        () async {
          qq.result = switch (scenario) {
            'empty' => const TranslationSourceLookup([
              LyricLine(startTimeMs: 1000, words: ''),
              LyricLine(startTimeMs: 2000, words: ''),
              LyricLine(startTimeMs: 4000, words: ''),
            ]),
            'wrong length' => const TranslationSourceLookup([
              LyricLine(startTimeMs: 1000, words: '纸星星'),
            ]),
            'wrong language' => TranslationSourceLookup(original.lines),
            'network error' => const TranslationSourceLookup(
              null,
              networkError: true,
            ),
            _ => const TranslationSourceLookup(null),
          };
          qq.throws = scenario == 'exception';
          if (preload) {
            final result = await resolver.resolve(query);
            expect(result.lyrics.translationProvider, LyricsProvider.netease);
            expect(result.lyrics.lines.first.translation, '纸做的星星');
            expect(
              result.cacheable,
              !['network error', 'exception'].contains(scenario),
            );
          } else {
            final result = await resolver.translate(query, original, 'zh');
            expect(result?.provider, LyricsProvider.netease);
            expect(result?.lines.first, '纸做的星星');
          }
          expect(qq.calls, 1);
          expect(netease.calls, 1);
        },
      );
    }
  }

  test(
    'both sources unavailable preserve originals and permit a later retry',
    () async {
      qq.throws = netease.throws = true;
      final result = await resolver.resolve(query);
      expect(result.lyrics, same(original));
      expect(result.cacheable, isFalse);
      await expectLater(
        resolver.translate(query, original, 'zh'),
        throwsStateError,
      );
    },
  );

  test('confirmed misses do not become network errors', () async {
    qq.result = netease.result = const TranslationSourceLookup(null);
    expect((await resolver.resolve(query)).cacheable, isTrue);
    expect(await resolver.translate(query, original, 'zh'), isNull);
  });

  test(
    'existing translations are preserved without querying either source',
    () async {
      final embedded = SpotifyLyrics(
        language: 'en',
        lines: original.lines,
        alternatives: const [
          LyricsAlternative(language: 'zh', lines: ['已有译词', '', '画一个圆']),
        ],
      );
      resolver = LyricsResolver(
        (_) async => embedded,
        qqTranslation: qq,
        translation: netease,
      );
      expect((await resolver.resolve(query)).lyrics, same(embedded));
      expect(
        (await resolver.translate(query, embedded, 'zh-Hans'))?.provider,
        LyricsProvider.spotify,
      );
      expect(qq.calls + netease.calls, 0);
    },
  );

  test(
    'disabled preloading does not disable an explicit translation request',
    () async {
      resolver = LyricsResolver(
        (_) async => original,
        qqTranslation: qq,
        translation: netease,
        translationEnabled: () => false,
      );
      await resolver.resolve(query);
      expect(qq.calls + netease.calls, 0);
      expect(
        (await resolver.translate(query, original, 'zh'))?.provider,
        LyricsProvider.qqMusic,
      );
    },
  );

  test(
    'non-Chinese target does not query either Chinese translation source',
    () async {
      expect(await resolver.translate(query, original, 'en'), isNull);
      expect(qq.calls + netease.calls, 0);
    },
  );

  test(
    'Chinese originals do not preload another Chinese version from LRCLIB',
    () async {
      const chinese = SpotifyLyrics(
        lines: [
          LyricLine(startTimeMs: 1000, words: '这里已经是一句中文歌词'),
          LyricLine(startTimeMs: 4000, words: '不要再次把原文当成译文'),
        ],
      );
      final fallback = FakeFallback();
      resolver = LyricsResolver(
        (_) async => chinese,
        fallback: fallback,
        qqTranslation: qq,
        translation: netease,
      );
      expect((await resolver.resolve(query)).lyrics, same(chinese));
      expect(qq.calls + netease.calls + fallback.calls, 0);
      await resolver.translate(query, chinese, 'en');
      expect(
        fallback.calls,
        1,
        reason: 'explicit other-language requests are unchanged',
      );
    },
  );

  test('refresh forgets both providers', () async {
    await resolver.forget(query);
    expect(qq.forgotten, 1);
    expect(netease.forgotten, 1);
  });

  test(
    'omitting community sources preserves the original-only preload contract',
    () async {
      final fallback = FakeFallback();
      resolver = LyricsResolver((_) async => original, fallback: fallback);
      expect((await resolver.resolve(query)).lyrics, same(original));
      expect(fallback.calls, 0);
      await resolver.translate(query, original, 'zh-Hans');
      expect(
        fallback.calls,
        1,
        reason: 'an explicit translation can still use LRCLIB',
      );
    },
  );
}
