import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/immersive_lyrics_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

const _entering = SpotifyTrack(
  id: 'immersive-entering',
  name: 'Entering Song',
  durationMs: 180000,
);
const _current = SpotifyTrack(
  id: 'immersive-current',
  name: 'Current Song',
  durationMs: 180000,
);

void main() {
  testWidgets(
    'closing immersive lyrics never flashes the track it opened with',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final paletteEnabled = ArtworkPalette.enabled;
      ArtworkPalette.enabled = false;
      addTearDown(() => ArtworkPalette.enabled = paletteEnabled);
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final audio = FakeAudioPlayerService();
      await tester.pumpWidget(
        FlutifyApp(
          storageService: storage,
          audioEngine: audio,
          emePlayer: EmePlayer(),
          spotifyApiService: FakeSpotifyApiService(storage.auth),
          trackAudioLoader: FakeTrackAudioSource(),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final shell = tester.element(find.byType(MainShell));
      final playback = shell.read<PlaybackProvider>();
      await playback.playTrack(_entering, contextQueue: [_entering, _current]);
      audio.durationController.add(const Duration(minutes: 3));
      audio.stateController.add(PlayerState(true, ProcessingState.ready));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final shellText = (String text) => find.descendant(
        of: find.byType(MainShell),
        matching: find.text(text),
        skipOffstage: false,
      );
      expect(shellText('Entering Song'), findsWidgets);

      ImmersiveLyricsScreen.open(shell);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The track changes while the immersive page covers the shell.
      await playback.playTrack(_current, contextQueue: [_entering, _current]);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(playback.currentTrack?.id, _current.id);

      await tester.tap(find.byTooltip('退出全屏歌词（Esc）'));
      // Sample every frame of the exit animation: the shell that shows through
      // must already be on the current track.
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          shellText('Entering Song'),
          findsNothing,
          reason: 'stale track visible at exit frame $frame',
        );
      }
      expect(shellText('Current Song'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      // Reset inside the body: the framework checks debug variables before
      // tear-down callbacks run.
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );
}
