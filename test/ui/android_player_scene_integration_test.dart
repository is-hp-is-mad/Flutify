import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/lyrics/lyrics_translation.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutify_app/ui/screens/player/lyrics/glass_icon_button.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyric_line_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_translation_controls.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutify_app/ui/widgets/mini_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

const _track = SpotifyTrack(
  id: 'scene-track',
  name: 'A Long Song Name For The New Lyrics Control Card',
  artists: [SpotifyArtist(id: 'scene-artist', name: 'A Realistic Artist Name')],
  durationMs: 180000,
);

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<PlaybackProvider> _open(
  WidgetTester tester, {
  double width = 390,
  bool withTranslation = false,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  final palette = ArtworkPalette.enabled;
  ArtworkPalette.enabled = false;
  addTearDown(() => ArtworkPalette.enabled = palette);
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await tester.pumpWidget(
    FlutifyApp(
      storageService: storage,
      audioEngine: FakeAudioPlayerService(),
      emePlayer: EmePlayer(),
      spotifyApiService: FakeSpotifyApiService(
        storage,
        lyricsById: {
          _track.id: SpotifyLyrics(
            language: 'en',
            lines: List.generate(
              30,
              (i) => LyricLine(
                startTimeMs: i * 4000,
                words: 'A line of lyrics number $i',
                translation: withTranslation ? '第 $i 行歌词译文' : '',
              ),
            ),
          ),
        },
      ),
      trackAudioLoader: FakeTrackAudioSource(),
    ),
  );
  await _frames(tester);
  final playback = tester
      .element(find.byType(MainShell))
      .read<PlaybackProvider>();
  await playback.playTrack(_track, contextQueue: [_track]);
  await _frames(tester);
  await tester.tap(find.byType(MiniPlayer));
  await _frames(tester);
  return playback;
}

void main() {
  for (final autoTranslate in [true, false]) {
    testWidgets('Android restores translated lyrics after artwork round trips '
        '(auto: $autoTranslate)', (tester) async {
      await _open(tester, withTranslation: true);
      final player = find.byType(FullPlayerSheet);
      final preferences = tester.element(player).read<PreferencesProvider>();
      preferences.update(
        preferences.prefs.copyWith(lyricsAutoTranslate: autoTranslate),
      );
      await _frames(tester);
      final lyricsButton = find.descendant(
        of: player,
        matching: find.byTooltip('歌词'),
      );
      final translationButton = find.byType(LyricsTranslationButton);
      final translationIcon = find.descendant(
        of: translationButton,
        matching: find.byType(GlassIconButton),
      );
      await tester.tap(lyricsButton);
      await _frames(tester);
      if (!autoTranslate) {
        expect(find.text('第 0 行歌词译文'), findsNothing);
        await tester.tap(translationButton);
        await _frames(tester);
      }
      final controller = tester
          .element(translationButton)
          .read<LyricsTranslationController>();
      final translations = controller.lines;
      expect(find.text('第 0 行歌词译文'), findsOneWidget);

      // Exercise both the small cover and the footer toggle, including a
      // second remount with an unchanged shared translation controller.
      for (final viaCover in [true, false]) {
        if (viaCover) {
          final cover = find.descendant(
            of: player,
            matching: find.byType(Hero),
          );
          await tester.tapAt(tester.getCenter(cover));
        } else {
          await tester.tap(lyricsButton);
        }
        await _frames(tester);
        expect(find.byType(LyricsView), findsNothing);
        await tester.tap(lyricsButton);
        await _frames(tester);

        expect(controller.lines, same(translations));
        expect(
          tester.widget<GlassIconButton>(translationIcon).selected,
          isTrue,
        );
        expect(find.text('第 0 行歌词译文'), findsOneWidget);
        expect(
          tester
              .widget<LyricLineView>(find.byType(LyricLineView).first)
              .translationProgress,
          1,
        );
      }

      // An explicit cancellation must also survive a round trip, even when
      // automatic translation is enabled in preferences.
      await tester.tap(translationButton);
      await _frames(tester);
      await tester.tap(lyricsButton);
      await _frames(tester);
      expect(find.byType(LyricsView), findsNothing);
      await tester.tap(lyricsButton);
      await _frames(tester);
      expect(tester.widget<GlassIconButton>(translationIcon).selected, isFalse);
      expect(find.text('第 0 行歌词译文'), findsNothing);
      await tester.tap(translationButton);
      await _frames(tester);
      expect(find.text('第 0 行歌词译文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets(
      'Android lyrics share the cover and keep the card low at $width',
      (tester) async {
        final playback = await _open(tester, width: width);
        final player = find.byType(FullPlayerSheet);
        await tester.tap(
          find.descendant(of: player, matching: find.byTooltip('歌词')),
        );
        await _frames(tester);
        final hero = find.descendant(of: player, matching: find.byType(Hero));
        expect(hero, findsOneWidget);
        expect(tester.getSize(hero).width, inInclusiveRange(56, 64));
        final card = tester.getRect(
          find.byKey(const ValueKey('lyrics-control-card')),
        );
        final translation = tester.getRect(
          find.byType(LyricsTranslationButton),
        );
        expect(card.bottom, greaterThan(800));
        expect(translation.bottom, closeTo(card.top - 8, 0.01));
        final lyricsState = tester.state(find.byType(LyricsView));
        final translationController = tester
            .element(find.byType(LyricsTranslationButton))
            .read<LyricsTranslationController>();
        await tester.pump(const Duration(seconds: 4));
        await _frames(tester, 5);
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsNothing,
        );
        expect(
          find
              .descendant(of: player, matching: find.byTooltip('歌词'))
              .hitTestable(),
          findsOneWidget,
          reason: 'the bottom lyrics/device/queue row survives folding',
        );
        final deviceButton = tester.getRect(
          find
              .ancestor(
                of: find.descendant(
                  of: player,
                  matching: find.byIcon(Icons.devices_rounded),
                ),
                matching: find.byType(InkWell),
              )
              .first,
        );
        final lyricsButton = tester.getRect(
          find.descendant(of: player, matching: find.byTooltip('歌词')),
        );
        await tester.tapAt(
          Offset(
            (deviceButton.right + lyricsButton.left) / 2,
            lyricsButton.center.dy,
          ),
        );
        await _frames(tester, 4);
        expect(
          tester.getRect(find.byKey(const ValueKey('lyrics-control-card'))),
          card,
        );
        expect(tester.state(find.byType(LyricsView)), same(lyricsState));
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsOneWidget,
          reason: 'the folded footer blank space still reveals the card',
        );
        await tester.pump(const Duration(seconds: 4));
        await _frames(tester, 5);
        playback.positionNotifier.value = const Duration(seconds: 24);
        await _frames(tester, 4);
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsNothing,
        );
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(LyricsView),
            matching: find.byType(Scrollable),
          ),
        );
        final beforeUpwardSwipe = scrollable.position.pixels;
        await tester.dragFrom(const Offset(100, 300), const Offset(0, -60));
        await _frames(tester, 4);
        expect(scrollable.position.pixels, greaterThan(beforeUpwardSwipe));
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsNothing,
          reason: 'upward lyric browsing must leave the card folded',
        );
        final beforeDownwardSwipe = scrollable.position.pixels;
        await tester.dragFrom(const Offset(100, 300), const Offset(0, 60));
        await _frames(tester, 4);
        expect(scrollable.position.pixels, lessThan(beforeDownwardSwipe));
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsOneWidget,
        );
        expect(tester.state(find.byType(LyricsView)), lyricsState);
        expect(
          tester
              .element(find.byType(LyricsTranslationButton))
              .read<LyricsTranslationController>(),
          same(translationController),
        );
        final beforeActiveUpwardSwipe = scrollable.position.pixels;
        await tester.dragFrom(const Offset(100, 300), const Offset(0, -60));
        await _frames(tester, 5);
        expect(
          scrollable.position.pixels,
          greaterThan(beforeActiveUpwardSwipe),
        );
        final foldedCard = tester.getRect(
          find.byKey(const ValueKey('lyrics-control-card')),
        );
        expect(foldedCard.top, greaterThan(card.top));
        expect(foldedCard.bottom, closeTo(card.bottom, 0.01));
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsNothing,
          reason: 'upward lyric browsing actively folds a visible card',
        );
        expect(tester.state(find.byType(LyricsView)), lyricsState);
        await tester.dragFrom(const Offset(100, 300), const Offset(0, 60));
        await _frames(tester, 4);
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsOneWidget,
        );
        expect(tester.state(find.byType(LyricsView)), lyricsState);
        expect(
          tester
              .element(find.byType(LyricsTranslationButton))
              .read<LyricsTranslationController>(),
          same(translationController),
        );
        await tester.pump(const Duration(milliseconds: 3500));
        await _frames(tester, 5);
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsNothing,
          reason: 'manual lyric browsing re-arms the next idle cycle',
        );
        playback.positionNotifier.value = const Duration(seconds: 32);
        await _frames(tester, 4);
        expect(
          find.byType(LyricsTranslationButton).hitTestable(),
          findsNothing,
          reason: 'later playback updates must not wake the folded card',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _frames(tester);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('large text and landscape keep lyrics and controls usable', (
    tester,
  ) async {
    await _open(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    await tester.tap(find.byTooltip('歌词'));
    await _frames(tester);
    for (final size in [const Size(320, 560), const Size(844, 390)]) {
      tester.view.physicalSize = size;
      await _frames(tester);
      final card = tester.getRect(
        find.byKey(const ValueKey('lyrics-control-card')),
      );
      expect(card.bottom, lessThanOrEqualTo(size.height - 24));
      expect(tester.getSize(find.byType(LyricsView)).height, greaterThan(60));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}
