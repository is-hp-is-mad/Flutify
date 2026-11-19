import 'dart:io';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/input/mouse_navigation_channel.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/playlist_detail_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutify_app/ui/screens/player/immersive_lyrics_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';

enum _Overlay { dialog, fullPlayer, immersive, stacked }

const _channel = MethodChannel('flutify/mouse_navigation');

Future<void> _settle(WidgetTester tester) async {
  // The player and lyrics have continuous animations.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

SpotifyPlaylist _playlist(String id) => SpotifyPlaylist(
  id: id,
  name: id,
  ownerName: 'Tester',
  tracks: const [
    SpotifyTrack(id: 'overlay-track', name: 'Overlay Track', durationMs: 1000),
  ],
  totalTracks: 1,
);

Future<void> _pumpApp(WidgetTester tester, TargetPlatform platform) async {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = platform == TargetPlatform.android
      ? const Size(390, 844)
      : const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final paletteEnabled = ArtworkPalette.enabled;
  ArtworkPalette.enabled = false;
  addTearDown(() => ArtworkPalette.enabled = paletteEnabled);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await tester.pumpWidget(
    FlutifyApp(
      storageService: storage,
      audioEngine: FakeAudioPlayerService(),
      emePlayer: EmePlayer(),
      spotifyApiService: FakeSpotifyApiService(storage.auth),
    ),
  );
  await _settle(tester);
}

Future<Finder> _openOverlay(WidgetTester tester, _Overlay overlay) async {
  final shell = tester.element(find.byType(MainShell));
  switch (overlay) {
    case _Overlay.dialog:
      showDialog<void>(
        context: shell,
        builder: (_) => const AlertDialog(content: Text('Navigation modal')),
      );
      await _settle(tester);
      return find.text('Navigation modal');
    case _Overlay.fullPlayer:
      FullPlayerSheet.show(shell);
      await _settle(tester);
      return find.byType(FullPlayerSheet);
    case _Overlay.immersive:
      ImmersiveLyricsScreen.open(shell);
      await _settle(tester);
      return find.byType(ImmersiveLyricsScreen);
    case _Overlay.stacked:
      FullPlayerSheet.show(shell);
      await _settle(tester);
      ImmersiveLyricsScreen.open(tester.element(find.byType(FullPlayerSheet)));
      await _settle(tester);
      return find.byType(ImmersiveLyricsScreen);
  }
}

Future<void> _fromNative(WidgetTester tester, String method) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(MethodCall(method)),
      (_) {},
    );

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    for (final overlay in _Overlay.values) {
      testWidgets('${platform.name} $overlay preserves back/forward history', (
        tester,
      ) async {
        await _pumpApp(tester, platform);
        final shell = tester.element(find.byType(MainShell));
        final root = Navigator.of(shell, rootNavigator: true);
        AppRoutes.openPlaylist(shell, _playlist('first'));
        await _settle(tester);
        AppRoutes.openPlaylist(shell, _playlist('second'));
        await _settle(tester);
        AppRoutes.navigateBack!();
        await _settle(tester);

        // There is now both a back entry (home) and a forward entry (second).
        final firstPage = tester.element(find.byType(PlaylistDetailScreen));
        final firstRoute = ModalRoute.of(firstPage)!;
        final top = await _openOverlay(tester, overlay);
        final overlayRoute = ModalRoute.of(tester.element(top))!;

        void expectHistoryUntouched() {
          expect(top, findsOneWidget);
          expect(overlayRoute.isCurrent, isTrue);
          expect(firstPage.mounted, isTrue);
          expect(firstRoute.isCurrent, isTrue);
          expect(
            find.byType(PlaylistDetailScreen, skipOffstage: false),
            findsOneWidget,
          );
        }

        for (final button in [kBackMouseButton, kForwardMouseButton]) {
          await tester.tap(top, buttons: button, kind: PointerDeviceKind.mouse);
          await _settle(tester);
          expectHistoryUntouched();
        }

        // Native input bypasses Flutter hit testing, but shares these callbacks.
        AppRoutes.navigateBack!();
        await _settle(tester);
        expectHistoryUntouched();
        AppRoutes.navigateForward!();
        await _settle(tester);
        expectHistoryUntouched();

        if (Platform.isMacOS) {
          installMacOSMouseNavigation(
            onBack: () => AppRoutes.navigateBack?.call(),
            onForward: () => AppRoutes.navigateForward?.call(),
          );
          addTearDown(() => _channel.setMethodCallHandler(null));
          for (final method in ['back', 'forward']) {
            await _fromNative(tester, method);
            await _settle(tester);
            expectHistoryUntouched();
          }
        }

        root.popUntil((route) => route.isFirst);
        await _settle(tester);
        expect(firstPage.mounted, isTrue);

        // Both directions resume after dismissal; the forward entry survived.
        await tester.tap(
          find.byType(MainShell),
          buttons: kForwardMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await _settle(tester);
        expect(
          tester
              .widget<PlaylistDetailScreen>(find.byType(PlaylistDetailScreen))
              .playlist
              .id,
          'second',
        );
        AppRoutes.navigateBack!();
        await _settle(tester);
        expect(
          tester
              .widget<PlaylistDetailScreen>(find.byType(PlaylistDetailScreen))
              .playlist
              .id,
          'first',
        );
        AppRoutes.navigateBack!();
        await _settle(tester);
        expect(find.byType(PlaylistDetailScreen), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
