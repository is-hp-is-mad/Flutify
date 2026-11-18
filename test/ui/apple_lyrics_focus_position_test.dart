import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

void main() {
  group(
    'portrait full-screen (Apple style) lyrics follow the position setting',
    () {
      Future<(PreferencesProvider, PlaybackProvider)> lyricsHost(
        WidgetTester tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final storage = await StorageService.init();
        final prefs = PreferencesProvider(storage.preferences);
        prefs.update(prefs.prefs.copyWith(lyricsAutoTranslate: false));
        final playback = PlaybackProvider(FakeAudioPlayerService(), storage.playback,
          audioLoader: FakeTrackAudioSource(),
        );
        final spotify = SpotifyProvider(
          FakeSpotifyApiService(storage.auth,
            lyricsById: {
              'apple-focus': SpotifyLyrics(
                lines: [
                  for (var i = 0; i < 30; i++)
                    LyricLine(startTimeMs: i * 4000, words: 'Line $i'),
                ],
              ),
            },
          ),
          storage.library,
        );
        addTearDown(prefs.dispose);
        addTearDown(playback.dispose);
        addTearDown(spotify.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: prefs),
              ChangeNotifierProvider.value(value: playback),
              ChangeNotifierProvider.value(value: spotify),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: Scaffold(
                body: LyricsView(
                  track: SpotifyTrack(id: 'apple-focus', name: 'Apple focus'),
                  appleMusicStyle: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return (prefs, playback);
      }

      testWidgets('default setting anchors the focused line at 16%', (
        tester,
      ) async {
        final (_, playback) = await lyricsHost(tester);
        playback.positionNotifier.value = const Duration(seconds: 8);
        await tester.pumpAndSettle();
        // 600 高视口，设置值即对焦行顶端比例：默认 16%，再减 2dp 并加上 Apple 文本 2dp 顶部留白。
        expect(
          tester.getTopLeft(find.text('Line 2')).dy,
          closeTo(600 * .16, 2),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('changing the setting moves the focused line, even live', (
        tester,
      ) async {
        final (prefs, playback) = await lyricsHost(tester);
        playback.positionNotifier.value = const Duration(seconds: 8);
        await tester.pumpAndSettle();
        for (final value in [0.10, 0.40, 0.70]) {
          prefs.update(prefs.prefs.copyWith(lyricsFocusPosition: value));
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(find.text('Line 2')).dy,
            closeTo(600 * value, 2),
            reason: 'focus position $value',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );
}
