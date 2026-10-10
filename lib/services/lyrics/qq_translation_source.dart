import 'dart:convert';

import '../../models/lyrics.dart';
import '../../models/lyrics_query.dart';
import 'artist_match.dart';
import 'lrc_parser.dart';
import 'lyrics_disk_cache.dart';
import 'lyrics_language.dart';
import 'netease_translation_source.dart';
import 'qq_music_client.dart';
import 'translation_source.dart';

/// Anonymous Chinese translations only; never replaces the original lyrics.
/// Quick search is followed by a detail check because its candidates lack
/// duration and song type. Source LRC text must also match the original lines.
class QqTranslationSource implements TranslationSource {
  final QqMusicClient _client;
  @override
  final LyricsDiskCache? cache;

  QqTranslationSource(this._client, {this.cache});

  @override
  LyricsProvider get provider => LyricsProvider.qqMusic;

  static String cacheKey(LyricsQuery query) =>
      'qqmusic|v2|${query.trackId.isNotEmpty ? query.trackId : jsonEncode([query.title, query.artist, query.durationMs])}';

  @override
  Future<void> forget(LyricsQuery query) async =>
      cache?.remove(cacheKey(query));

  @override
  Future<TranslationSourceLookup> find(
    LyricsQuery query,
    List<LyricLine> originals,
  ) async {
    if (originals.isEmpty ||
        query.title.trim().isEmpty ||
        query.artist.trim().isEmpty ||
        !NeteaseTranslationSource.needsTranslation(originals)) {
      return const TranslationSourceLookup(null);
    }
    final generation = cache?.generation;
    final key = cacheKey(query);
    final raw = await cache?.read(key);
    var bundle = raw == null ? null : QqMusicLyrics.decode(raw);
    if (bundle == null) {
      final result = await _findBundle(query);
      if (result.networkError || result.value == null) {
        return TranslationSourceLookup(null, networkError: result.networkError);
      }
      bundle = result.value!;
      await cache?.write(key, bundle.encode(), expectedGeneration: generation);
    }
    if (bundle.tlyric.isEmpty || !_hasTextAnchors(bundle.lrc, originals)) {
      return const TranslationSourceLookup(null);
    }
    // The existing alignment handles offsets, repeated choruses, and duplicate
    // timestamps. QQ adds a text-overlap gate so timing alone cannot match a song.
    final lines = NeteaseTranslationSource.align(
      bundle.lrc,
      bundle.tlyric,
      originals,
    );
    if (lines == null ||
        !LyricsLanguage.of(
          'und',
          lines.map((l) => l.words).join('\n'),
        ).startsWith('zh')) {
      return const TranslationSourceLookup(null);
    }
    return TranslationSourceLookup(lines);
  }

  Future<QqMusicResult<QqMusicLyrics>> _findBundle(LyricsQuery query) async {
    final title = NeteaseTranslationSource.baseTitle(query.title);
    QqMusicSong? candidate;
    for (final keyword in {'$title ${query.primaryArtist}'.trim(), title}) {
      final found = await _client.search(keyword);
      if (found.networkError) {
        return const QqMusicResult(null, networkError: true);
      }
      final matches = (found.value ?? [])
          .where((song) => _matches(song, query))
          .toList();
      // Prefer a matching artist, then the exact requested version over a
      // normalized Live/Remix title. Smartbox itself provides no duration.
      matches.sort((a, b) => _rank(b, query).compareTo(_rank(a, query)));
      if (matches.isNotEmpty) {
        candidate = matches.first;
        break;
      }
    }
    if (candidate == null) return const QqMusicResult(QqMusicLyrics());
    final detail = await _client.detail(candidate.id);
    if (detail.networkError || detail.value == null) {
      return const QqMusicResult(null, networkError: true);
    }
    final song = detail.value!;
    if (!_matches(song, query) ||
        (query.durationMs > 0 &&
            (song.durationMs - query.durationMs).abs() > 5000)) {
      return const QqMusicResult(QqMusicLyrics());
    }
    return _client.lyric(song.id, songType: song.songType);
  }

  static int _rank(QqMusicSong song, LyricsQuery query) {
    final artist =
        ArtistMatcher.compare(query.artist, song.artists) == ArtistMatch.match
        ? 4
        : 0;
    final title =
        song.title.trim().toLowerCase() == query.title.trim().toLowerCase()
        ? 2
        : (NeteaseTranslationSource.baseTitle(song.title) == song.title.trim()
              ? 1
              : 0);
    return artist + title;
  }

  static bool _matches(QqMusicSong song, LyricsQuery query) =>
      NeteaseTranslationSource.baseTitle(song.title).toLowerCase() ==
          NeteaseTranslationSource.baseTitle(query.title).toLowerCase() &&
      ArtistMatcher.compare(query.artist, song.artists) != ArtistMatch.mismatch;

  static bool _hasTextAnchors(String lrc, List<LyricLine> originals) {
    String normalize(String text) => text.toLowerCase().replaceAll(
      RegExp(r'[^\p{L}\p{N}]', unicode: true),
      '',
    );
    final reference = LrcParser.parse(lrc)
        .map((line) => normalize(line.words))
        .where((text) => text.isNotEmpty)
        .toSet();
    final texts = originals.map((line) => normalize(line.words)).toList();
    final count = texts.where((text) => text.isNotEmpty).length;
    final anchored = <int>{};
    for (var start = 0; start < texts.length; start++) {
      var joined = '';
      // Match the same bounded, adjacent spans accepted by the alignment. Do
      // not join across interludes or allow timestamps alone to identify a song.
      for (var end = start; end < texts.length && end < start + 3; end++) {
        if (texts[end].isEmpty ||
            originals[end].startTimeMs - originals[start].startTimeMs > 10000) {
          break;
        }
        joined += texts[end];
        if (reference.contains(joined)) {
          anchored.addAll([for (var i = start; i <= end; i++) i]);
        }
      }
    }
    return count > 0 && anchored.length >= count * 0.4;
  }
}
