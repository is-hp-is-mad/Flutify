import 'dart:async';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_widgets.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/widgets/cover_image.dart';
import 'package:flutify_app/ui/widgets/track_table/track_table_header.dart';
import 'package:flutify_app/ui/widgets/track_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

/// 歌单页表格（只用合成数据）：列表头 / 专辑与添加日期列、点列名排序、歌单内搜索、紧凑视图。
void main() {
  final zh = lookupAppLocalizations(const Locale('zh'));

  SpotifyTrack track(String name, String album, {int? daysAgo}) => SpotifyTrack(
    id: 'synthetic-$name',
    name: name,
    artists: [SpotifyArtist(id: 'a-$name', name: 'Artist $name')],
    album: SpotifyAlbum(id: 'al-$album', name: album),
    durationMs: 180000,
    addedAt: daysAgo == null ? null : DateTime.now().subtract(Duration(days: daysAgo)),
  );

  final playlist = SpotifyPlaylist(
    id: 'synthetic-table-playlist',
    name: 'Synthetic Table Playlist',
    ownerName: 'Tester',
    tracks: [
      track('Charlie', 'Album Three', daysAgo: 3),
      track('Alpha', 'Album One', daysAgo: 400),
      track('Bravo', 'Album Two'),
    ],
    totalTracks: 3,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester tester,
    Size size, {
    Map<String, Object> initialValues = const {},
    SpotifyPlaylist? target,
    SpotifyApiService Function(StorageService storage)? api,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;
    SharedPreferences.setMockInitialValues(initialValues);
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: api?.call(storage) ?? SpotifyApiService(storage.auth),
      ),
    );
    await settle(tester);
    AppRoutes.openPlaylist(
      tester.element(find.byType(MainShell)),
      target ?? playlist,
    );
    await settle(tester);
  }

  AppPreferences prefsOf(WidgetTester tester) =>
      tester.element(find.byType(MainShell)).read<PreferencesProvider>().prefs;

  /// 当前显示的曲目名（自上而下）。
  List<String> rows(WidgetTester tester) =>
      tester.widgetList<TrackTile>(find.byType(TrackTile)).map((t) => t.track.name).toList();

  Finder header(String label) => find.descendant(of: find.byType(TrackTableHeader), matching: find.text(label));

  testWidgets('wide desktop: header, album and date-added columns', (tester) async {
    await open(tester, const Size(1600, 900));
    expect(header(zh.trackColumnTitle), findsOneWidget);
    expect(header(zh.trackColumnAlbum), findsOneWidget);
    expect(header(zh.trackColumnAddedAt), findsOneWidget);
    expect(find.text('Album Three'), findsOneWidget);
    expect(find.text(zh.addedDaysAgo(3)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clicking a column name sorts, again reverses, third time restores', (tester) async {
    await open(tester, const Size(1600, 900));
    expect(rows(tester), ['Charlie', 'Alpha', 'Bravo']);

    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    expect(rows(tester), ['Alpha', 'Bravo', 'Charlie']);

    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    expect(rows(tester), ['Charlie', 'Bravo', 'Alpha']);

    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    expect(rows(tester), ['Charlie', 'Alpha', 'Bravo']);

    // 添加日期：新 → 旧，没有日期的排最后
    await tester.tap(header(zh.trackColumnAddedAt));
    await settle(tester);
    expect(rows(tester), ['Charlie', 'Alpha', 'Bravo']);
  });

  testWidgets('header sort clicks are remembered per playlist', (tester) async {
    await open(tester, const Size(1600, 900));

    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    expect(prefsOf(tester).playlistTrackSorts, {
      'synthetic-table-playlist': 'title',
    });

    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    expect(prefsOf(tester).playlistTrackSorts, {
      'synthetic-table-playlist': 'title:desc',
    });

    // 第三次回到自定义顺序：条目被删除而不是存 'custom'
    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    expect(prefsOf(tester).playlistTrackSorts, isEmpty);
  });

  testWidgets('remembered sort applies on open, only for that playlist', (
    tester,
  ) async {
    final seeded = AppPreferences.defaults.withPlaylistTrackSort(
      'synthetic-table-playlist',
      'title:desc',
    );
    await open(
      tester,
      const Size(1600, 900),
      initialValues: {'app_prefs': seeded.encode()},
    );
    expect(rows(tester), ['Charlie', 'Bravo', 'Alpha']);

    // 同一批曲目、不同歌单 id：没有记录，按自定义顺序显示
    final other = SpotifyPlaylist(
      id: 'synthetic-other-playlist',
      name: 'Synthetic Other Playlist',
      ownerName: 'Tester',
      tracks: playlist.tracks,
      totalTracks: 3,
    );
    AppRoutes.openPlaylist(tester.element(find.byType(MainShell)), other);
    await settle(tester);
    expect(rows(tester), ['Charlie', 'Alpha', 'Bravo']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved addedAt sort falls back to custom when the playlist has no dates',
    (tester) async {
      final noDates = SpotifyPlaylist(
        id: 'synthetic-no-dates-playlist',
        name: 'Synthetic No Dates Playlist',
        ownerName: 'Tester',
        tracks: [
          track('Charlie', 'Album Three'),
          track('Alpha', 'Album One'),
          track('Bravo', 'Album Two'),
        ],
        totalTracks: 3,
      );
      final seeded = AppPreferences.defaults.withPlaylistTrackSort(
        'synthetic-no-dates-playlist',
        'addedAt:desc',
      );
      await open(
        tester,
        const Size(1600, 900),
        initialValues: {'app_prefs': seeded.encode()},
        target: noDates,
      );

      expect(rows(tester), ['Charlie', 'Alpha', 'Bravo']);
      expect(find.text(zh.trackSortCustom), findsOneWidget);
      // 记录保留：曲目拉到加入时间后仍按「添加日期」排
      expect(
        prefsOf(tester).playlistTrackSorts['synthetic-no-dates-playlist'],
        'addedAt:desc',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('action row play sends the sorted order with a reordered context', (
    tester,
  ) async {
    final seeded = AppPreferences.defaults.withPlaylistTrackSort(
      'synthetic-table-playlist',
      'title',
    );
    await open(
      tester,
      const Size(1600, 900),
      initialValues: {'app_prefs': seeded.encode()},
    );

    (PlaybackContext, List<SpotifyTrack>, SpotifyTrack?)? captured;
    tester.element(find.byType(MainShell)).read<PlaybackProvider>().remotePlay =
        (ctx, tracks, start) async {
          captured = (ctx, tracks, start);
          return true;
        };

    // 操作行的大播放键（收起态标题栏另有一个小号）
    final playButton = find.descendant(
      of: find.byType(CollectionActionRow),
      matching: find.byType(ContextPlayButton),
    );
    await tester.tap(playButton);
    await settle(tester);

    var (ctx, played, start) = captured!;
    expect(played.map((t) => t.name), ['Alpha', 'Bravo', 'Charlie']);
    expect(ctx.reordered, isTrue);
    expect(ctx.uri, playlist.contextUri);
    expect(start, isNull);

    // 排回自定义顺序（title → desc → custom），再点播放是歌单原顺序；
    // remotePlay 接管不改本机播放上下文，按钮仍算「非当前上下文」，再点还是走 playContext
    captured = null;
    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    await tester.tap(header(zh.trackColumnTitle));
    await settle(tester);
    expect(rows(tester), ['Charlie', 'Alpha', 'Bravo']);

    await tester.tap(playButton);
    await settle(tester);
    (ctx, played, start) = captured!;
    expect(played.map((t) => t.name), ['Charlie', 'Alpha', 'Bravo']);
    expect(ctx.reordered, isFalse);
    expect(ctx.uri, playlist.contextUri);
    expect(start, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remembered sort while tracks still stream in: play waits for the full list', (
    tester,
  ) async {
    final seeded = AppPreferences.defaults.withPlaylistTrackSort(
      'synthetic-table-playlist',
      'title',
    );
    late _StreamingPlaylistApi streaming;
    await open(
      tester,
      const Size(1600, 900),
      initialValues: {'app_prefs': seeded.encode()},
      api: (storage) => streaming = _StreamingPlaylistApi(storage),
    );

    // 首批只到两首（总共 3 首），还在拉取
    streaming.pages.add(
      playlist.copyWith(tracks: playlist.tracks.take(2).toList()),
    );
    await settle(tester);
    expect(rows(tester), ['Alpha', 'Charlie']);

    (PlaybackContext, List<SpotifyTrack>, SpotifyTrack?)? captured;
    tester.element(find.byType(MainShell)).read<PlaybackProvider>().remotePlay =
        (ctx, tracks, start) async {
          captured = (ctx, tracks, start);
          return true;
        };

    await tester.tap(
      find.descendant(
        of: find.byType(CollectionActionRow),
        matching: find.byType(ContextPlayButton),
      ),
    );
    await settle(tester);
    // 没拉完不播：否则只排了已加载的两首
    expect(captured, isNull);

    streaming.pages.add(playlist);
    await streaming.pages.close();
    await settle(tester);

    final (ctx, played, start) = captured!;
    expect(played.map((t) => t.name), ['Alpha', 'Bravo', 'Charlie']);
    expect(ctx.reordered, isTrue);
    expect(start, isNull);
    expect(tester.takeException(), isNull);
  });

  Finder actionPlay() => find.descendant(
    of: find.byType(CollectionActionRow),
    matching: find.byType(ContextPlayButton),
  );

  (PlaybackContext, List<SpotifyTrack>, SpotifyTrack?)? Function() capturePlays(WidgetTester tester) {
    (PlaybackContext, List<SpotifyTrack>, SpotifyTrack?)? captured;
    tester.element(find.byType(MainShell)).read<PlaybackProvider>().remotePlay =
        (ctx, tracks, start) async {
          captured = (ctx, tracks, start);
          return true;
        };
    return () => captured;
  }

  testWidgets('cached snapshot still refreshing: play waits and uses the refreshed playlist', (
    tester,
  ) async {
    // 没记排序（自定义顺序）也要等：缓存的旧快照可能和服务端的歌单顺序、曲目不同
    late _StreamingPlaylistApi streaming;
    await open(
      tester,
      const Size(1600, 900),
      api: (storage) => streaming = _StreamingPlaylistApi(storage),
    );
    expect(rows(tester), ['Charlie', 'Alpha', 'Bravo']);
    final captured = capturePlays(tester);

    await tester.tap(actionPlay());
    await settle(tester);
    expect(captured(), isNull);
    // 等待中播放键转圈
    expect(
      find.descendant(of: actionPlay(), matching: find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );

    // 服务端的歌单换了顺序、多了一首
    final refreshed = playlist.copyWith(
      tracks: [playlist.tracks[2], track('Delta', 'Album Four'), playlist.tracks[0], playlist.tracks[1]],
      totalTracks: 4,
    );
    streaming.pages.add(refreshed);
    await streaming.pages.close();
    await settle(tester);

    final (ctx, played, start) = captured()!;
    expect(played.map((t) => t.name), ['Bravo', 'Delta', 'Charlie', 'Alpha']);
    expect(ctx.reordered, isFalse);
    expect(start, isNull);
    expect(
      find.descendant(of: actionPlay(), matching: find.byType(CircularProgressIndicator)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a song while refreshing starts it in the refreshed queue', (tester) async {
    late _StreamingPlaylistApi streaming;
    await open(
      tester,
      const Size(1600, 900),
      api: (storage) => streaming = _StreamingPlaylistApi(storage),
    );
    final captured = capturePlays(tester);

    await tester.tap(find.text('Alpha'));
    await settle(tester);
    expect(captured(), isNull);

    final refreshed = playlist.copyWith(
      tracks: [playlist.tracks[1], playlist.tracks[2], playlist.tracks[0]],
    );
    streaming.pages.add(refreshed);
    await streaming.pages.close();
    await settle(tester);

    final (_, played, start) = captured()!;
    expect(played.map((t) => t.name), ['Alpha', 'Bravo', 'Charlie']);
    expect(start?.name, 'Alpha');
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh fails: play falls back to the cached snapshot with a notice', (tester) async {
    late _StreamingPlaylistApi streaming;
    await open(
      tester,
      const Size(1600, 900),
      api: (storage) => streaming = _StreamingPlaylistApi(storage),
    );
    final captured = capturePlays(tester);

    await tester.tap(actionPlay());
    await settle(tester);
    expect(captured(), isNull);

    streaming.pages.addError(Exception('offline'));
    await streaming.pages.close();
    await settle(tester);

    final (_, played, _) = captured()!;
    expect(played.map((t) => t.name), ['Charlie', 'Alpha', 'Bravo']);
    expect(find.text(zh.playlistPlayingCachedCopy), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-playlist search filters rows and explains empty results', (tester) async {
    await open(tester, const Size(1600, 900));
    await tester.tap(find.byTooltip(zh.trackSearchHint));
    await settle(tester);

    await tester.enterText(find.byType(TextField).last, 'album two');
    await settle(tester);
    expect(rows(tester), ['Bravo']);

    await tester.enterText(find.byType(TextField).last, 'zzz');
    await settle(tester);
    expect(rows(tester), isEmpty);
    expect(find.text(zh.trackSearchNoResults('zzz')), findsOneWidget);

    await tester.tap(find.byTooltip(zh.trackSearchClose));
    await settle(tester);
    expect(rows(tester), hasLength(3));
  });

  testWidgets('phone portrait: in-playlist search opens a full-width, tappable field', (tester) async {
    await open(tester, const Size(390, 844));

    // 收起的工具（🔍 + 排序键）就在播放键那一行：与播放键纵向居中、在它的左边
    final playButton = find.descendant(
      of: find.byType(CollectionActionRow),
      matching: find.byType(ContextPlayButton),
    );
    final playRect = tester.getRect(playButton);
    for (final f in [
      find.byTooltip(zh.trackSearchHint),
      find.text(zh.trackSortCustom),
    ]) {
      final r = tester.getRect(f);
      expect(
        (r.center.dy - playRect.center.dy).abs(),
        lessThan(4),
        reason: '收起的工具应与播放键同一行（纵向居中）',
      );
      expect(
        r.right,
        lessThanOrEqualTo(playRect.left + 1),
        reason: '收起的工具应在播放键左侧',
      );
    }

    await tester.tap(find.byTooltip(zh.trackSearchHint));
    await settle(tester);

    final field = find.byType(TextField).last;
    final size = tester.getSize(field);
    expect(size.width, greaterThan(180), reason: '手机竖屏下输入框应铺满工具行，不再是几十像素的小框');
    expect(size.height, greaterThanOrEqualTo(44), reason: '触控目标不小于 44');
    // 展开的输入框单独一行：顶边在播放键底边之下
    expect(
      tester.getRect(field).top,
      greaterThanOrEqualTo(playRect.bottom),
      reason: '展开的输入框应单独一行，排在播放键下面',
    );

    // 真的点得进去、输得了字
    await tester.tap(field);
    await tester.enterText(field, 'bravo');
    await settle(tester);
    expect(rows(tester), ['Bravo']);

    // 收起后工具回到播放键那一行
    await tester.tap(find.byTooltip(zh.trackSearchClose));
    await settle(tester);
    final back = tester.getRect(find.byTooltip(zh.trackSearchHint));
    expect(
      (back.center.dy - tester.getRect(playButton).center.dy).abs(),
      lessThan(4),
      reason: '收起搜索后工具应回到播放键那一行',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow phone: collapsed tools share the play row, search expands full-width', (tester) async {
    await open(tester, const Size(360, 780));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip(zh.trackSearchHint));
    await settle(tester);
    final field = find.byType(TextField).last;
    final size = tester.getSize(field);
    expect(size.width, greaterThan(180), reason: '输入框独占一行铺满宽度');
    expect(size.height, greaterThanOrEqualTo(44), reason: '触控目标不小于 44');

    await tester.enterText(field, 'bravo');
    await settle(tester);
    expect(rows(tester), ['Bravo']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact view: no covers, artist column, remembered', (tester) async {
    await open(tester, const Size(1600, 900));
    expect(find.descendant(of: find.byType(TrackTile), matching: find.byType(CoverImage)), findsWidgets);

    await tester.tap(find.text(zh.trackSortCustom));
    await settle(tester);
    await tester.tap(find.text(zh.trackViewCompact));
    await settle(tester);

    expect(find.descendant(of: find.byType(TrackTile), matching: find.byType(CoverImage)), findsNothing);
    expect(header(zh.trackColumnArtist), findsOneWidget);
    final prefs = tester.element(find.byType(MainShell)).read<PreferencesProvider>().prefs;
    expect(prefs.compactTrackList, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final width in const [900.0, 1100.0, 1280.0]) {
    testWidgets('no overflow at ${width.round()} wide; extra columns fold away', (tester) async {
      await open(tester, Size(width, 800));
      expect(tester.takeException(), isNull);
      expect(header(zh.trackColumnTitle), findsOneWidget);
    });
  }
}

/// 歌单曲目由测试分批推送（模拟长歌单分页拉取）。
class _StreamingPlaylistApi extends SpotifyApiService {
  _StreamingPlaylistApi(StorageService storage) : super(storage.auth);

  final pages = StreamController<SpotifyPlaylist>();

  @override
  Stream<SpotifyPlaylist> watchPlaylist(String id) => pages.stream;
}
