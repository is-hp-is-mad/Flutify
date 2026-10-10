import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/lyrics/lrclib_client.dart';
import 'package:flutify_app/services/lyrics/lrclib_lyrics_source.dart';
import 'package:flutify_app/services/lyrics/lyrics_disk_cache.dart';
import 'package:flutify_app/services/lyrics/lyrics_resolver.dart';
import 'package:flutify_app/services/lyrics/netease_client.dart';
import 'package:flutify_app/services/lyrics/netease_translation_source.dart';
import 'package:flutify_app/services/lyrics/qq_music_client.dart';
import 'package:flutify_app/services/lyrics/qq_translation_source.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/sample_catalog.dart';

/// 用内存 HTTP 替身代替网络：搜索按关键字返回合成曲目，歌词按曲目 id 返回合成歌词。
void main() {
  late SpotifyProvider spotify;
  late StorageService storage;
  late List<Uri> requests;
  var lyricsStatus = 200;

  http.Response handle(http.Request req) {
    requests.add(req.url);
    final path = req.url.path;
    if (path.contains('/color-lyrics/')) {
      if (lyricsStatus != 200) return http.Response('', lyricsStatus);
      return http.Response(
        jsonEncode({
          'lyrics': {
            'syncType': 'LINE_SYNCED',
            'lines': [
              {'startTimeMs': '1000', 'words': 'first line'},
              {'startTimeMs': '2000', 'words': 'second line'},
            ],
          },
        }),
        200,
      );
    }
    if (path.endsWith('/search')) {
      final q = req.url.queryParameters['q'] ?? '';
      final track = q.contains('two')
          ? SampleCatalog.track2
          : SampleCatalog.track1;
      return http.Response(
        jsonEncode({
          'tracks': {
            'items': [
              {
                'id': track.id,
                'name': track.name,
                'uri': track.uri,
                'artists': <dynamic>[],
              },
            ],
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 404);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    await storage.setAccessToken('test-token'); // 合成令牌：仅用于让服务走「已配置」分支
    requests = [];
    lyricsStatus = 200;
    spotify = SpotifyProvider(
      SpotifyApiService(storage, MockClient((req) async => handle(req))),
      storage,
    );
  });

  tearDown(() => spotify.dispose());

  test('rapid typing only applies the latest query', () async {
    spotify.performSearch('o');
    spotify.performSearch('on');
    spotify.performSearch('two');
    expect(spotify.isSearching, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(spotify.isSearching, isFalse);
    expect(spotify.searchTracks.map((t) => t.id), [SampleCatalog.track2.id]);
    expect(
      requests.where((u) => u.path.endsWith('/search')),
      hasLength(1),
      reason: '防抖后只发一次请求',
    );
  });

  test('未登录（无令牌）时搜索返回空结果，不发请求', () async {
    await storage.setAccessToken('');

    spotify.performSearch('anything');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(spotify.searchTracks, isEmpty);
    expect(requests.where((u) => u.path.endsWith('/search')), isEmpty);
  });

  test('recent searches are deduplicated and persisted', () {
    spotify.commitRecentSearch('weeknd');
    spotify.commitRecentSearch('dua');
    spotify.commitRecentSearch('weeknd');

    expect(spotify.recentSearches, ['weeknd', 'dua']);
    expect(storage.recentSearches, ['weeknd', 'dua']);
  });

  test('lyrics are cached after the first fetch', () async {
    final id = SampleCatalog.track1.id;
    final query = LyricsQuery.fromTrack(SampleCatalog.track1);
    expect(spotify.cachedLyrics(id), isNull);

    final lyrics = await spotify.fetchLyrics(query);
    expect(lyrics.lines.map((l) => l.words), ['first line', 'second line']);
    expect(identical(spotify.cachedLyrics(id), lyrics), isTrue);

    await spotify.fetchLyrics(query);
    expect(
      requests.where((u) => u.path.contains('/color-lyrics/')),
      hasLength(1),
    );
  });

  test('歌词写入缓存时通知曲目 ID；失败不通知', () async {
    final cached = <String>[];
    final sub = spotify.lyricsCached.listen(cached.add);
    await spotify.fetchLyrics(LyricsQuery.fromTrack(SampleCatalog.track1));
    lyricsStatus = 503;
    await spotify.fetchLyrics(LyricsQuery.fromTrack(SampleCatalog.track3));
    await Future<void>.delayed(Duration.zero);
    expect(cached, [SampleCatalog.track1.id]);
    await sub.cancel();
  });

  test('没有歌词（404）也会缓存为空歌词', () async {
    lyricsStatus = 404;
    final id = SampleCatalog.track2.id;
    final query = LyricsQuery.fromTrack(SampleCatalog.track2);

    final lyrics = await spotify.fetchLyrics(query);

    expect(lyrics.lines, isEmpty);
    expect(spotify.cachedLyrics(id), isNotNull);
  });

  test('歌词请求失败（5xx）返回空歌词但不缓存，下次会重试', () async {
    lyricsStatus = 503;
    final id = SampleCatalog.track3.id;
    final query = LyricsQuery.fromTrack(SampleCatalog.track3);

    final failed = await spotify.fetchLyrics(query);
    expect(failed.lines, isEmpty);
    expect(spotify.cachedLyrics(id), isNull);

    lyricsStatus = 200;
    final retried = await spotify.fetchLyrics(query);
    expect(retried.lines, hasLength(2));
  });

  group('LRCLIB 补全', () {
    late SpotifyProvider withFallback;
    var fallbackOn = true;
    var lrclibCalls = 0;

    // 合成 LRCLIB：/api/get 返回一份同步歌词，其余接口返回空
    http.Response lrclib(http.Request req) {
      lrclibCalls++;
      if (req.url.path.endsWith('/get')) {
        return http.Response(
          jsonEncode({
            'id': 1,
            'trackName': req.url.queryParameters['track_name'],
            'artistName': req.url.queryParameters['artist_name'],
            'syncedLyrics': '[00:01.00]synthetic one\n[00:02.50]synthetic two',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('[]', 200);
    }

    setUp(() {
      fallbackOn = true;
      lrclibCalls = 0;
      final api = SpotifyApiService(
        storage,
        MockClient((req) async => handle(req)),
      );
      withFallback = SpotifyProvider(
        api,
        storage,
        lyrics: LyricsResolver(
          api.getLyrics,
          fallback: LrclibLyricsSource(
            LrclibClient(
              MockClient((req) async => lrclib(req)),
              sleep: (_) async {},
            ),
            sleep: (_) async {},
          ),
          fallbackEnabled: () => fallbackOn,
        ),
      );
    });

    tearDown(() => withFallback.dispose());

    test('官方有逐行同步歌词时不查 LRCLIB', () async {
      final lyrics = await withFallback.fetchLyrics(
        LyricsQuery.fromTrack(SampleCatalog.track1),
      );
      expect(lyrics.provider, LyricsProvider.spotify);
      expect(lrclibCalls, 0);
    });

    test('官方没有歌词时用 LRCLIB 补全并缓存', () async {
      lyricsStatus = 404;
      final query = LyricsQuery.fromTrack(SampleCatalog.track2);
      final lyrics = await withFallback.fetchLyrics(query);
      expect(lyrics.provider, LyricsProvider.lrclib);
      expect(lyrics.lines.map((l) => l.words), [
        'synthetic one',
        'synthetic two',
      ]);
      expect(lyrics.lines.map((l) => l.startTimeMs), [1000, 2500]);
      expect(withFallback.cachedLyrics(query.trackId), same(lyrics));
    });

    test('关闭补全后保持官方结果', () async {
      lyricsStatus = 404;
      fallbackOn = false;
      final lyrics = await withFallback.fetchLyrics(
        LyricsQuery.fromTrack(SampleCatalog.track3),
      );
      expect(lyrics.lines, isEmpty);
      expect(lrclibCalls, 0);
    });
  });

  group('双语歌词：网易云译文与作废内存歌词', () {
    late Directory dir;
    late LyricsDiskCache lrclibCache;
    late LyricsDiskCache translationCache;
    late SpotifyProvider bilingual;
    late List<Uri> neteaseRequests;
    var translationOn = false;
    final query = LyricsQuery.fromTrack(SampleCatalog.track1);

    // 合成网易云：搜到 Track One，原文 / 译文时间轴与合成的官方歌词一致
    http.Response netease(http.Request req) {
      neteaseRequests.add(req.url);
      final body = req.url.path.contains('search')
          ? {
              'result': {
                'songs': [
                  {
                    'id': 1,
                    'name': 'Track One',
                    'artists': [
                      {'name': 'Artist A'},
                    ],
                    'duration': 180000,
                  },
                ],
              },
            }
          : {
              'code': 200,
              'lrc': {'lyric': '[00:01.00]first line\n[00:02.00]second line'},
              'tlyric': {'lyric': '[00:01.00]第一行\n[00:02.00]第二行'},
            };
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('flutify_bilingual_test');
      lrclibCache = LyricsDiskCache(
        Directory('${dir.path}${Platform.pathSeparator}lrc'),
      );
      translationCache = LyricsDiskCache(
        Directory('${dir.path}${Platform.pathSeparator}translation'),
      );
      neteaseRequests = [];
      translationOn = false;
      final api = SpotifyApiService(
        storage,
        MockClient((req) async => handle(req)),
      );
      bilingual = SpotifyProvider(
        api,
        storage,
        lyrics: LyricsResolver(
          api.getLyrics,
          fallback: LrclibLyricsSource(
            LrclibClient(
              MockClient((_) async => http.Response('[]', 200)),
              sleep: (_) async {},
            ),
            cache: lrclibCache,
            sleep: (_) async {},
          ),
          translation: NeteaseTranslationSource(
            NeteaseClient(
              MockClient((req) async => netease(req)),
              sleep: (_) async {},
            ),
            cache: translationCache,
            sleep: (_) async {},
          ),
          translationEnabled: () => translationOn,
        ),
      );
    });

    tearDown(() {
      bilingual.dispose();
      dir.deleteSync(recursive: true);
    });

    test('clearLyricsCache invalidates QQ and NetEase disk caches', () async {
      final qqCache = LyricsDiskCache(Directory('${dir.path}/qq'));
      final qq = QqTranslationSource(
        QqMusicClient(MockClient((_) async => http.Response('', 500))),
        cache: qqCache,
      );
      final ne = NeteaseTranslationSource(
        NeteaseClient(MockClient((req) async => netease(req))),
        cache: translationCache,
      );
      final provider = SpotifyProvider(
        SpotifyApiService(storage, MockClient((req) async => handle(req))),
        storage,
        lyrics: LyricsResolver(
          (_) async => const SpotifyLyrics(),
          qqTranslation: qq,
          translation: ne,
        ),
      );
      addTearDown(provider.dispose);
      await qqCache.write('qq-entry', 'cached');
      await translationCache.write('netease-entry', 'cached');
      await provider.clearLyricsCache();
      expect(await qqCache.count(), 0);
      expect(await translationCache.count(), 0);
      expect(qqCache.generation, 1);
      expect(translationCache.generation, 1);
    });

    test('关闭时不向网易云发请求；打开并作废内存歌词后重新解析，挂上译文', () async {
      final off = await bilingual.fetchLyrics(query);
      expect(off.lines.map((l) => l.translation), ['', '']);
      expect(neteaseRequests, isEmpty, reason: '关闭双语歌词时曲名 / 歌手不能发给网易云');

      translationOn = true;
      // 不作废就仍命中关闭期间缓存的结果（没有译文）
      expect(await bilingual.fetchLyrics(query), same(off));
      expect(neteaseRequests, isEmpty);

      bilingual.invalidateResolvedLyrics();
      final on = await bilingual.fetchLyrics(query);
      expect(on.lines.map((l) => l.translation), ['第一行', '第二行']);
      expect(neteaseRequests.map((u) => u.host), everyElement('music.163.com'));
      expect(neteaseRequests, isNotEmpty);
      expect(bilingual.cachedLyrics(query.trackId), same(on));
    });

    test('invalidateResolvedLyrics：递增 generation 并通知、丢掉内存歌词，本地缓存保留', () async {
      await lrclibCache.write('lrclib-entry', '[00:01.00]cached');
      await translationCache.write('netease-entry', '{"lrc":"","tlyric":""}');
      await bilingual.fetchLyrics(query);
      expect(bilingual.cachedLyricsCount, 1);

      // 只数这一次调用里的通知（构造时发出的主页加载可能稍后才通知）
      var notified = 0;
      void listener() => notified++;
      final generation = bilingual.lyricsGeneration;
      bilingual.addListener(listener);
      bilingual.invalidateResolvedLyrics();
      bilingual.removeListener(listener);

      expect(bilingual.lyricsGeneration, generation + 1);
      expect(notified, 1);
      expect(bilingual.cachedLyrics(query.trackId), isNull);
      expect(bilingual.cachedLyricsCount, 0);
      // 清本地缓存是异步删目录（clearLyricsCache）：等一会儿再确认两份本地缓存都还在
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await lrclibCache.count(), 1);
      expect(await translationCache.count(), 1);
    });

    test('作废前发出、晚到的结果照常返回但不写缓存，也不影响作废后新发出的请求', () async {
      final pending = <Completer<SpotifyLyrics>>[];
      final slow = SpotifyProvider(
        SpotifyApiService(storage, MockClient((req) async => handle(req))),
        storage,
        lyrics: LyricsResolver((_) {
          final official = Completer<SpotifyLyrics>();
          pending.add(official);
          return official.future;
        }),
      );
      addTearDown(slow.dispose);
      const stale = SpotifyLyrics(
        lines: [LyricLine(startTimeMs: 0, words: 'stale')],
      );
      const fresh = SpotifyLyrics(
        lines: [LyricLine(startTimeMs: 0, words: 'fresh')],
      );

      final before = slow.fetchLyrics(query);
      slow.invalidateResolvedLyrics();
      final after = slow.fetchLyrics(query);
      expect(pending, hasLength(2), reason: '作废后不能再合并到作废前的请求上');

      pending[0].complete(stale);
      expect(await before, same(stale));
      expect(slow.cachedLyrics(query.trackId), isNull);
      // 旧请求结束时不能把新请求从进行中列表里移除：再取一次仍合并到新请求上
      expect(slow.fetchLyrics(query), same(after));
      expect(pending, hasLength(2));

      pending[1].complete(fresh);
      expect(await after, same(fresh));
      expect(slow.cachedLyrics(query.trackId), same(fresh));
    });
  });
}
