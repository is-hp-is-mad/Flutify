import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/widgets/track_tile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

/// 长歌单滚动性能的结构性守护（只用合成数据）：
/// - 未悬停的行不构建 IconButton（每个 IconButton 带 Tooltip / Focus / Ink 一整套组件）；
/// - 曲目列表定高，所有行同高；
/// - 触控板连续滑动 2000 首的歌单不出异常，悬停后按钮照常出现。
void main() {
  final playlist = SpotifyPlaylist(
    id: 'synthetic-long-playlist',
    name: 'Synthetic Long Playlist',
    ownerName: 'Tester',
    tracks: List.generate(
      2000,
      (i) => SpotifyTrack(id: 'synthetic${'$i'.padLeft(13, '0')}', name: 'Synthetic Track $i', durationMs: 150000 + i),
    ),
    totalTracks: 2000,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openLongPlaylist(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
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

  Finder rowButtons([Finder? of]) =>
      find.descendant(of: of ?? find.byType(TrackTile), matching: find.byType(IconButton));

  testWidgets('desktop: idle rows build no IconButtons and share one fixed height', (tester) async {
    await openLongPlaylist(tester);

    expect(find.byType(TrackTile), findsWidgets);
    expect(rowButtons(), findsNothing);
    final heights = find.byType(TrackTile).evaluate().map((e) => e.size!.height).toSet();
    expect(heights, hasLength(1));
  });

  testWidgets('desktop: trackpad scrolling deep into a long playlist stays error-free', (tester) async {
    await openLongPlaylist(tester);
    final list = find.byType(CustomScrollView).last;
    final center = tester.getCenter(list);

    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(center));
    var pan = Offset.zero;
    for (var frame = 0; frame < 200; frame++) {
      pan += const Offset(0, -40);
      await tester.sendEventToBinding(pointer.panZoomUpdate(center, pan: pan));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await settle(tester);

    expect(tester.takeException(), isNull);
    // 200 帧 × 40px 远超前几十行：确认真的滚到了深处
    expect(find.text('Synthetic Track 0'), findsNothing);
    expect(rowButtons(), findsNothing);

    // 悬停任意一行：爱心与「⋯」两个真按钮出现
    final row = find.byType(TrackTile).at(3);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row));
    await settle(tester);
    expect(rowButtons(row), findsNWidgets(2));
  });
}
