import 'dart:async';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutify_app/ui/screens/player/lyrics/breathing_dots.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyric_line_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_translation_controls.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutify_app/ui/screens/player/lyrics_sheet.dart';
import 'package:flutify_app/ui/screens/settings/sections/lyrics_section.dart';
import 'package:flutify_app/ui/screens/settings/widgets/settings_section.dart';
import 'package:flutify_app/ui/widgets/liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

void main() {
  const track = SpotifyTrack(
    id: 'android-lyrics',
    uri: 'spotify:track:android-lyrics',
    name: 'Android Lyrics',
    durationMs: 60000,
  );
  const lyrics = SpotifyLyrics(
    language: 'en',
    lines: [
      LyricLine(startTimeMs: 8000, words: 'First words'),
      LyricLine(startTimeMs: 12000, words: 'Second words'),
      LyricLine(startTimeMs: 16000, words: '♪'),
      LyricLine(startTimeMs: 24000, words: 'After the break'),
    ],
    alternatives: [
      LyricsAlternative(
        language: 'zh-Hans',
        lines: ['第一句歌词', '第二句歌词', '', '间奏之后'],
      ),
    ],
  );

  Widget androidApp(Widget child, {bool reduceMotion = false}) => MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    builder: reduceMotion
        ? (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          )
        : null,
    home: Scaffold(body: child),
  );

  Future<(FakeAudioPlayerService, PlaybackProvider)> pumpLyrics(
    WidgetTester tester, {
    double width = 390,
    bool reduceMotion = false,
    bool glass = true,
    SpotifyLyrics source = lyrics,
    double? viewportHeight,
    double topInset = 48,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final audio = FakeAudioPlayerService();
    final playback = PlaybackProvider(
      audio,
      storage,
      audioLoader: FakeTrackAudioSource(),
    );
    final spotify = SpotifyProvider(
      FakeSpotifyApiService(storage, lyricsById: {track.id: source}),
      storage,
    );
    final preferences = PreferencesProvider(storage);
    addTearDown(playback.dispose);
    addTearDown(spotify.dispose);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: spotify),
          ChangeNotifierProvider.value(value: preferences),
        ],
        child: androidApp(
          SizedBox(
            height: viewportHeight,
            child: LyricsTranslationScope(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LyricsView(track: track, topInset: topInset),
                  ),
                  Positioned(
                    top: 0,
                    left: 12,
                    child: LyricsTranslationButton(glass: glass),
                  ),
                ],
              ),
            ),
          ),
          reduceMotion: reduceMotion,
        ),
      ),
    );
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return (audio, playback);
  }

  double breathingScale(WidgetTester tester) => tester
      .widget<Transform>(
        find.descendant(
          of: find.byType(BreathingDots),
          matching: find.byType(Transform),
        ),
      )
      .transform
      .entry(0, 0);

  testWidgets('Android intro breathes as soon as playback starts', (
    tester,
  ) async {
    final (audio, playback) = await pumpLyrics(tester);
    final initialScale = breathingScale(tester);
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(playback.positionNotifier.value, Duration.zero);
    expect(breathingScale(tester), isNot(closeTo(initialScale, 0.001)));
    audio.stateController.add(PlayerState(false, ProcessingState.ready));
    await tester.pump();
    final pausedScale = breathingScale(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(breathingScale(tester), closeTo(pausedScale, 0.001));
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    await tester.pump();
    expect(breathingScale(tester), closeTo(pausedScale, 0.001));
    await tester.pump(const Duration(milliseconds: 300));
    expect(breathingScale(tester), isNot(closeTo(pausedScale, 0.001)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android seeking while paused does not start breathing', (
    tester,
  ) async {
    final (_, playback) = await pumpLyrics(tester);
    final pausedScale = breathingScale(tester);
    playback.positionNotifier.value = const Duration(seconds: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(breathingScale(tester), closeTo(pausedScale, 0.001));
    playback.positionNotifier.value = const Duration(seconds: 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(breathingScale(tester), closeTo(pausedScale, 0.001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android buffering freezes the intro animation', (tester) async {
    final (audio, _) = await pumpLyrics(tester);
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    audio.stateController.add(PlayerState(true, ProcessingState.buffering));
    await tester.pump();
    final bufferingScale = breathingScale(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(breathingScale(tester), closeTo(bufferingScale, 0.001));
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(breathingScale(tester), isNot(closeTo(bufferingScale, 0.001)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android reduced motion does not schedule breathing frames', (
    tester,
  ) async {
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      androidApp(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: BreathingDots(
            position: position,
            isPlaying: true,
            startMs: 0,
            endMs: 8000,
            dotSize: 12,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(breathingScale(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(breathingScale(tester), 1);
    position.value = const Duration(milliseconds: 7700);
    await tester.pump();
    expect(breathingScale(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android breathing detaches an old position source', (
    tester,
  ) async {
    final first = _PositionNotifier(Duration.zero);
    final second = _PositionNotifier(const Duration(seconds: 2));
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Future<void> pumpDots(ValueNotifier<Duration> position) =>
        tester.pumpWidget(
          androidApp(
            BreathingDots(
              position: position,
              isPlaying: false,
              startMs: 0,
              endMs: 8000,
              dotSize: 12,
            ),
          ),
        );
    await pumpDots(first);
    expect(first.observed, isTrue);
    await pumpDots(second);
    expect(first.observed, isFalse);
    expect(second.observed, isTrue);
    first.value = const Duration(seconds: 5);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.observed, isFalse);
  });

  testWidgets('Android returning to lyrics uses the latest playback position', (
    tester,
  ) async {
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    Future<void> pumpDots(bool enabled) => tester.pumpWidget(
      androidApp(
        TickerMode(
          enabled: enabled,
          child: BreathingDots(
            position: position,
            isPlaying: true,
            startMs: 0,
            endMs: 8000,
            dotSize: 12,
          ),
        ),
      ),
    );
    await pumpDots(true);
    await tester.pump(const Duration(milliseconds: 300));
    await pumpDots(false);
    position.value = const Duration(seconds: 4);
    await tester.pump(const Duration(seconds: 10));
    await pumpDots(true);
    await tester.pump();
    expect(breathingScale(tester), greaterThan(0.8));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (sheet, width) in [
    for (final width in [320.0, 390.0, 600.0])
      for (final sheet in ['full player', 'lyrics sheet']) (sheet, width),
  ]) {
    testWidgets(
      'Android $sheet shows the intro and bilingual lyrics at ${width}px',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
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
            spotifyApiService: FakeSpotifyApiService(
              storage,
              lyricsById: {track.id: lyrics},
            ),
            trackAudioLoader: FakeTrackAudioSource(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final context = tester.element(find.byType(MainShell));
        final playback = context.read<PlaybackProvider>();
        await playback.playTrack(track);
        audio.stateController.add(PlayerState(true, ProcessingState.ready));
        if (sheet == 'full player') {
          unawaited(FullPlayerSheet.show(context));
        } else {
          unawaited(LyricsSheet.show(context));
        }
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (sheet == 'full player') {
          await tester.tap(
            find.descendant(
              of: find.byType(FullPlayerSheet),
              matching: find.byTooltip('歌词'),
            ),
          );
          for (var frame = 0; frame < 8; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        }
        expect(find.byType(BreathingDots), findsOneWidget);
        expect(find.text('First words'), findsOneWidget);
        expect(find.text('第一句歌词'), findsOneWidget);
        final buttonRect = tester.getRect(find.byType(LyricsTranslationButton));
        if (sheet == 'lyrics sheet') {
          final title = find.descendant(
            of: find.byType(LyricsSheet),
            matching: find.text(track.name),
          );
          final cardRect = tester.getRect(
            find.ancestor(of: title, matching: find.byType(LiquidGlass)).first,
          );
          expect(buttonRect.right, closeTo(cardRect.right, 0.1));
          expect(cardRect.top - buttonRect.bottom, closeTo(6, 0.1));
        } else {
          final cardRect = tester.getRect(
            find.byKey(const ValueKey('lyrics-control-card')),
          );
          expect(buttonRect.right, closeTo(cardRect.right, 0.1));
          expect(cardRect.top - buttonRect.bottom, closeTo(8, 0.1));
        }
        expect(buttonRect.width, greaterThanOrEqualTo(48));
        expect(buttonRect.height, buttonRect.width);
        final decoration =
            tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: find.byType(LyricsTranslationButton),
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.borderRadius, BorderRadius.circular(24));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(LyricsTranslationButton));
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('First words'), findsOneWidget);
        expect(find.text('第一句歌词'), findsNothing);
        playback.positionNotifier.value = const Duration(seconds: 9);
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(BreathingDots), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('Android bilingual lyrics can be toggled at ${width}px', (
      tester,
    ) async {
      await pumpLyrics(tester, width: width);
      expect(find.text('First words'), findsOneWidget);
      expect(find.text('第一句歌词'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(LyricsTranslationButton));
      await tester.pumpAndSettle();
      expect(find.text('First words'), findsOneWidget);
      expect(find.text('第一句歌词'), findsNothing);
      await tester.tap(find.byType(LyricsTranslationButton));
      await tester.pumpAndSettle();
      expect(find.text('第一句歌词'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final provider in [LyricsProvider.qqMusic, LyricsProvider.netease]) {
    testWidgets('bilingual lyrics attribute the actual provider: $provider', (
      tester,
    ) async {
      await pumpLyrics(
        tester,
        source: SpotifyLyrics(
          language: 'en',
          translationProvider: provider,
          lines: const [
            LyricLine(
              startTimeMs: 1000,
              words: 'Paper stars',
              translation: '纸星星',
            ),
            LyricLine(
              startTimeMs: 4000,
              words: 'Draw a circle',
              translation: '画一个圆',
            ),
          ],
        ),
      );
      final expected = provider == LyricsProvider.qqMusic
          ? '译词来自 QQ 音乐'
          : '译词来自网易云音乐社区';
      final other = provider == LyricsProvider.qqMusic
          ? '译词来自网易云音乐社区'
          : '译词来自 QQ 音乐';
      expect(find.text(expected), findsOneWidget);
      expect(find.text(other), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final glass in [true, false]) {
    testWidgets(
      'Android translation stays a translate icon with inverted colors (glass: $glass)',
      (tester) async {
        await pumpLyrics(tester, glass: glass);
        final button = find.descendant(
          of: find.byType(LyricsTranslationButton),
          matching: find.byType(IconButton),
        );
        IconButton currentButton() => tester.widget<IconButton>(button);
        expect((currentButton().icon as Icon).icon, Icons.translate_rounded);
        expect(currentButton().color, Colors.black87);
        expect(currentButton().isSelected, isTrue);
        expect(currentButton().tooltip, '取消译词');
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect((currentButton().icon as Icon).icon, Icons.translate_rounded);
        expect(currentButton().color, Colors.white);
        expect(currentButton().isSelected, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Android translation moves and fades together with Apple easing',
    (tester) async {
      final (_, playback) = await pumpLyrics(tester);
      playback.positionNotifier.value = const Duration(seconds: 13);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(LyricsTranslationButton));
      await tester.pumpAndSettle();
      final original = find.text('Second words');
      final translation = find.text('第二句歌词');
      final collapsedY = tester.getTopLeft(original).dy;
      await tester.tap(find.byType(LyricsTranslationButton));
      await tester.pump();
      expect(tester.getTopLeft(original).dy, closeTo(collapsedY, 0.1));
      await tester.pump(const Duration(milliseconds: 80));
      final intermediateY = tester.getTopLeft(original).dy;
      final intermediateTranslationY = tester.getTopLeft(translation).dy;
      final intermediateAlpha = tester
          .widget<Text>(translation)
          .style!
          .color!
          .a;
      expect(intermediateY, lessThan(collapsedY));
      expect(intermediateAlpha, inExclusiveRange(0.0, 0.62));
      await tester.pumpAndSettle();
      final expandedY = tester.getTopLeft(original).dy;
      expect(intermediateY, greaterThan(expandedY));
      expect(
        collapsedY - intermediateY,
        greaterThan((collapsedY - expandedY) * 0.3),
        reason: 'Apple ease-out moves faster than a linear 80 / 560 tween',
      );
      expect(
        intermediateTranslationY,
        greaterThan(tester.getTopLeft(translation).dy),
      );
      expect(
        tester.widget<Text>(translation).style!.color!.a,
        closeTo(0.62, 0.01),
      );
      await tester.tap(find.byType(LyricsTranslationButton));
      await tester.pump();
      expect(translation, findsOneWidget);
      expect(tester.getTopLeft(original).dy, closeTo(expandedY, 0.1));
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.getTopLeft(original).dy,
        inExclusiveRange(expandedY, collapsedY),
      );
      expect(
        tester.widget<Text>(translation).style!.color!.a,
        inExclusiveRange(0.0, 0.62),
      );
      await tester.pumpAndSettle();
      expect(translation, findsNothing);
      expect(tester.getTopLeft(original).dy, closeTo(collapsedY, 0.5));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Android rapid translation reversal keeps its current position', (
    tester,
  ) async {
    final (_, playback) = await pumpLyrics(tester);
    playback.positionNotifier.value = const Duration(seconds: 13);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LyricsTranslationButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final beforeReversal = tester.getTopLeft(find.text('Second words')).dy;
    expect(find.text('第二句歌词'), findsOneWidget);
    await tester.tap(find.byType(LyricsTranslationButton));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Second words')).dy,
      closeTo(beforeReversal, 0.1),
    );
    await tester.pumpAndSettle();
    expect(find.text('第二句歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android lyric scrolling uses nonlinear Apple easing', (
    tester,
  ) async {
    final (_, playback) = await pumpLyrics(tester);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(LyricsView),
        matching: find.byType(Scrollable),
      ),
    );
    final start = scrollable.position.pixels;
    playback.positionNotifier.value = const Duration(seconds: 13);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final intermediate = scrollable.position.pixels;
    await tester.pumpAndSettle();
    final end = scrollable.position.pixels;
    expect(intermediate, inExclusiveRange(start, end));
    expect(intermediate - start, greaterThan((end - start) * 0.3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android reduced motion switches translations immediately', (
    tester,
  ) async {
    await pumpLyrics(tester, reduceMotion: true);
    await tester.tap(find.byType(LyricsTranslationButton));
    await tester.pump();
    expect(find.text('第一句歌词'), findsNothing);
    await tester.tap(find.byType(LyricsTranslationButton));
    await tester.pump();
    expect(find.text('第一句歌词'), findsOneWidget);
    final originalY = tester.getTopLeft(find.text('First words')).dy;
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(find.text('First words')).dy, originalY);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android multiline translations reflow without losing focus', (
    tester,
  ) async {
    const multiline = SpotifyLyrics(
      language: 'en',
      lines: [
        LyricLine(startTimeMs: 0, words: 'First words'),
        LyricLine(startTimeMs: 12000, words: 'Second words'),
        LyricLine(startTimeMs: 24000, words: 'Next words'),
      ],
      alternatives: [
        LyricsAlternative(
          language: 'zh-Hans',
          lines: ['第一句长长的译文\n也有第二行\n还有第三行', '第二句歌词的多行译文\n这行也需要保留间距', '下一句歌词'],
        ),
      ],
    );
    final (_, playback) = await pumpLyrics(
      tester,
      width: 320,
      source: multiline,
    );
    playback.positionNotifier.value = const Duration(seconds: 13);
    await tester.pumpAndSettle();
    final original = find.text('Second words');
    final expandedY = tester.getTopLeft(original).dy;
    await tester.tap(find.byType(LyricsTranslationButton));
    await tester.pump();
    for (var frame = 0; frame < 7; frame++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.getTopLeft(original).dy,
        inInclusiveRange(expandedY - 0.5, expandedY + 9.5),
      );
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LyricsTranslationButton));
    await tester.pump();
    for (var frame = 0; frame < 7; frame++) {
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.getTopLeft(original).dy,
        inInclusiveRange(expandedY - 0.5, expandedY + 9.5),
      );
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(original).dy, closeTo(expandedY, 0.5));
    expect(
      tester.getBottomLeft(find.text(multiline.alternatives.first.lines[1])).dy,
      lessThan(tester.getTopLeft(find.text('Next words')).dy - 12),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final frameDuration in [
    const Duration(microseconds: 16667),
    const Duration(microseconds: 8333),
  ]) {
    testWidgets(
      'Android translated lyric focus is stable at paint time (${frameDuration.inMicroseconds} us)',
      (tester) async {
        final source = SpotifyLyrics(
          language: 'en',
          lines: List.generate(
            24,
            (index) => LyricLine(
              startTimeMs: index * 5000,
              words: 'Original line $index',
            ),
          ),
          alternatives: [
            LyricsAlternative(
              language: 'zh-Hans',
              lines: List.generate(
                24,
                (index) => '第 $index 句的多行译文\n译文的第二行\n译文的第三行',
              ),
            ),
          ],
        );
        final (_, playback) = await pumpLyrics(
          tester,
          width: 320,
          source: source,
        );
        playback.positionNotifier.value = const Duration(seconds: 61);
        await tester.pumpAndSettle();
        final original = find.text('Original line 12');
        final row = find.ancestor(
          of: original,
          matching: find.byType(LyricLineView),
        );
        final collapsedY = tester.getTopLeft(original).dy + 9;
        final paintErrors = <double>[];
        var samplePaint = true;
        addTearDown(() => samplePaint = false);
        tester.binding.addPersistentFrameCallback((_) {
          if (!samplePaint) return;
          final progress = tester
              .widget<LyricLineView>(row)
              .translationProgress;
          final expectedY = collapsedY - 9 * progress;
          paintErrors.add((tester.getTopLeft(original).dy - expectedY).abs());
        });
        for (var toggle = 0; toggle < 3; toggle++) {
          await tester.tap(find.byType(LyricsTranslationButton));
          await tester.pump();
          for (var frame = 0; frame < 75; frame++) {
            await tester.pump(frameDuration);
          }
        }
        await tester.tap(find.byType(LyricsTranslationButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(find.byType(LyricsTranslationButton));
        await tester.pump();
        for (var frame = 0; frame < 75; frame++) {
          await tester.pump(frameDuration);
        }
        samplePaint = false;
        expect(paintErrors, isNotEmpty);
        expect(
          paintErrors.reduce(
            (first, second) => first > second ? first : second,
          ),
          lessThan(0.1),
          reason:
              'Scroll reflow must be compensated before painting each frame',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Android lyrics tolerate a first viewport shorter than the header',
    (tester) async {
      for (final height in [0.0, 64.0, 120.0, 160.0]) {
        await pumpLyrics(tester, viewportHeight: height, topInset: 128);
        expect(tester.takeException(), isNull);
        expect(find.text('First words'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'Android translation changes do not reset manual lyric browsing',
    (tester) async {
      await pumpLyrics(tester);
      await tester.drag(find.byType(LyricsView), const Offset(0, -100));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(LyricsView),
          matching: find.byType(Scrollable),
        ),
      );
      final browsedOffset = scrollable.position.pixels;
      expect(browsedOffset, greaterThan(20));
      await tester.tap(find.byType(LyricsTranslationButton));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, closeTo(browsedOffset, 0.5));
      await tester.tap(find.byType(LyricsTranslationButton));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, closeTo(browsedOffset, 0.5));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Android playback can change lines during translation reflow', (
    tester,
  ) async {
    final (_, playback) = await pumpLyrics(tester);
    playback.positionNotifier.value = const Duration(seconds: 9);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LyricsTranslationButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final nextLine = find.text('Second words');
    final beforeSwitch = tester.getTopLeft(nextLine).dy;
    playback.positionNotifier.value = const Duration(seconds: 13);
    await tester.pump();
    expect(tester.getTopLeft(nextLine).dy, closeTo(beforeSwitch, 0.5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(nextLine).dy, lessThan(beforeSwitch));
    await tester.pumpAndSettle();
    expect(find.text('第二句歌词'), findsNothing);
    expect(tester.getTopLeft(nextLine).dy, closeTo(187.36, 0.5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android community translations are opt-in and persisted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    final preferences = PreferencesProvider(storage);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: preferences,
        child: androidApp(const SingleChildScrollView(child: LyricsSection())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('社区歌词翻译'), findsOneWidget);
    final communitySwitch = find.descendant(
      of: find.widgetWithText(SettingsSwitchTile, '社区歌词翻译'),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(communitySwitch).value, isFalse);
    await tester.ensureVisible(communitySwitch);
    await tester.pumpAndSettle();
    await tester.tap(communitySwitch);
    await tester.pumpAndSettle();
    expect(preferences.prefs.lyricsBilingual, isTrue);
    expect(
      AppPreferences.decode(storage.preferencesJson).lyricsBilingual,
      isTrue,
    );
    await tester.tap(communitySwitch);
    await tester.pumpAndSettle();
    expect(preferences.prefs.lyricsBilingual, isFalse);
    expect(
      AppPreferences.decode(storage.preferencesJson).lyricsBilingual,
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _PositionNotifier extends ValueNotifier<Duration> {
  _PositionNotifier(super.value);

  bool get observed => hasListeners;
}
