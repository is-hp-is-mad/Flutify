import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/playlist_detail_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

/// 鼠标侧键（后退 / 前进）驱动与顶栏 ‹ › 相同的内容历史。
void main() {
  final playlist = SpotifyPlaylist(
    id: 'synthetic-playlist',
    name: 'Synthetic Playlist',
    description: 'Only used by widget tests.',
    ownerName: 'Tester',
    tracks: [
      const SpotifyTrack(id: 'synthetic00000000001', name: 'Synthetic Track', durationMs: 150000),
    ],
    totalTracks: 1,
  );

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
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

  Future<void> pressMouseButton(WidgetTester tester, int buttons) async {
    await tester.tap(
      find.byType(MainShell),
      buttons: buttons,
      kind: PointerDeviceKind.mouse,
    );
    await settle(tester);
  }

  testWidgets('侧键后退 / 前进在详情页与上一页之间切换', (tester) async {
    await pumpApp(tester);
    expect(find.byType(PlaylistDetailScreen), findsNothing);

    AppRoutes.openPlaylist(tester.element(find.byType(MainShell)), playlist);
    await settle(tester);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);

    await pressMouseButton(tester, kBackMouseButton);
    expect(find.byType(PlaylistDetailScreen), findsNothing);

    await pressMouseButton(tester, kForwardMouseButton);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根页面按后退、空前进栈按前进都是无操作', (tester) async {
    await pumpApp(tester);

    await pressMouseButton(tester, kBackMouseButton);
    await pressMouseButton(tester, kForwardMouseButton);
    expect(find.byType(MainShell), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('⌘[ / ⌘] 与顶栏 ‹ › 行为一致（macOS）', (tester) async {
    DesktopWindow.debugMacNativeWindowOverride = true;
    addTearDown(() => DesktopWindow.debugMacNativeWindowOverride = null);
    // 原生菜单栏在测试里没有平台实现：拦截 Menu.setMenus
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.menu,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.menu,
        null,
      ),
    );

    await pumpApp(tester);
    AppRoutes.openPlaylist(tester.element(find.byType(MainShell)), playlist);
    await settle(tester);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    expect(find.byType(PlaylistDetailScreen), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
