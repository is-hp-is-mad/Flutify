import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyric_line_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutify_app/ui/screens/settings/sections/lyrics_section.dart';
import 'package:flutify_app/ui/screens/settings/widgets/settings_slider_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

void main() {
  test(
    'old preferences keep the previous position; malformed values are safe',
    () {
      expect(AppPreferences.fromJson({}).lyricsFocusPosition, 0.16);
      for (final value in [null, 'bad', double.nan, double.infinity]) {
        expect(
          AppPreferences.fromJson({
            'lyricsFocusPosition': value,
          }).lyricsFocusPosition,
          0.16,
        );
      }
      expect(
        AppPreferences.fromJson({
          'lyricsFocusPosition': -1,
        }).lyricsFocusPosition,
        0.10,
      );
      expect(
        AppPreferences.fromJson({'lyricsFocusPosition': 9}).lyricsFocusPosition,
        0.70,
      );
    },
  );

  testWidgets(
    'settings slider persists the position for the next app session',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final prefs = PreferencesProvider(storage.preferences);
      addTearDown(prefs.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: prefs,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(child: LyricsSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tile = find.byWidgetPredicate(
        (w) => w is SettingsSliderTile && w.title == '当前行位置',
      );
      final slider = find.descendant(of: tile, matching: find.byType(Slider));
      await tester.ensureVisible(slider);
      await tester.tapAt(tester.getCenter(slider));
      await tester.pumpAndSettle();
      expect(prefs.prefs.lyricsFocusPosition, closeTo(0.40, 0.02));
      final restored = PreferencesProvider((await StorageService.init()).preferences);
      addTearDown(restored.dispose);
      expect(restored.prefs, prefs.prefs);
      expect(restored.prefs.hashCode, prefs.prefs.hashCode);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first, middle and last lines follow a live position setting and resize',
    (tester) async {
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
            'position-test': SpotifyLyrics(
              lines: [
                for (var i = 0; i < 20; i++)
                  LyricLine(startTimeMs: i * 1000, words: 'Line $i'),
              ],
            ),
          },
        ),
        storage.library,
      );
      final height = ValueNotifier(500.0);
      addTearDown(prefs.dispose);
      addTearDown(playback.dispose);
      addTearDown(spotify.dispose);
      addTearDown(height.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: prefs),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: spotify),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: ValueListenableBuilder<double>(
                  valueListenable: height,
                  builder: (_, h, _) => SizedBox(
                    height: h,
                    width: 600,
                    child: const LyricsView(
                      track: SpotifyTrack(
                        id: 'position-test',
                        name: 'Position test',
                      ),
                      topInset: 40,
                      bottomInset: 80,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      void expectLineAt(int line, double fraction) {
        final row = find.byWidgetPredicate(
          (w) => w is LyricLineView && w.text == 'Line $line',
        );
        final y =
            tester.getTopLeft(row).dy -
            tester.getTopLeft(find.byType(LyricsView)).dy;
        expect(y, closeTo(40 + (height.value - 120) * fraction, 1));
      }

      expectLineAt(0, 0.16);
      for (final fraction in [0.10, 0.40, 0.70]) {
        for (final line in [0, 10, 19]) {
          playback.positionNotifier.value = Duration(seconds: line);
          await tester.pumpAndSettle();
          prefs.update(prefs.prefs.copyWith(lyricsFocusPosition: fraction));
          await tester.pumpAndSettle();
          expectLineAt(line, fraction);
        }
      }
      height.value = 360;
      await tester.pumpAndSettle();
      expectLineAt(19, 0.70);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
