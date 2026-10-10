import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/lyrics/lyrics_translation.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/lyrics/apple_music_motion.dart';
import 'package:flutify_app/ui/screens/player/lyrics/breathing_dots.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyric_line_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

void main() {
  Future<
    ({
      PlaybackProvider playback,
      PreferencesProvider preferences,
      LyricsTranslationController translation,
    })
  >
  host(
    WidgetTester tester, {
    SpotifyLyrics? lyrics,
    bool appleMusicStyle = true,
    ValueNotifier<bool>? tickerMode,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final playback = PlaybackProvider(
      FakeAudioPlayerService(),
      storage,
      audioLoader: FakeTrackAudioSource(),
    );
    final preferences = PreferencesProvider(storage);
    final translation = LyricsTranslationController();
    final spotify = SpotifyProvider(
      FakeSpotifyApiService(
        storage,
        lyricsById: {
          'regression':
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
    addTearDown(preferences.dispose);
    addTearDown(spotify.dispose);
    addTearDown(translation.dispose);
    final lyricsView = LyricsView(
      track: const SpotifyTrack(id: 'regression', name: 'Regression'),
      fontSize: 42,
      appleMusicStyle: appleMusicStyle,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: preferences),
          ChangeNotifierProvider.value(value: spotify),
          ChangeNotifierProvider.value(value: translation),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: tickerMode == null
                ? lyricsView
                : ValueListenableBuilder<bool>(
                    valueListenable: tickerMode,
                    child: lyricsView,
                    builder: (_, enabled, child) =>
                        TickerMode(enabled: enabled, child: child!),
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (
      playback: playback,
      preferences: preferences,
      translation: translation,
    );
  }

  ScrollController scroll(WidgetTester tester) => tester
      .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
      .controller!;

  bool browsing(WidgetTester tester) =>
      tester.widget<LyricLineView>(find.byType(LyricLineView).first).focusAll;

  double lineTop(WidgetTester tester, String text) =>
      tester.getTopLeft(find.widgetWithText(LyricLineView, text)).dy;

  testWidgets('Apple lyrics use a 30sp base and preserve preference scaling', (
    tester,
  ) async {
    final app = await host(tester);
    expect(tester.widget<Text>(find.text('Line 0')).style!.fontSize, 30);
    app.preferences.update(app.preferences.prefs.copyWith(lyricsScale: 1.2));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('Line 0')).style!.fontSize, 36);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('non-Apple lyrics retain their caller-supplied font size', (
    tester,
  ) async {
    await host(tester, appleMusicStyle: false);
    expect(tester.widget<Text>(find.text('Line 0')).style!.fontSize, 42);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'visible current lyrics do not immediately cancel manual browsing',
    (tester) async {
      final app = await host(tester);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -25),
      );
      await tester.pumpAndSettle();
      expect(browsing(tester), isTrue);
      final offset = scroll(tester).offset;
      app.playback.positionNotifier.value = const Duration(seconds: 4);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(browsing(tester), isTrue);
      expect(scroll(tester).offset, closeTo(offset, .1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('offscreen browsing resumes after five seconds of scroll idle', (
    tester,
  ) async {
    final app = await host(tester);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    expect(browsing(tester), isTrue);
    final offset = scroll(tester).offset;
    app.playback.positionNotifier.value = const Duration(seconds: 4);
    await tester.pump(const Duration(seconds: 3));
    expect(scroll(tester).offset, closeTo(offset, .1));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(browsing(tester), isFalse);
    expect(lineTop(tester, 'Line 1'), closeTo(600 * .08 - 2, .1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('outside pointer cancellation starts a fresh five-second hold', (
    tester,
  ) async {
    final app = await host(tester);
    final gesture = await tester.startGesture(const Offset(300, 450));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -620));
    await tester.pump(const Duration(seconds: 6));
    app.playback.positionNotifier.value = const Duration(seconds: 8);
    await tester.pump();
    expect(browsing(tester), isTrue);
    final offset = scroll(tester).offset;
    await gesture.cancel();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(browsing(tester), isTrue);
    expect(scroll(tester).offset, closeTo(offset, .1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(browsing(tester), isFalse);
    expect(lineTop(tester, 'Line 2'), closeTo(600 * .08 - 2, .1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the five-second hold starts after fling inertia stops', (
    tester,
  ) async {
    final app = await host(tester);
    await tester.fling(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
      1600,
    );
    expect(scroll(tester).position.isScrollingNotifier.value, isTrue);
    for (
      var i = 0;
      i < 200 && scroll(tester).position.isScrollingNotifier.value;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(browsing(tester), isTrue);
    }
    expect(scroll(tester).position.isScrollingNotifier.value, isFalse);
    final offset = scroll(tester).offset;
    app.playback.positionNotifier.value = const Duration(seconds: 4);
    await tester.pump(const Duration(milliseconds: 4900));
    expect(browsing(tester), isTrue);
    expect(scroll(tester).offset, closeTo(offset, .1));
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pumpAndSettle();
    expect(browsing(tester), isFalse);
    expect(lineTop(tester, 'Line 1'), closeTo(600 * .08 - 2, .1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposing while the browse timer is pending cancels all work', (
    tester,
  ) async {
    await host(tester);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(browsing(tester), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'gap removal during translation reveal stays anchored and paused seeking still works',
    (tester) async {
      final app = await host(
        tester,
        lyrics: const SpotifyLyrics(
          language: 'en',
          lines: [
            LyricLine(startTimeMs: 8000, words: 'First words'),
            LyricLine(startTimeMs: 12000, words: 'Second words'),
            LyricLine(startTimeMs: 14000, words: ''),
            LyricLine(startTimeMs: 24000, words: 'After the break'),
          ],
          alternatives: [
            LyricsAlternative(
              language: 'en',
              lines: [
                'Translated first',
                'Translated second',
                '',
                'Translated ending',
              ],
            ),
          ],
        ),
      );
      app.playback.positionNotifier.value = const Duration(milliseconds: 22800);
      await tester.pumpAndSettle();
      await app.translation.translate();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Translated ending'), findsOneWidget);
      final anchor = lineTop(tester, 'After the break');
      app.playback.positionNotifier.value = const Duration(milliseconds: 23700);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(BreathingDots), findsNothing);
      expect(lineTop(tester, 'After the break'), closeTo(anchor, .1));
      await tester.pumpAndSettle();
      expect(lineTop(tester, 'After the break'), closeTo(anchor, .1));
      await app.playback.seekTo(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(app.playback.isPlaying, isFalse);
      expect(lineTop(tester, 'First words'), closeTo(600 * .08 - 2, .1));
      app.translation.cancel();
      await tester.pumpAndSettle();
      expect(find.text('Translated first'), findsNothing);
      expect(lineTop(tester, 'First words'), closeTo(600 * .08 - 2, .1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final lifecycle in [true, false]) {
    testWidgets(
      '${lifecycle ? 'app lifecycle' : 'TickerMode'} return recovers a lost pointer release',
      (tester) async {
        final tickerMode = ValueNotifier(true);
        addTearDown(tickerMode.dispose);
        final app = await host(tester, tickerMode: tickerMode);
        final gesture = await tester.startGesture(const Offset(300, 450));
        await gesture.moveBy(const Offset(0, -80));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(0, -320));
        await tester.pump();
        expect(browsing(tester), isTrue);
        if (lifecycle) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        } else {
          tickerMode.value = false;
        }
        await tester.pump();
        app.playback.positionNotifier.value = const Duration(seconds: 4);
        await tester.pump(const Duration(seconds: 6));
        expect(browsing(tester), isTrue);
        if (lifecycle) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          tickerMode.value = true;
        }
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));
        expect(browsing(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(
          browsing(tester),
          isFalse,
          reason:
              'A release lost while hidden must not freeze following forever.',
        );
        expect(lineTop(tester, 'Line 1'), closeTo(600 * .08 - 2, .1));
        await gesture.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'a new touch extends the hold and tap-to-seek resumes immediately',
    (tester) async {
      final app = await host(tester);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      final gesture = await tester.startGesture(const Offset(300, 450));
      await tester.pump(const Duration(seconds: 6));
      expect(browsing(tester), isTrue);
      await gesture.cancel();
      await tester.pump(const Duration(seconds: 4));
      expect(browsing(tester), isTrue);
      final visible = tester
          .widgetList<LyricLineView>(find.byType(LyricLineView))
          .firstWhere((line) {
            final y = lineTop(tester, line.text);
            return y > 100 && y < 350;
          });
      await tester.tap(find.text(visible.text));
      await tester.pumpAndSettle();
      expect(browsing(tester), isFalse);
      final index = int.parse(visible.text.split(' ').last);
      expect(app.playback.positionNotifier.value, Duration(seconds: index * 4));
      expect(lineTop(tester, visible.text), closeTo(600 * .08 - 2, .1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
      expect(tester.takeException(), isNull);
    },
  );

  for (final intro in [true, false]) {
    final source = SpotifyLyrics(
      lines: [
        if (!intro) ...[
          const LyricLine(startTimeMs: 0, words: 'Before silence'),
          const LyricLine(startTimeMs: 2000, words: ''),
        ],
        const LyricLine(startTimeMs: 10000, words: 'After silence'),
        const LyricLine(startTimeMs: 14000, words: 'Following line'),
      ],
    );
    testWidgets(
      '${intro ? 'intro' : 'interlude'} removal preserves the same painted anchor',
      (tester) async {
        final app = await host(tester, lyrics: source);
        app.playback.positionNotifier.value = const Duration(
          milliseconds: 8800,
        );
        await tester.pumpAndSettle();
        expect(find.byType(BreathingDots), findsOneWidget);
        final before = lineTop(tester, 'After silence');
        app.playback.positionNotifier.value = const Duration(
          milliseconds: 9700,
        );
        await tester.pump();
        expect(find.byType(BreathingDots), findsNothing);
        expect(lineTop(tester, 'After silence'), closeTo(before, .1));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(lineTop(tester, 'After silence'), closeTo(before, .1));
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final frameMs in [16, 100]) {
    testWidgets(
      'interlude exit keeps one cascade clock across active-index changes ($frameMs ms frames)',
      (tester) async {
        final app = await host(
          tester,
          lyrics: const SpotifyLyrics(
            lines: [
              LyricLine(startTimeMs: 0, words: 'Before silence'),
              LyricLine(startTimeMs: 2000, words: ''),
              LyricLine(startTimeMs: 10000, words: 'After silence'),
              LyricLine(startTimeMs: 14000, words: 'Following line'),
            ],
          ),
        );
        app.playback.positionNotifier.value = const Duration(
          milliseconds: 8000,
        );
        await tester.pumpAndSettle();
        final initial = lineTop(tester, 'After silence');
        final followingInitial = lineTop(tester, 'Following line');
        app.playback.positionNotifier.value = const Duration(
          milliseconds: 8700,
        );
        await tester.pump();
        await tester.pump();
        const anchor = 600 * .08 - 2;
        final deviations = <double>[];
        final frames = <String>[];
        for (var elapsed = frameMs; elapsed <= 1120; elapsed += frameMs) {
          app.playback.positionNotifier.value = Duration(
            // Match the real player's ~200 ms feed while rendering at 60 Hz.
            milliseconds:
                8700 + (frameMs == 16 ? elapsed ~/ 200 * 200 : elapsed),
          );
          await tester.pump(Duration(milliseconds: frameMs));
          final expected =
              anchor +
              (initial - anchor) *
                  AppleMusicMotion.remainingMove(0, elapsed.toDouble());
          final actual = lineTop(tester, 'After silence');
          deviations.add((actual - expected).abs());
          final followingExpected =
              followingInitial -
              (initial - anchor) *
                  (1 - AppleMusicMotion.remainingMove(1, elapsed.toDouble()));
          deviations.add(
            (lineTop(tester, 'Following line') - followingExpected).abs(),
          );
          frames.add(
            '$elapsed:${actual.toStringAsFixed(3)}/${expected.toStringAsFixed(3)}',
          );
        }
        debugPrint(
          'cascade $frameMs ms frames (ms:actual/expected dp): ${frames.join(', ')}',
        );
        expect(
          deviations,
          everyElement(lessThan(.25)),
          reason:
              'No frame may restart the cascade clock or jump at gap removal.',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
