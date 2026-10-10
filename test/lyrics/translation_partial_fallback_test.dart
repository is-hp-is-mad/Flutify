import 'dart:async';

import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/services/lyrics/lrclib_client.dart';
import 'package:flutify_app/services/lyrics/lrclib_lyrics_source.dart';
import 'package:flutify_app/services/lyrics/lyrics_resolver.dart';
import 'package:flutify_app/services/lyrics/lyrics_translation.dart';
import 'package:flutify_app/services/lyrics/netease_client.dart';
import 'package:flutify_app/services/lyrics/netease_translation_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

const _query = LyricsQuery(trackId: 'partial', title: 'Song', artist: 'Singer');
const _original = SpotifyLyrics(
  language: 'en',
  lines: [
    LyricLine(startTimeMs: 1000, words: 'First line'),
    LyricLine(startTimeMs: 2000, words: '♪'),
    LyricLine(startTimeMs: 3000, words: 'Second line'),
    LyricLine(startTimeMs: 5000, words: 'Third line'),
  ],
);
const _partial = LyricsTranslation([
  '第一句',
  '',
  '',
  '第三句',
], LyricsProvider.netease);
const _complete = LyricsTranslation([
  '完整第一句',
  '',
  '完整第二句',
  '完整第三句',
], LyricsProvider.lrclib);

SpotifyLyrics _embedded(LyricsTranslation translation) => SpotifyLyrics(
  language: _original.language,
  translationProvider: translation.provider,
  lines: [
    for (final (i, line) in _original.lines.indexed)
      LyricLine(
        startTimeMs: line.startTimeMs,
        words: line.words,
        translation: translation.lines[i],
      ),
  ],
);

void main() {
  test(
    'partial inline lyrics remain visible while a better source loads',
    () async {
      final pending = Completer<LyricsTranslation?>();
      var calls = 0;
      final controller = LyricsTranslationController(
        lookup: (_, _, _) {
          calls++;
          return pending.future;
        },
      );
      addTearDown(controller.dispose);
      controller.configure(
        _embedded(_partial),
        AppPreferences.defaults,
        'zh-CN',
        query: _query,
      );
      expect(calls, 1);
      expect(controller.lines, _partial.lines);
      expect(controller.busy, isTrue);
      pending.complete(_complete);
      await Future<void>.delayed(Duration.zero);
      expect(controller.lines, _complete.lines);
      expect(controller.fromLrclib, isTrue);
      expect(controller.busy, isFalse);
    },
  );

  test('complete translation ignores interludes and needs no lookup', () {
    var calls = 0;
    final controller = LyricsTranslationController(
      lookup: (_, _, _) async {
        calls++;
        return null;
      },
    );
    addTearDown(controller.dispose);
    controller.configure(
      _embedded(_complete),
      AppPreferences.defaults,
      'zh-CN',
      query: _query,
    );
    expect(controller.lines, _complete.lines);
    expect(controller.busy, isFalse);
    expect(calls, 0);
  });

  test('fallback failure does not hide usable partial lyrics', () async {
    var calls = 0;
    final controller = LyricsTranslationController(
      lookup: (_, _, _) async {
        calls++;
        throw StateError('offline');
      },
    );
    addTearDown(controller.dispose);
    controller.configure(
      _embedded(_partial),
      AppPreferences.defaults,
      'zh-CN',
      query: _query,
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(controller.lines, _partial.lines);
    expect(controller.failed, isFalse);
    expect(controller.unavailable, isFalse);
    expect(controller.busy, isFalse);
  });

  test(
    'cancel prevents an in-flight improvement from restoring translations',
    () async {
      final pending = Completer<LyricsTranslation?>();
      var calls = 0;
      final controller = LyricsTranslationController(
        lookup: (_, _, _) {
          calls++;
          return pending.future;
        },
      );
      addTearDown(controller.dispose);
      controller.configure(
        _embedded(_partial),
        AppPreferences.defaults,
        'zh-CN',
        query: _query,
      );
      expect(calls, 1);
      controller.cancel();
      pending.complete(_complete);
      await Future<void>.delayed(Duration.zero);
      expect(controller.lines, isNull);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'an inferior or mismatched result cannot replace existing translations',
    () async {
      for (final result in [
        const LyricsTranslation(['', '', '第二句', '第三句'], LyricsProvider.lrclib),
        const LyricsTranslation(['wrong length'], LyricsProvider.lrclib),
        null,
      ]) {
        var calls = 0;
        final controller = LyricsTranslationController(
          lookup: (_, _, _) async {
            calls++;
            return result;
          },
        );
        addTearDown(controller.dispose);
        controller.configure(
          _embedded(_partial),
          AppPreferences.defaults,
          'zh-CN',
          query: _query,
        );
        await Future<void>.delayed(Duration.zero);
        expect(calls, 1);
        expect(controller.lines, _partial.lines);
        expect(controller.fromNetease, isTrue);
      }
    },
  );

  test(
    'resolver tries a more complete source after partial preloaded lyrics',
    () async {
      final fallback = _Fallback(_complete);
      final netease = _Netease();
      final resolver = LyricsResolver(
        (_) async => _original,
        fallback: fallback,
        translation: netease,
      );
      final result = await resolver.translate(
        _query,
        _embedded(_partial),
        'zh-Hans',
      );
      expect(result?.lines, _complete.lines);
      expect(result?.provider, LyricsProvider.lrclib);
      expect(fallback.calls, 1);
      expect(
        netease.calls,
        0,
        reason: 'the preloaded Netease result is already known',
      );
    },
  );

  test(
    'fresh partial Netease results do not suppress the existing fallback',
    () async {
      final fallback = _Fallback(_complete);
      final netease = _Netease();
      final resolver = LyricsResolver(
        (_) async => _original,
        fallback: fallback,
        translation: netease,
      );
      final result = await resolver.translate(_query, _original, 'zh-Hans');
      expect(result?.lines, _complete.lines);
      expect(fallback.calls, 1);
      expect(netease.calls, 1);
    },
  );

  test(
    'resolver retains partial lyrics on absence, error or poorer fallback',
    () async {
      for (final fallback in [
        _Fallback(null),
        _Fallback(null, fail: true),
        _Fallback(
          const LyricsTranslation([
            '',
            '',
            '第二句',
            '第三句',
          ], LyricsProvider.lrclib),
        ),
      ]) {
        final resolver = LyricsResolver(
          (_) async => _original,
          fallback: fallback,
        );
        final result = await resolver.translate(
          _query,
          _embedded(_partial),
          'zh-Hans',
        );
        expect(result?.lines, _partial.lines);
        expect(result?.provider, LyricsProvider.netease);
        expect(fallback.calls, 1);
      }
    },
  );

  test(
    'disabled fallback performs no extra request for partial translations',
    () async {
      final fallback = _Fallback(_complete);
      final resolver = LyricsResolver(
        (_) async => _original,
        fallback: fallback,
        fallbackEnabled: () => false,
      );
      final result = await resolver.translate(
        _query,
        _embedded(_partial),
        'zh-Hans',
      );
      expect(result?.lines, _partial.lines);
      expect(fallback.calls, 0);
    },
  );
}

class _Fallback extends LrclibLyricsSource {
  final LyricsTranslation? result;
  final bool fail;
  int calls = 0;

  _Fallback(this.result, {this.fail = false})
    : super(
        LrclibClient(
          MockClient((_) async => throw StateError('unexpected HTTP')),
        ),
      );

  @override
  Future<LyricsTranslation?> findTranslation(
    LyricsQuery query,
    SpotifyLyrics original,
    String target,
  ) async {
    calls++;
    if (fail) throw StateError('offline');
    return result;
  }
}

class _Netease extends NeteaseTranslationSource {
  int calls = 0;
  _Netease()
    : super(
        NeteaseClient(
          MockClient((_) async => throw StateError('unexpected HTTP')),
        ),
      );

  @override
  Future<NeteaseTranslationLookup> find(
    LyricsQuery query,
    List<LyricLine> originals,
  ) async {
    calls++;
    return NeteaseTranslationLookup([
      for (final (i, line) in originals.indexed)
        LyricLine(startTimeMs: line.startTimeMs, words: _partial.lines[i]),
    ]);
  }
}
