import 'package:flutify_app/core/self_test/mock_services.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/auth/web_token_service.dart';
import 'package:flutify_app/ui/screens/home/home_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'FlutifyApp boots in Mock mode logged-in without login gate and drives playback silently',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final prevPalette = ArtworkPalette.enabled;
      ArtworkPalette.enabled = false;
      addTearDown(() => ArtworkPalette.enabled = prevPalette);

      late MockBootstrap mock;
      await tester.runAsync(() async {
        mock = await MockBootstrap.create();
      });

      addTearDown(() async {
        await tester.runAsync(() async {
          mock.audioEngine.dispose();
          await mock.coverServer.close();
          if (await mock.tempDir.exists()) {
            await mock.tempDir.delete(recursive: true);
          }
        });
      });

      await tester.pumpWidget(
        FlutifyApp(
          storageService: mock.storageService,
          audioEngine: mock.audioEngine,
          emePlayer: mock.emePlayer,
          spotifyApiService: mock.spotifyApiService,
          authService: mock.authService,
          webTokenService: WebTokenService(
            mock.storageService,
            MockOfflineHttpClient(),
          ),
          trackAudioLoader: mock.trackAudioLoader,
          playbackSessionStore: mock.playbackSessionStore,
          audioCacheLocation: mock.audioCacheLocation,
          playbackRegionGate: mock.playbackRegionGate,
          updateService: mock.updateService,
          audioOutputBackend: mock.audioOutputBackend,
          enableConnectReceiver: false,
        ),
      );

      // Pump enough frames for initial async home/library load inside mock zone
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byType(MainShell), findsOneWidget);
      expect(find.byType(HomeScreen), findsOneWidget);

      // Verify silent mock track playback via PlaybackProvider
      final shellCtx = tester.element(find.byType(MainShell));
      final playback = shellCtx.read<PlaybackProvider>();
      final track = mock.catalog.coreTracks.first;

      await tester.runAsync(() async {
        await playback.playTrack(
          track,
          contextQueue: mock.catalog.coreTracks,
          context: PlaybackContext.playlist(
            mock.catalog.playlists.first.name,
            uri: mock.catalog.playlists.first.contextUri,
          ),
        );
      });
      await tester.pump(const Duration(milliseconds: 100));

      expect(playback.currentTrack?.id, track.id);
      expect(playback.isPlaying, isTrue);

      await tester.runAsync(() => playback.pause());
      await tester.pump(const Duration(milliseconds: 50));
      expect(playback.isPlaying, isFalse);

      // Unmount tree and drain periodic/delayed timers (UpdateService & CacheStore).
      await tester.pumpWidget(const SizedBox.shrink());
      mock.updateService.dispose();
      await tester.pump(const Duration(seconds: 15));
    },
  );
}
