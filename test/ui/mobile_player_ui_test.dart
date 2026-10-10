import 'dart:ui' as ui;

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/appearance_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutify_app/ui/screens/player/player_expansion.dart';
import 'package:flutify_app/ui/screens/player/player_lyrics_motion.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutify_app/ui/screens/player/queue_list.dart';
import 'package:flutify_app/ui/screens/player/widgets/swipeable_artwork.dart';
import 'package:flutify_app/ui/shell/mobile/mobile_bottom_bar.dart';
import 'package:flutify_app/ui/widgets/mini_player.dart';
import 'package:flutify_app/ui/widgets/marquee_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_track_audio_source.dart';

/// 移动端第 5 步界面：毛玻璃底部导航、胶囊迷你播放器、全屏播放器的内嵌视图与滑动切歌。
/// 只使用本文件内的合成曲目，不依赖任何账号或示例数据。
void main() {
  const tracks = [
    SpotifyTrack(id: 'synthetic-1', name: 'Synthetic One', durationMs: 180000),
    SpotifyTrack(id: 'synthetic-2', name: 'Synthetic Two', durationMs: 200000),
    SpotifyTrack(
      id: 'synthetic-3',
      name: 'Synthetic Three',
      durationMs: 220000,
    ),
  ];

  Future<PlaybackProvider> pumpPlaying(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
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
        spotifyApiService: SpotifyApiService(storage),
        trackAudioLoader: FakeTrackAudioSource(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final playback = Provider.of<PlaybackProvider>(
      tester.element(find.byType(MainShell)),
      listen: false,
    );
    await playback.playTrack(
      tracks.first,
      contextQueue: tracks,
      context: const PlaybackContext.playlist(
        'Synthetic Mix',
        uri: 'spotify:playlist:synthetic',
      ),
    );
    await settle(tester);
    return playback;
  }

  for (final screenWidth in [320.0, 390.0]) {
    testWidgets('android compact title covers both edges at $screenWidth', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final playback = await pumpPlaying(tester, size: Size(screenWidth, 844));
      const longTrack = SpotifyTrack(
        id: 'synthetic-mask',
        name: 'A Synthetic Song With A Long Scrolling Title For Edge Coverage',
        durationMs: 180000,
      );
      await playback.playTrack(longTrack, contextQueue: [longTrack]);
      await settle(tester);
      await tester.pump(const Duration(seconds: 5));

      final title = find.descendant(
        of: find.byType(MiniPlayer),
        matching: find.byType(MarqueeText),
      );
      final maskFinder = find.descendant(
        of: title,
        matching: find.bySubtype<ShaderMask>(),
      );
      expect(maskFinder, findsOneWidget);
      final mask = tester.widget<ShaderMask>(maskFinder);
      final bounds = Offset.zero & tester.getSize(maskFinder);

      await tester.runAsync(() async {
        for (final pixelRatio in [1.0, 2.625, 3.0]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..scale(pixelRatio);
          canvas.drawRect(
            bounds,
            Paint()..shader = mask.shaderCallback(bounds),
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(
            (bounds.width * pixelRatio).ceil(),
            (bounds.height * pixelRatio).ceil(),
          );
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final middleRow = image.height ~/ 2;
          for (final column in [
            0,
            1,
            2,
            3,
            image.width - 4,
            image.width - 3,
            image.width - 2,
            image.width - 1,
          ]) {
            expect(
              bytes.getUint8((middleRow * image.width + column) * 4 + 3),
              0,
              reason: 'compact title edge $column at DPR $pixelRatio',
            );
          }
          expect(
            bytes.getUint8(
              (middleRow * image.width + image.width ~/ 2) * 4 + 3,
            ),
            255,
          );
          image.dispose();
          picture.dispose();
        }
      });
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final closeMethod in ['button', 'back', 'drag']) {
    testWidgets('android mini title restarts after every $closeMethod collapse', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final playback = await pumpPlaying(tester);
      const longTrack = SpotifyTrack(
        id: 'synthetic-marquee',
        name:
            'A Synthetic Song With A Very Long Title That Keeps Scrolling In The Mini Player',
        durationMs: 180000,
      );
      await playback.playTrack(longTrack, contextQueue: [longTrack]);
      await settle(tester);
      double titleOffset() {
        final title = find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.byType(MarqueeText),
        );
        final scroll = find.descendant(
          of: title,
          matching: find.byType(SingleChildScrollView),
        );
        return tester.widget<SingleChildScrollView>(scroll).controller!.offset;
      }

      await tester.pump(const Duration(milliseconds: 4500));
      for (var repetition = 0; repetition < 2; repetition++) {
        expect(titleOffset(), greaterThan(0));
        await tester.tap(find.byType(MiniPlayer));
        await settle(tester);
        await tester.pump(const Duration(seconds: 2));
        final close = find.descendant(
          of: find.byType(FullPlayerSheet),
          matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
        );
        switch (closeMethod) {
          case 'button':
            await tester.tap(close);
          case 'back':
            await tester.binding.handlePopRoute();
          case 'drag':
            await tester.drag(close, const Offset(0, 200));
        }
        await tester.pump();
        for (var frame = 0; frame < 10; frame++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        expect(find.byType(FullPlayerSheet), findsNothing);
        expect(titleOffset(), 0);
        await tester.pump(const Duration(seconds: 3));
        expect(titleOffset(), 0);
        await tester.pump(const Duration(milliseconds: 1500));
        expect(titleOffset(), greaterThan(0));
      }
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('glass navigation bar with the pill mini player above it', (
    tester,
  ) async {
    await pumpPlaying(tester);

    final bar = find.byType(MobileBottomBar);
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(MiniPlayer)),
      findsOneWidget,
    );
    // 迷你播放器在导航栏上方
    expect(
      tester.getBottomLeft(find.byType(MiniPlayer)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(NavigationBar)).dy),
    );
    expect(find.text('Synthetic One'), findsWidgets);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform player switches between artwork, lyrics and queue', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await pumpPlaying(tester);

      await tester.tap(find.byType(MiniPlayer));
      await settle(tester);
      final player = find.byType(FullPlayerSheet);
      expect(
        find.descendant(of: player, matching: find.byType(SwipeableArtwork)),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(of: player, matching: find.byTooltip('播放队列')),
      );
      await settle(tester);
      expect(
        find.descendant(of: player, matching: find.byType(QueueList)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: player, matching: find.byType(SwipeableArtwork)),
        platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        reason: 'only Android keeps the shared artwork in the queue card',
      );

      await tester.tap(
        find.descendant(of: player, matching: find.byTooltip('歌词')),
      );
      await settle(tester);
      expect(
        find.descendant(of: player, matching: find.byType(LyricsView)),
        findsOneWidget,
      );
      expect(find.byTooltip('全屏歌词'), findsNothing);

      // 再点一次当前视图的按钮回到封面
      await tester.tap(
        find.descendant(of: player, matching: find.byTooltip('歌词')),
      );
      await settle(tester);
      expect(
        find.descendant(of: player, matching: find.byType(SwipeableArtwork)),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'folded lyrics card blank tap reveals only after release ($reduced)',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reduced);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await pumpPlaying(tester);
        await tester.tap(find.byType(MiniPlayer));
        await settle(tester);
        final player = find.byType(FullPlayerSheet);
        final lyricsButton = find.descendant(
          of: player,
          matching: find.byTooltip('歌词'),
        );
        await tester.tap(lyricsButton);
        await settle(tester);
        final lyricsState = tester.state(find.byType(LyricsView));
        final card = find.byKey(const ValueKey('lyrics-control-card'));
        final expanded = tester.getRect(card);
        await tester.pump(PlayerLyricsMotion.idleDelay);
        await tester.pump(
          PlayerLyricsMotion.foldDuration + const Duration(milliseconds: 1),
        );
        final folded = tester.getRect(card);
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
        final blank = Offset(
          (deviceButton.right + tester.getRect(lyricsButton).left) / 2,
          folded.center.dy,
        );
        expect(blank.dx, greaterThan(deviceButton.right));
        final tap = await tester.startGesture(blank);
        await tester.pump();
        expect(tester.getRect(card), folded);
        await tap.moveBy(const Offset(0, 4));
        await tester.pump();
        expect(tester.getRect(card), folded);
        await tap.up();
        await tester.pump();
        await tester.pump(
          PlayerLyricsMotion.chromeDuration + const Duration(milliseconds: 1),
        );
        expect(tester.getRect(card), expanded);
        expect(tester.state(find.byType(LyricsView)), same(lyricsState));
        await tester.dragFrom(blank, const Offset(0, -60));
        await tester.pump();
        await tester.pump(
          PlayerLyricsMotion.foldDuration + const Duration(milliseconds: 1),
        );
        expect(tester.getRect(card), folded);
        await tester.dragFrom(blank, const Offset(60, 0));
        await tester.pump(const Duration(milliseconds: 301));
        expect(tester.getRect(card), folded);
        final cancelled = await tester.startGesture(blank);
        await cancelled.cancel();
        await tester.pump(const Duration(milliseconds: 301));
        expect(tester.getRect(card), folded);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'folded lyrics footer tap enters queue without reopening ($reduced)',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(disableAnimations: reduced);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        try {
          await pumpPlaying(tester);
          await tester.tap(find.byType(MiniPlayer));
          await settle(tester);
          final player = find.byType(FullPlayerSheet);
          await tester.tap(
            find.descendant(of: player, matching: find.byTooltip('歌词')),
          );
          await settle(tester);
          final card = find.byKey(const ValueKey('lyrics-control-card'));
          final expanded = tester.getRect(card);
          await tester.pump(const Duration(milliseconds: 3500));
          await tester.pump(
            PlayerLyricsMotion.foldDuration + const Duration(milliseconds: 1),
          );
          final folded = tester.getRect(card);
          expect(folded.top, greaterThan(expanded.top));
          await tester.tap(
            find.descendant(of: player, matching: find.byTooltip('播放队列')),
          );
          await tester.pump();
          for (var frame = 0; frame < 33; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              tester.getRect(card),
              folded,
              reason: 'handoff frame $frame',
            );
          }
          expect(find.byType(QueueList), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets('android queue card preserves reorder, swipe removal and play', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final playback = await pumpPlaying(tester);
    await tester.tap(find.byType(MiniPlayer));
    await settle(tester);
    final player = find.byType(FullPlayerSheet);
    await tester.tap(
      find.descendant(of: player, matching: find.byTooltip('播放队列')),
    );
    await settle(tester);
    final queue = find.byType(QueueList);
    final queueElement = tester.element(queue);
    final handles = find.descendant(
      of: queue,
      matching: find.byType(ReorderableDragStartListener),
    );
    expect(handles, findsNWidgets(2));
    expect(handles.last.hitTestable(), findsOneWidget);
    final drag = await tester.startGesture(tester.getCenter(handles.last));
    await tester.pump();
    for (var step = 0; step < 10; step++) {
      await drag.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await drag.up();
    await settle(tester);
    expect(playback.upNext.map((entry) => entry.track.id), [
      'synthetic-3',
      'synthetic-2',
    ]);
    final removeRow = find.ancestor(
      of: find.descendant(of: queue, matching: find.text('Synthetic Two')),
      matching: find.byType(Dismissible),
    );
    await tester.drag(removeRow, const Offset(-380, 0));
    await settle(tester);
    expect(playback.upNext.single.track.id, 'synthetic-3');
    await tester.tap(
      find.descendant(of: queue, matching: find.text('Synthetic Three')),
    );
    await settle(tester);
    expect(playback.currentTrack?.id, 'synthetic-3');
    expect(tester.element(queue), same(queueElement));
    expect(
      find.descendant(of: player, matching: find.byType(SwipeableArtwork)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final size in [const Size(320, 480), const Size(740, 390)]) {
    testWidgets('android queue fits $size with large text and reduced motion', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpPlaying(tester);
      await tester.tap(find.byType(MiniPlayer));
      await settle(tester);
      // Resize the already-open Android full-screen route, including landscape.
      tester.view.physicalSize = size;
      await settle(tester);
      final player = find.byType(FullPlayerSheet);
      final toggle = find.descendant(
        of: player,
        matching: find.byTooltip('播放队列'),
      );
      await tester.tap(toggle);
      await tester.pump();
      final queue = tester.getRect(find.byType(QueueList));
      final card = tester.getRect(
        find.byKey(const ValueKey('lyrics-control-card')),
      );
      expect(queue.height, greaterThan(0));
      expect((Offset.zero & size).contains(queue.topLeft), isTrue);
      expect(queue.bottom, lessThanOrEqualTo(size.height));
      expect(queue.overlaps(card), isFalse);
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(size.height));
      await tester.tap(toggle);
      await tester.pump();
      expect(find.byType(QueueList), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('android player expands from the pill and morphs its artwork', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPlaying(tester);
    final origin = tester.getRect(
      find.byKey(const ValueKey('mini-player-expansion-source')),
    );
    final artworkOrigin = tester.getRect(find.byType(Hero));

    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump();
    expect(find.byType(BottomSheet), findsNothing);

    Rect surface() {
      final clip = tester.widget<ClipPath>(
        find.byKey(const ValueKey('player-expansion-surface')),
      );
      return clip.clipper!.getClip(const Size(390, 844)).getBounds();
    }

    expect(surface(), origin);
    await tester.pump(const Duration(milliseconds: 120));
    final expanding = surface();
    expect(expanding.top, lessThan(origin.top));
    expect(expanding.bottom, greaterThan(origin.bottom));
    expect(
      origin.top - expanding.top,
      greaterThan(expanding.bottom - origin.bottom),
    );
    expect(expanding.top, greaterThan(0));
    expect(expanding.bottom, lessThan(844));

    final artwork = tester.getRect(
      find.byKey(const ValueKey('player-artwork-flight')),
    );
    expect(artwork.top, lessThan(artworkOrigin.top));
    expect(artwork.left, greaterThan(artworkOrigin.left));
    expect(artwork.width, greaterThan(artworkOrigin.width));
    final artworkClip = tester.widget<ClipRRect>(
      find.byKey(const ValueKey('player-artwork-flight')),
    );
    expect(
      (artworkClip.borderRadius as BorderRadius).topLeft.x,
      lessThan(artwork.width / 2),
    );
    final compact = tester.widget<Opacity>(
      find.byKey(const ValueKey('player-expansion-compact')),
    );
    expect(compact.opacity, inExclusiveRange(0, 1));
    final controls = tester.widget<Opacity>(
      find.byKey(const ValueKey('player-expansion-controls')),
    );
    expect(controls.opacity, inExclusiveRange(0, 1));

    await tester.pump(const Duration(milliseconds: 480));
    expect(surface(), const Rect.fromLTWH(0, 0, 390, 844));
    await settle(tester);
    expect(find.byKey(const ValueKey('player-artwork-flight')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('android player reverses the morph and restores its pill', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPlaying(tester);
    final origin = tester.getRect(
      find.byKey(const ValueKey('mini-player-expansion-source')),
    );
    final originalBarriers = find.byType(ModalBarrier).evaluate().length;
    await tester.tap(find.byType(MiniPlayer));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final clip = tester.widget<ClipPath>(
      find.byKey(const ValueKey('player-expansion-surface')),
    );
    final closing = clip.clipper!.getClip(const Size(390, 844)).getBounds();
    expect(closing.top, inExclusiveRange(0, origin.top));
    expect(closing.bottom, inExclusiveRange(origin.bottom, 844));
    await settle(tester);
    expect(find.byType(FullPlayerSheet), findsNothing);
    expect(find.byType(ModalBarrier), findsNWidgets(originalBarriers));
    expect(tester.getRect(find.byType(Hero)).size, const Size(44, 44));
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  for (final closeMethod in ['button', 'back', 'drag']) {
    testWidgets('android $closeMethod collapse restores info with artwork', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await pumpPlaying(tester);
      final origin = tester.getRect(
        find.byKey(const ValueKey('mini-player-expansion-source')),
      );
      final artworkOrigin = tester.getRect(find.byType(Hero));
      await tester.tap(find.byType(MiniPlayer));
      await settle(tester);
      final expandedArtwork = tester.getRect(
        find.descendant(
          of: find.byType(FullPlayerSheet),
          matching: find.byType(Hero),
        ),
      );
      final close = find.byIcon(Icons.keyboard_arrow_down_rounded);
      switch (closeMethod) {
        case 'button':
          await tester.tap(close);
        case 'back':
          await tester.binding.handlePopRoute();
        case 'drag':
          await tester.drag(close, const Offset(0, 200));
      }
      await tester.pump();
      await tester.pump();

      // Sample the entire return, including the first 68% when the old compact
      // row stayed hidden even though the artwork was already moving home.
      for (var frame = 0; frame < 7; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
        final artwork = tester.getRect(
          find.byKey(const ValueKey('player-artwork-flight')),
        );
        final returned =
            (expandedArtwork.width - artwork.width) /
            (expandedArtwork.width - artworkOrigin.width);
        final compact = find.byKey(const ValueKey('player-expansion-compact'));
        expect(compact, findsOneWidget);
        expect(
          tester.widget<Opacity>(compact).opacity,
          closeTo(returned, 0.001),
          reason: 'Song info and buttons must fade in as the artwork returns',
        );
        final rowReturned =
            (tester.getTopLeft(compact).dy + 16) / (origin.top + 16);
        expect(
          rowReturned,
          closeTo(returned, 0.001),
          reason: 'The compact row must travel home on the artwork timeline',
        );
      }
      await settle(tester);
      expect(find.byType(FullPlayerSheet), findsNothing);
      expect(tester.getRect(find.byType(Hero)), artworkOrigin);
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('android player respects reduced motion', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPlaying(tester);
    final appearance = tester
        .element(find.byType(MainShell))
        .read<AppearanceProvider>();
    appearance.update(appearance.settings.copyWith(reduceMotion: true));
    await tester.pump();
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump();
    expect(find.byType(FullPlayerSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('player-artwork-flight')), findsNothing);
    final clip = tester.widget<ClipPath>(
      find.byKey(const ValueKey('player-expansion-surface')),
    );
    expect(
      clip.clipper!.getClip(const Size(390, 844)).getBounds(),
      const Rect.fromLTWH(0, 0, 390, 844),
    );
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    await tester.pump();
    expect(find.byType(FullPlayerSheet), findsNothing);
    expect(
      find.byKey(const ValueKey('player-expansion-compact')),
      findsNothing,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('android player can reverse mid-expansion without jumping', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpPlaying(tester);
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    Rect surface() => tester
        .widget<ClipPath>(
          find.byKey(const ValueKey('player-expansion-surface')),
        )
        .clipper!
        .getClip(const Size(390, 844))
        .getBounds();
    final before = surface();
    final compact = find.byKey(const ValueKey('player-expansion-compact'));
    final compactBefore = tester.getRect(compact);
    final opacityBefore = tester.widget<Opacity>(compact).opacity;
    Navigator.pop(tester.element(find.byType(FullPlayerSheet)));
    await tester.pump();
    expect(surface(), before);
    expect(tester.getRect(compact), compactBefore);
    expect(tester.widget<Opacity>(compact).opacity, opacityBefore);
    await tester.pump(const Duration(milliseconds: 16));
    expect(surface().height, lessThan(before.height));
    expect(tester.widget<Opacity>(compact).opacity, greaterThan(opacityBefore));
    await settle(tester);
    expect(find.byType(FullPlayerSheet), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'navigation pill reserves the bottom inset only outside its contents',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 34);
      await pumpPlaying(tester);
      final nav = find.byType(NavigationBar);
      final pill = tester.getRect(nav);
      expect(pill.height, 64);
      expect(844 - pill.bottom, 34 + 12);
      for (final element in find.byType(NavigationDestination).evaluate()) {
        final destination = tester.getRect(find.byWidget(element.widget));
        expect(destination.center.dy, pill.center.dy);
      }
      await tester.tap(find.byIcon(Icons.search_rounded).first);
      await settle(tester);
      expect(tester.widget<NavigationBar>(nav).selectedIndex, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('swiping the artwork changes tracks', (tester) async {
    final playback = await pumpPlaying(tester);

    await tester.tap(find.byType(MiniPlayer));
    await settle(tester);

    await tester.drag(find.byType(SwipeableArtwork), const Offset(-220, 0));
    await settle(tester);
    expect(playback.currentTrack?.id, 'synthetic-2');

    // 小幅拖动不切歌，松手回弹
    await tester.drag(find.byType(SwipeableArtwork), const Offset(-20, 0));
    await settle(tester);
    expect(playback.currentTrack?.id, 'synthetic-2');
  });

  testWidgets('swiping lyrics down removes the sheet and its modal barrier', (
    tester,
  ) async {
    final playback = await pumpPlaying(tester);
    final originalBarriers = find.byType(ModalBarrier).evaluate().length;
    await tester.tap(find.byType(MiniPlayer));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(FullPlayerSheet),
        matching: find.byTooltip('歌词'),
      ),
    );
    await settle(tester);
    final close = find.descendant(
      of: find.byType(FullPlayerSheet),
      matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
    );
    await tester.fling(close, const Offset(0, 650), 1500);
    await playback.nextTrack();
    await settle(tester);
    expect(find.byType(FullPlayerSheet), findsNothing);
    expect(find.byType(ModalBarrier), findsNWidgets(originalBarriers));
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid repeated opens cannot leave a second player modal underneath',
    (tester) async {
      await pumpPlaying(tester);
      final originalBarriers = find.byType(ModalBarrier).evaluate().length;
      final context = tester.element(find.byType(MiniPlayer));
      FullPlayerSheet.show(context);
      FullPlayerSheet.show(context);
      await settle(tester);
      expect(find.byType(FullPlayerSheet, skipOffstage: false), findsOneWidget);
      await tester.fling(
        find.byIcon(Icons.keyboard_arrow_down_rounded).last,
        const Offset(0, 650),
        1500,
      );
      await settle(tester);
      expect(find.byType(ModalBarrier), findsNWidgets(originalBarriers));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player opened from the mini player respects display cutouts', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 34);
    await pumpPlaying(tester);

    await tester.tap(find.byType(MiniPlayer));
    await settle(tester);
    final close = find.descendant(
      of: find.byType(FullPlayerSheet),
      matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
    );
    expect(tester.getTopLeft(close).dy, greaterThanOrEqualTo(48));

    await tester.tap(close);
    await settle(tester);
    expect(find.byType(FullPlayerSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'android: full player squares its top corners so they cover the screen',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpPlaying(tester);
      await tester.tap(find.byType(MiniPlayer));
      await settle(tester);
      debugDefaultTargetPlatformOverride = null;

      final clip = tester.widget<ClipRRect>(
        find
            .descendant(
              of: find.byType(FullPlayerSheet),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(clip.borderRadius, BorderRadius.zero);
      expect(tester.takeException(), isNull);
    },
  );

  for (final startsAsDialog in [false, true]) {
    testWidgets(
      'android: corners follow the open route after resize (dialog=$startsAsDialog)',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await pumpPlaying(
          tester,
          size: startsAsDialog ? const Size(900, 1000) : const Size(700, 1000),
        );
        FullPlayerSheet.show(tester.element(find.byType(MainShell)));
        await settle(tester);
        BorderRadiusGeometry radius() => tester
            .widget<ClipRRect>(
              find
                  .descendant(
                    of: find.byType(FullPlayerSheet),
                    matching: find.byType(ClipRRect),
                  )
                  .first,
            )
            .borderRadius;
        final initialRadius = radius();
        expect(initialRadius == BorderRadius.zero, !startsAsDialog);
        tester.view.physicalSize = startsAsDialog
            ? const Size(700, 1000)
            : const Size(1000, 700);
        await settle(tester);
        debugDefaultTargetPlatformOverride = null;
        expect(
          find.byType(startsAsDialog ? Dialog : PlayerExpansionTransition),
          findsOneWidget,
        );
        expect(radius(), initialRadius);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('other platforms keep the rounded top corners', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pumpPlaying(tester);
    await tester.tap(find.byType(MiniPlayer));
    await settle(tester);
    debugDefaultTargetPlatformOverride = null;

    final clip = tester.widget<ClipRRect>(
      find
          .descendant(
            of: find.byType(FullPlayerSheet),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(clip.borderRadius, isNot(BorderRadius.zero));
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
