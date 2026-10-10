import 'dart:async';
import 'dart:convert';

import 'package:flutify_app/services/lyrics/qq_music_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object value) =>
    http.Response(jsonEncode(value), 200);
http.Response rpcResponse(Object data) => jsonResponse({
  'code': 0,
  'request': {'code': 0, 'data': data},
});

void main() {
  test(
    'QQ trailing-semicolon Content-Type does not reject valid JSON',
    () async {
      final body = jsonEncode({
        'code': 0,
        'request': {
          'code': 0,
          'data': {
            'track_info': {
              'id': 42,
              'title': 'Song',
              'interval': 123,
              'type': 0,
              'singer': [
                {'name': 'Artist'},
              ],
            },
          },
        },
      });
      final client = QqMusicClient(
        MockClient.streaming(
          (request, stream) async => http.StreamedResponse(
            Stream.value(utf8.encode(body)),
            200,
            headers: {'content-type': 'text/plain; charset=utf-8;'},
          ),
        ),
      );
      expect((await client.detail(42)).value?.id, 42);
    },
  );

  test('anonymous search validates IDs and parses song candidates', () async {
    final client = QqMusicClient(
      MockClient((request) async {
        expect(request.url.host, 'c.y.qq.com');
        expect(request.url.queryParameters['key'], 'Test Song Artist');
        expect(request.headers['authorization'], isNull);
        expect(request.headers['cookie'], isNull);
        return jsonResponse({
          'code': 0,
          'data': {
            'song': {
              'itemlist': [
                {
                  'id': '42',
                  'mid': 'song-mid',
                  'name': 'Test Song',
                  'singer': 'Artist',
                },
                {'id': 'bad', 'name': 'Test Song'},
              ],
            },
          },
        });
      }),
    );
    final result = await client.search('Test Song Artist');
    expect(result.networkError, isFalse);
    expect(result.value, hasLength(1));
    expect(result.value!.single.id, 42);
    expect(result.value!.single.artists, 'Artist');
  });

  test(
    'details supply duration, artist list and the lyric song type',
    () async {
      final client = QqMusicClient(
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['request']['param'], {'song_id': 42});
          return rpcResponse({
            'track_info': {
              'id': 42,
              'mid': 'song-mid',
              'title': 'Test Song',
              'type': 7,
              'interval': 123,
              'singer': [
                {'name': 'Artist'},
                {'name': 'Guest'},
              ],
            },
          });
        }),
      );
      final song = (await client.detail(42)).value!;
      expect(song.durationMs, 123000);
      expect(song.artists, 'Artist, Guest');
      expect(song.songType, 7);
    },
  );

  test(
    'requests plain LRC and decodes Base64 original and translation',
    () async {
      const original = '[00:01.00]A made-up line\n[00:02.00]Another line';
      const translation = '[00:01.00]虚构的一句\n[00:02.00]另一句';
      final client = QqMusicClient(
        MockClient((request) async {
          final params = jsonDecode(request.body)['request']['param'];
          expect(params['crypt'], 0);
          expect(params['qrc'], 0);
          expect(params['trans'], 1);
          expect(params['songId'], 42);
          expect(params['type'], 7);
          return rpcResponse({
            'lyric': base64Encode(utf8.encode(original)),
            'trans': base64Encode(utf8.encode(translation)),
          });
        }),
      );
      final bundle = (await client.lyric(42, songType: 7)).value!;
      expect(bundle.lrc, original);
      expect(bundle.tlyric, translation);
    },
  );

  test('empty translations are a miss, malformed data is retryable', () async {
    for (final value in ['', 'not base64!', 123]) {
      final client = QqMusicClient(
        MockClient(
          (_) async => rpcResponse({
            'lyric': base64Encode(utf8.encode('[00:01.00]Synthetic line')),
            'trans': value,
          }),
        ),
      );
      final result = await client.lyric(42);
      expect(result.networkError, value != '');
      if (value == '') expect(result.value!.tlyric, isEmpty);
    }
  });

  test(
    'business errors and malformed search schemas are not cached misses',
    () async {
      for (final body in [
        {'code': 2001},
        {'code': 0, 'data': {}},
        {'code': 0, 'data': 7},
        {
          'code': 0,
          'data': {'song': 'unexpected'},
        },
        {
          'code': 0,
          'request': {'code': 2001},
        },
      ]) {
        final client = QqMusicClient(
          MockClient((_) async => jsonResponse(body)),
        );
        expect((await client.search('song')).networkError, isTrue);
      }
    },
  );

  test('Retry-After blocks all QQ paths until the cooldown ends', () async {
    var now = DateTime.utc(2026, 10, 6);
    var calls = 0;
    final client = QqMusicClient(
      MockClient((_) async {
        calls++;
        return http.Response('', 429, headers: {'retry-after': '60'});
      }),
      now: () => now,
    );
    expect((await client.search('song')).networkError, isTrue);
    expect((await client.lyric(42)).networkError, isTrue);
    expect(calls, 1);
    now = now.add(const Duration(seconds: 61));
    await client.detail(42);
    expect(calls, 2);
  });

  test('redirects and oversized responses are rejected', () async {
    for (final status in [302, 200]) {
      final client = QqMusicClient(
        MockClient.streaming((request, _) async {
          expect(request.followRedirects, isFalse);
          return http.StreamedResponse(
            Stream.value(List.filled(QqMusicClient.maxResponseBytes + 1, 32)),
            status,
            headers: {'location': 'https://example.invalid/redirect'},
          );
        }),
      );
      expect((await client.search('song')).networkError, isTrue);
    }
  });

  test('business rejection briefly cools down all QQ endpoints', () async {
    var calls = 0;
    var now = DateTime.utc(2026, 10, 6);
    final client = QqMusicClient(
      MockClient((_) async {
        calls++;
        return jsonResponse({
          'code': 0,
          'request': {'code': 2001},
        });
      }),
      now: () => now,
    );
    expect((await client.detail(42)).networkError, isTrue);
    await client.search('another song');
    expect(calls, 1);
    now = now.add(const Duration(minutes: 1));
    await client.detail(42);
    expect(calls, 2);
  });

  test('a timeout aborts the underlying HTTP request', () async {
    var aborted = false;
    final client = QqMusicClient(
      MockClient.streaming((request, _) async {
        await (request as http.AbortableRequest).abortTrigger;
        aborted = true;
        throw http.RequestAbortedException(request.url);
      }),
      requestTimeout: const Duration(milliseconds: 5),
    );
    expect((await client.search('song')).networkError, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
  });

  test(
    'a timed-out request returns a retryable error without retrying',
    () async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final client = QqMusicClient(
        MockClient((_) {
          calls++;
          return pending.future;
        }),
        requestTimeout: const Duration(milliseconds: 5),
      );
      expect((await client.search('song')).networkError, isTrue);
      expect(calls, 1);
      pending.complete(jsonResponse({'code': 0, 'data': {}}));
    },
  );
}
