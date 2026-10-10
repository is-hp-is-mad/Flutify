// Opt-in live smoke test. Run: flutter test tool/lyrics/qq_music_probe.dart
// Outputs metadata/counts only: no credentials or lyric text is logged or saved.
import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/services/lyrics/lrc_parser.dart';
import 'package:flutify_app/services/lyrics/qq_music_client.dart';
import 'package:flutify_app/services/lyrics/qq_translation_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('anonymous QQ bilingual lyric smoke test', () async {
    await probe(['Love Story Taylor Swift', 'Lemon 米津玄師']);
  });
}

Future<void> probe(List<String> args) async {
  final transport = http.Client();
  final client = QqMusicClient(transport);
  try {
    for (final keyword
        in args.isEmpty ? ['Love Story Taylor Swift', 'Lemon 米津玄師'] : args) {
      final watch = Stopwatch()..start();
      final search = await client.search(keyword);
      final candidates = search.value;
      if (candidates == null || candidates.isEmpty) {
        stdout.writeln(
          jsonEncode({
            'query': keyword,
            'stage': 'search',
            'networkError': search.networkError,
          }),
        );
        fail('QQ search unavailable for $keyword');
      }
      final song = (await client.detail(candidates.first.id)).value;
      if (song == null) {
        fail('QQ detail unavailable for $keyword');
      }
      final bundle = (await client.lyric(
        song.id,
        songType: song.songType,
      )).value;
      if (bundle == null) {
        fail('QQ lyrics unavailable for $keyword');
      }
      var reference = bundle.lrc;
      var referenceSource = 'QQ';
      // Also check a real cross-provider timeline, not only QQ against itself.
      if (song.artists == 'Taylor Swift' && song.title == 'Love Story') {
        final response = await transport
            .get(
              Uri.https('lrclib.net', '/api/get', {
                'track_name': song.title,
                'artist_name': song.artists,
                'duration': '${song.durationMs ~/ 1000}',
              }),
            )
            .timeout(const Duration(seconds: 8));
        expect(response.statusCode, 200);
        final text = jsonDecode(
          utf8.decode(response.bodyBytes),
        )['syncedLyrics'];
        expect(text, isA<String>());
        reference = text as String;
        referenceSource = 'LRCLIB';
      }
      final originals = LrcParser.parse(reference);
      final query = LyricsQuery(
        trackId: '',
        title: song.title,
        artist: song.artists,
        durationMs: song.durationMs,
      );
      final found = await QqTranslationSource(client).find(query, originals);
      final translated =
          found.lines?.where((line) => line.words.trim().isNotEmpty).length ??
          0;
      stdout.writeln(
        jsonEncode({
          'query': keyword,
          'qqId': song.id,
          'songType': song.songType,
          'originalSource': referenceSource,
          'originalLines': originals.length,
          'translatedLines': translated,
          'networkError': found.networkError,
          'elapsedMs': watch.elapsedMilliseconds,
        }),
      );
      expect(translated, greaterThan(0), reason: keyword);
    }
  } finally {
    transport.close();
  }
}
