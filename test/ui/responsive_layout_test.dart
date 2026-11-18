import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_hero.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_shell.dart';
import 'package:flutify_app/ui/shell/mobile/mobile_bottom_bar.dart';
import 'package:flutify_app/ui/widgets/share/share_sheet.dart';
import 'package:flutify_app/ui/widgets/track_tile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

/// 第 6 步：1440 / 1024 / 390 三个宽度下的外壳与详情页，
/// 以及桌面端曲目行的悬停与右键菜单。只使用合成数据。
void main() {
  final playlist = SpotifyPlaylist(
    id: 'synthetic-playlist',
    name: 'A Rather Long Synthetic Playlist Title For Layout Checks',
    description: 'Only used by widget tests.',
    ownerName: 'Tester',
    tracks: List.generate(
      12,
      (i) => SpotifyTrack(
        id: 'synthetic${'$i'.padLeft(13, '0')}',
        name: 'Synthetic Track $i',
        durationMs: 150000 + i * 1000,
      ),
    ),
    totalTracks: 12,
  );

  Future<void> pumpAt(WidgetTester tester, Size size) async {
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
  }

  Future<void> openPlaylist(WidgetTester tester) async {
    AppRoutes.openPlaylist(tester.element(find.byType(MainShell)), playlist);
    await settle(tester);
  }

  for (final (label, size, desktop) in [
    ('1440', const Size(1440, 900), true),
    ('1024', const Size(1024, 768), true),
    ('390', const Size(390, 844), false),
  ]) {
    testWidgets(
      '$label wide: shell and playlist detail lay out without errors',
      (tester) async {
        await pumpAt(tester, size);
        expect(
          find.byType(DesktopShell),
          desktop ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(MobileBottomBar),
          desktop ? findsNothing : findsOneWidget,
        );

        await openPlaylist(tester);
        expect(find.byType(CollectionHero), findsOneWidget);
        expect(find.byType(TrackTile), findsWidgets);

        // 滚动到吸顶状态再回来，期间不应有布局异常
        await tester.drag(
          find.byType(CustomScrollView).last,
          const Offset(0, -700),
        );
        await settle(tester);
        await tester.drag(
          find.byType(CustomScrollView).last,
          const Offset(0, 700),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop: hovering a track row reveals the play icon and more button',
    (tester) async {
      await pumpAt(tester, const Size(1440, 900));
      await openPlaylist(tester);

      final firstTile = find.byType(TrackTile).first;
      expect(
        find.descendant(
          of: firstTile,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsNothing,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(firstTile));
      await settle(tester);

      expect(
        find.descendant(
          of: firstTile,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstTile,
          matching: find.byIcon(Icons.more_horiz_rounded),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('desktop: right-clicking a track row opens the context menu', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1440, 900));
    await openPlaylist(tester);

    await tester.tap(find.byType(TrackTile).first, buttons: kSecondaryButton);
    await settle(tester);

    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
    // 详情页操作行也有分享按钮，这里只认菜单里的那一项
    Finder menuShare() => find.descendant(
      of: find.byWidgetPredicate((w) => w is PopupMenuItem),
      matching: find.byIcon(Icons.ios_share_rounded),
    );
    expect(menuShare(), findsOneWidget);

    await tester.tap(find.byIcon(Icons.queue_music_rounded));
    await settle(tester);
    expect(find.byType(SnackBar), findsOneWidget);

    // 「分享」打开分享对话框，而不是直接复制链接
    await tester.tap(find.byType(TrackTile).first, buttons: kSecondaryButton);
    await settle(tester);
    await tester.tap(menuShare());
    await settle(tester);
    expect(find.byType(ShareSheet), findsOneWidget);
  });

  testWidgets('desktop: share survives the hover button disappearing', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1440, 900));
    await openPlaylist(tester);
    final tile = find.byType(TrackTile).first;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(tile));
    await settle(tester);
    final more = find.descendant(
      of: tile,
      matching: find.byIcon(Icons.more_horiz_rounded),
    );
    await tester.tap(more);
    await settle(tester);
    final share = find.descendant(
      of: find.byWidgetPredicate((w) => w is PopupMenuItem),
      matching: find.byIcon(Icons.ios_share_rounded),
    );
    await mouse.moveTo(tester.getCenter(share));
    await settle(tester);
    expect(more, findsNothing, reason: 'menu is outside the hovered row');
    await tester.tap(share);
    await settle(tester);
    expect(find.byType(ShareSheet), findsOneWidget);
    expect(
      tester.widget<ShareSheet>(find.byType(ShareSheet)).target.title,
      playlist.tracks.first.name,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
