import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics/breathing_dots.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

void main() {
  Future<PlaybackProvider> host(
    WidgetTester tester, {
    SpotifyLyrics? lyrics,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final playback = PlaybackProvider(
      FakeAudioPlayerService(),
      storage,
      audioLoader: FakeTrackAudioSource(),
    );
    final spotify = SpotifyProvider(
      FakeSpotifyApiService(
        storage,
        lyricsById: {
          'apple':
              lyrics ??
              SpotifyLyrics(
                lines: [
                  for (var i = 0; i < 30; i++)
                    LyricLine(startTimeMs: i * 4000, words: 'Line $i'),
                ],
              ),
        },
      ),
      storage,
    );
    addTearDown(playback.dispose);
    addTearDown(spotify.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: spotify),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: LyricsView(
              track: SpotifyTrack(id: 'apple', name: 'Apple'),
              appleMusicStyle: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return playback;
  }

  testWidgets(
    'reanchors instantly, animates rows separately and settles at 8%',
    (tester) async {
      final playback = await host(tester);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      final before = tester.getTopLeft(find.text('Line 1')).dy;
      playback.positionNotifier.value = const Duration(seconds: 4);
      await tester.pump();
      expect(scroll.offset, greaterThan(50));
      await tester.pump();
      expect(tester.getTopLeft(find.text('Line 1')).dy, closeTo(before, 2));
      await tester.pump(const Duration(milliseconds: 850));
      // 8% viewport -2dp, plus Apple's 2dp text top padding.
      expect(
        tester.getTopLeft(find.text('Line 1')).dy,
        closeTo(600 * .08 - 2 + 2, 2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('untimed lyrics stay at the beginning without motion', (
    tester,
  ) async {
    final playback = await host(
      tester,
      lyrics: SpotifyLyrics(
        syncType: 'UNSYNCED',
        lines: [
          for (var i = 0; i < 30; i++)
            LyricLine(startTimeMs: 0, words: 'Plain $i'),
        ],
      ),
    );
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    expect(scroll.offset, 0);
    playback.positionNotifier.value = const Duration(minutes: 1);
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a held finger queues anchoring until release', (tester) async {
    final playback = await host(tester);
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    final gesture = await tester.startGesture(const Offset(300, 500));
    playback.positionNotifier.value = const Duration(seconds: 4);
    await tester.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(50));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('browsing offscreen is not pulled back after three seconds', (
    tester,
  ) async {
    final playback = await host(tester);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    final browsingOffset = scroll.offset;
    playback.positionNotifier.value = const Duration(seconds: 4);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(scroll.offset, closeTo(browsingOffset, .1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only explicit gaps >=7s produce dots, not long sung lines', (
    tester,
  ) async {
    final playback = await host(
      tester,
      lyrics: const SpotifyLyrics(
        lines: [
          LyricLine(startTimeMs: 6000, words: 'Short intro'),
          LyricLine(startTimeMs: 20000, words: 'Long sung line'),
          LyricLine(startTimeMs: 22000, words: ''),
          LyricLine(startTimeMs: 30000, words: 'After silence'),
        ],
      ),
    );
    expect(find.byType(BreathingDots), findsNothing);
    playback.positionNotifier.value = const Duration(seconds: 10);
    await tester.pumpAndSettle();
    expect(find.byType(BreathingDots), findsNothing);
    playback.positionNotifier.value = const Duration(seconds: 23);
    await tester.pumpAndSettle();
    expect(find.byType(BreathingDots), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
