import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
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

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: SpotifyApiService(storage.auth),
      ),
    );
    await settle(tester);
    AppRoutes.openPlaylist(tester.element(find.byType(MainShell)), playlist);
    await settle(tester);
  }

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
    await tester.tap(find.byTooltip(zh.trackSearchHint));
    await settle(tester);

    final field = find.byType(TextField).last;
    final size = tester.getSize(field);
    expect(size.width, greaterThan(180), reason: '手机竖屏下输入框应铺满工具行，不再是几十像素的小框');
    expect(size.height, greaterThanOrEqualTo(44), reason: '触控目标不小于 44');

    // 真的点得进去、输得了字
    await tester.tap(field);
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
