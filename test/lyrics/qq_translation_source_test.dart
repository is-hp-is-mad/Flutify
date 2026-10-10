import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/services/lyrics/lyrics_disk_cache.dart';
import 'package:flutify_app/services/lyrics/qq_music_client.dart';
import 'package:flutify_app/services/lyrics/qq_translation_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const query = LyricsQuery(
  trackId: 'test',
  title: 'Paper Stars',
  artist: 'Test Artist',
  durationMs: 123000,
);
const originals = [
  LyricLine(startTimeMs: 1000, words: 'Paper stars above the gate'),
  LyricLine(startTimeMs: 4000, words: 'Draw a circle in the rain'),
  LyricLine(startTimeMs: 7000, words: 'Leave a lantern by the door'),
];
const lrc =
    '[00:02.00]Paper stars above the gate\n[00:05.00]Draw a circle in the rain\n[00:08.00]Leave a lantern by the door';
const tlyric = '[00:02.00]门上悬着纸星星\n[00:05.00]雨中画个圆\n[00:08.00]门边留一盏灯';

http.Response response(Object data) => http.Response(jsonEncode(data), 200);
http.Response rpc(Object data) => response({
  'code': 0,
  'request': {'code': 0, 'data': data},
});

void main() {
  late Directory dir;
  late LyricsDiskCache cache;
  late List<String> calls;
  late String translation;
  late String reference;
  late String artist;
  late int duration;
  late int status;
  late QqTranslationSource source;
  List<Map<String, Object>>? searchSongs;
  late List<int> detailIds;
  Completer<void>? lyricGate;
  Completer<void>? lyricStarted;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('flutify_qq_test');
    cache = LyricsDiskCache(dir);
    calls = [];
    translation = tlyric;
    reference = lrc;
    artist = 'Test Artist';
    duration = 123;
    status = 200;
    lyricGate = lyricStarted = null;
    searchSongs = null;
    detailIds = [];
    source = QqTranslationSource(
      QqMusicClient(
        MockClient((request) async {
          calls.add(request.url.host);
          if (status != 200) return http.Response('', status);
          if (request.method == 'GET') {
            return response({
              'code': 0,
              'data': {
                'song': {
                  'itemlist':
                      searchSongs ??
                      [
                        {'id': '42', 'name': 'Paper Stars', 'singer': artist},
                      ],
                },
              },
            });
          }
          final method = jsonDecode(request.body)['request']['method'];
          if (method == 'get_song_detail_yqq') {
            final id =
                jsonDecode(request.body)['request']['param']['song_id'] as int;
            detailIds.add(id);
            return rpc({
              'track_info': {
                'id': id,
                'title':
                    searchSongs?.firstWhere(
                      (song) => song['id'] == id,
                    )['name'] ??
                    'Paper Stars',
                'type': 7,
                'interval': duration,
                'singer': [
                  {'name': artist},
                ],
              },
            });
          }
          expect(jsonDecode(request.body)['request']['param']['type'], 7);
          lyricStarted?.complete();
          await lyricGate?.future;
          return rpc({
            'lyric': base64Encode(utf8.encode(reference)),
            'trans': base64Encode(utf8.encode(translation)),
          });
        }),
      ),
      cache: cache,
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'finds and aligns QQ translations without changing original timestamps',
    () async {
      final found = await source.find(query, originals);
      expect(found.networkError, isFalse);
      expect(found.lines!.map((l) => l.words), ['门上悬着纸星星', '雨中画个圆', '门边留一盏灯']);
      expect(found.lines!.map((l) => l.startTimeMs), [1000, 4000, 7000]);
      expect(calls, hasLength(3));
    },
  );

  test(
    'cached translations are realigned and explicit refresh clears them',
    () async {
      await source.find(query, originals);
      expect(await cache.count(), 1);
      calls.clear();
      await source.find(query, originals);
      expect(calls, isEmpty);
      await source.forget(query);
      await source.find(query, originals);
      expect(calls, hasLength(3));
    },
  );

  test('an exact title wins over a normalized live/remix candidate', () async {
    searchSongs = [
      {'id': 43, 'name': 'Paper Stars - Live', 'singer': artist},
      {'id': 42, 'name': 'Paper Stars', 'singer': artist},
    ];
    expect((await source.find(query, originals)).lines, isNotNull);
    expect(detailIds, [42]);
  });

  test('joined QQ originals retain the current split-line alignment', () async {
    reference =
        '[00:02.00]Paper stars above the gate Draw a circle in the rain Leave a lantern by the door';
    translation = '[00:02.00]门上悬着纸星星 雨中画个圆 门边留一盏灯';
    final found = await source.find(query, originals);
    expect(found.lines?.map((line) => line.words), [
      '门上悬着纸星星',
      '雨中画个圆',
      '门边留一盏灯',
    ]);
    expect(found.lines?.map((line) => line.startTimeMs), [1000, 4000, 7000]);
  });

  test('a confirmed missing translation is cached', () async {
    translation = '';
    expect((await source.find(query, originals)).lines, isNull);
    calls.clear();
    expect((await source.find(query, originals)).lines, isNull);
    expect(calls, isEmpty);
  });

  test(
    'clearing the cache during a lookup prevents late cache writes',
    () async {
      lyricGate = Completer<void>();
      lyricStarted = Completer<void>();
      final pending = source.find(query, originals);
      await lyricStarted!.future;
      await cache.clear();
      lyricGate!.complete();
      expect((await pending).lines, isNotNull);
      expect(await cache.count(), 0);
    },
  );

  test(
    'network failures are not cached or followed by another search',
    () async {
      status = 500;
      expect((await source.find(query, originals)).networkError, isTrue);
      expect(await cache.count(), 0);
      expect(calls, hasLength(1));
      status = 200;
      expect((await source.find(query, originals)).lines, isNotNull);
    },
  );

  test('wrong artist and different duration are rejected', () async {
    artist = 'Other Singer';
    expect((await source.find(query, originals)).lines, isNull);
    expect(calls.where((host) => host == 'u.y.qq.com'), isEmpty);
    await source.forget(query);
    calls.clear();
    artist = 'Test Artist';
    duration = 140;
    expect((await source.find(query, originals)).lines, isNull);
    expect(calls, hasLength(2));
  });

  test(
    'unrelated originals with matching timestamps must not produce a translation',
    () async {
      reference =
          '[00:02.00]Different words\n[00:05.00]Unrelated song\n[00:08.00]Wrong lyrics';
      expect((await source.find(query, originals)).lines, isNull);
    },
  );

  test(
    'non-Chinese translations and untranslated responses are rejected',
    () async {
      translation = lrc;
      expect((await source.find(query, originals)).lines, isNull);
    },
  );

  test(
    'Chinese originals and empty lyrics do not trigger QQ requests',
    () async {
      await source.find(query, []);
      await source.find(query, const [
        LyricLine(startTimeMs: 0, words: '这是一句中文歌词'),
      ]);
      expect(calls, isEmpty);
    },
  );
}
