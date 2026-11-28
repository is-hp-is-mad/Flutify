import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/proxy_mode.dart';
import 'package:flutify_app/models/playback_state.dart'
    show SpotifyRepeatMode;
import 'package:flutter_test/flutter_test.dart';

/// 偏好的序列化：往返一致；坏数据 / 越界值回退或夹紧，不会导致启动失败。
void main() {
  test('encode / decode round-trips every field', () {
    const prefs = AppPreferences(
      language: AppLanguage.en,
      lyricsScale: 1.2,
      lyricsAlign: LyricsAlign.center,
      startPage: StartPage.last,
      defaultRepeatMode: SpotifyRepeatMode.track,
      rememberWindow: false,
      connectEnabled: false,
      remoteLyricsLeadMs: -300,
      proxyMode: ProxyMode.manual,
      proxyHost: '10.0.0.2',
      proxyPort: 8080,
      proxyUsername: 'alice',
      lyricsFallback: false,
      lyricsAutoTranslate: false,
      lyricsExcludeInterfaceLanguage: false,
      lyricsExcludedLanguages: ['ja', 'fr'],
      canvasEnabled: false,
      lyricsBilingual: true,
      taskbarLyrics: true,
      taskbarLyricsColor: TaskbarLyricsColor.custom,
      taskbarLyricsCustomColor: 0xFF336699,
      taskbarLyricsOpacity: 60,
      librarySort: LibrarySort.alphabetical,
      playlistTrackSorts: {'p1': 'title', 'p2': 'addedAt:desc'},
    );
    expect(AppPreferences.decode(prefs.encode()), prefs);
  });

  test('taskbar lyrics: off by default, bad values are sanitised', () {
    expect(AppPreferences.defaults.taskbarLyrics, isFalse);
    expect(AppPreferences.defaults.lyricsFallback, isTrue);
    final prefs = AppPreferences.fromJson({
      'taskbarLyricsColor': 'rainbow',
      'taskbarLyricsOpacity': 3,
    });
    expect(prefs.taskbarLyricsColor, TaskbarLyricsColor.auto);
    expect(prefs.taskbarLyricsOpacity, AppPreferences.minTaskbarLyricsOpacity);
  });

  test(
    'bilingual lyrics: off by default, missing or bad values decode to off',
    () {
      // 开启后才会把曲名与歌手发给网易云查译文：默认关闭，没有这个键（旧数据）或类型不对都按关闭处理
      expect(AppPreferences.defaults.lyricsBilingual, isFalse);
      expect(AppPreferences.fromJson({}).lyricsBilingual, isFalse);
      expect(
        AppPreferences.decode(
          '{"language": "en", "lyricsFallback": true}',
        ).lyricsBilingual,
        isFalse,
      );
      expect(
        AppPreferences.fromJson({'lyricsBilingual': 'yes'}).lyricsBilingual,
        isFalse,
      );
      expect(
        AppPreferences.fromJson({'lyricsBilingual': true}).lyricsBilingual,
        isTrue,
      );
    },
  );

  test('library sort and per-playlist track sorts: defaults, sanitising, updating', () {
    expect(AppPreferences.defaults.librarySort, LibrarySort.recent);
    expect(AppPreferences.defaults.playlistTrackSorts, isEmpty);

    expect(
      AppPreferences.fromJson({'librarySort': 'nope'}).librarySort,
      LibrarySort.recent,
    );
    expect(
      AppPreferences.fromJson({'librarySort': 'alphabetical'}).librarySort,
      LibrarySort.alphabetical,
    );
    expect(
      AppPreferences.fromJson({'playlistTrackSorts': 'x'}).playlistTrackSorts,
      isEmpty,
    );
    // 只保留键、值都是非空字符串的条目
    expect(
      AppPreferences.fromJson({
        'playlistTrackSorts': {
          'good': 'title',
          '': 'title',
          'badValue': 3,
          'emptyValue': '',
        },
      }).playlistTrackSorts,
      {'good': 'title'},
    );

    // withPlaylistTrackSort：新增 / 覆盖 / null 删除，其他条目不动
    var prefs = AppPreferences.defaults.withPlaylistTrackSort('p1', 'title');
    expect(prefs.playlistTrackSorts, {'p1': 'title'});
    prefs = prefs
        .withPlaylistTrackSort('p1', 'artist:desc')
        .withPlaylistTrackSort('p2', 'addedAt');
    expect(prefs.playlistTrackSorts, {'p1': 'artist:desc', 'p2': 'addedAt'});
    prefs = prefs.withPlaylistTrackSort('p1', null);
    expect(prefs.playlistTrackSorts, {'p2': 'addedAt'});

    // map 相等按内容比较，不受实现类型影响
    expect(
      const AppPreferences(playlistTrackSorts: {'a': 'title'}),
      AppPreferences.fromJson({
        'playlistTrackSorts': {'a': 'title'},
      }),
    );
    expect(
      const AppPreferences(playlistTrackSorts: {'a': 'title'}),
      isNot(const AppPreferences(playlistTrackSorts: {'a': 'artist'})),
    );
  });

  test('proxy fields: unknown mode falls back to system, bad port to 0', () {
    final prefs = AppPreferences.fromJson({
      'proxyMode': 'socks',
      'proxyHost': '  h  ',
      'proxyPort': 70000,
    });
    expect(prefs.proxyMode, ProxyMode.system);
    expect(prefs.proxyHost, 'h');
    expect(prefs.proxyPort, 0);
  });

  test('proxy username: trimmed, wrong type falls back to empty', () {
    expect(
      AppPreferences.fromJson({'proxyUsername': '  bob  '}).proxyUsername,
      'bob',
    );
    expect(AppPreferences.fromJson({'proxyUsername': 42}).proxyUsername, '');
    expect(AppPreferences.defaults.proxyUsername, '');
  });

  test('empty or corrupt data falls back to defaults', () {
    expect(AppPreferences.decode(''), AppPreferences.defaults);
    expect(AppPreferences.decode('{not json'), AppPreferences.defaults);
    expect(AppPreferences.decode('[1, 2]'), AppPreferences.defaults);
  });

  test('unknown enums, wrong types and out-of-range values are sanitised', () {
    final prefs = AppPreferences.fromJson({
      'language': 'klingon',
      'lyricsScale': 9.0,
      'lyricsAlign': 42,
      'defaultRepeatMode': 'forever',
      'startPage': null,
      'rememberWindow': 'yes',
      'connectEnabled': false,
      'remoteLyricsLeadMs': 99999,
    });
    expect(prefs.language, AppPreferences.defaults.language);
    expect(prefs.lyricsScale, AppPreferences.maxLyricsScale);
    expect(prefs.lyricsAlign, LyricsAlign.left);
    expect(prefs.defaultRepeatMode, SpotifyRepeatMode.off);
    expect(prefs.startPage, StartPage.home);
    expect(prefs.rememberWindow, isTrue);
    expect(prefs.connectEnabled, isFalse);
    expect(prefs.remoteLyricsLeadMs, AppPreferences.maxRemoteLyricsLeadMs);
  });

  test('copyWith changes only the given field', () {
    final prefs = AppPreferences.defaults.copyWith(lyricsScale: 0.9);
    expect(prefs.lyricsScale, 0.9);
    expect(prefs.copyWith(lyricsScale: 1.0), AppPreferences.defaults);
  });
}
