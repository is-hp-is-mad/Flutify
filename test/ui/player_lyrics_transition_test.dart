import 'package:flutify_app/ui/screens/player/android_player_scene.dart';
import 'package:flutify_app/ui/screens/player/player_lyrics_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ValueNotifier<bool>> pumpScene(
    WidgetTester tester, {
    Size size = const Size(390, 800),
    bool reduceMotion = false,
    VoidCallback? onPlay,
    VoidCallback? onLyricsTap,
    GestureDragUpdateCallback? onLyricsDrag,
    VoidCallback? onFooterTap,
    VoidCallback? onArtworkTap,
    ValueNotifier<bool>? interactionSuspended,
    ValueNotifier<bool>? tickerEnabled,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final lyrics = ValueNotifier(false);
    addTearDown(lyrics.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: reduceMotion),
          child: Material(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                lyrics,
                interactionSuspended,
                tickerEnabled,
              ]),
              builder: (context, _) => TickerMode(
                enabled: tickerEnabled?.value ?? true,
                child: AndroidPlayerScene(
                  lyricsMode: lyrics.value,
                  interactionSuspended: interactionSuspended?.value ?? false,
                  onArtworkTap: onArtworkTap,
                  queueMode: false,
                  background: const ColoredBox(color: Colors.indigo),
                  lyricsBackground: const ColoredBox(color: Colors.teal),
                  topBar: const SizedBox(height: 56),
                  title: const SizedBox(key: ValueKey('title'), height: 56),
                  controls: SizedBox(
                    height: 100,
                    child: TextButton(
                      onPressed: onPlay,
                      child: const Text('Play'),
                    ),
                  ),
                  footer: SizedBox(
                    key: const ValueKey('footer'),
                    height: 48,
                    child: TextButton(
                      onPressed: onFooterTap ?? () {},
                      child: const Text('Footer'),
                    ),
                  ),
                  artworkBuilder: (context, size, progress) => const ColoredBox(
                    key: ValueKey('cover'),
                    color: Colors.blue,
                  ),
                  lyrics: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onLyricsTap,
                    onVerticalDragUpdate: onLyricsDrag,
                    child: const ColoredBox(
                      key: ValueKey('lyrics'),
                      color: Colors.transparent,
                    ),
                  ),
                  translation: const SizedBox(
                    key: ValueKey('translation'),
                    width: 48,
                    height: 48,
                  ),
                  queue: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return lyrics;
  }

  testWidgets('small artwork handles its tap without seeking a lyric', (
    tester,
  ) async {
    var artworkTaps = 0;
    var lyricTaps = 0;
    final mode = await pumpScene(
      tester,
      reduceMotion: true,
      onArtworkTap: () => artworkTaps++,
      onLyricsTap: () => lyricTaps++,
    );
    mode.value = true;
    await tester.pump();
    final coverPosition = tester.getCenter(find.byKey(const ValueKey('cover')));
    await tester.tapAt(coverPosition);
    expect(artworkTaps, 1);
    expect(lyricTaps, 0);
    await tester.pump(const Duration(milliseconds: 3500));
    await tester.tapAt(coverPosition);
    expect(artworkTaps, 1, reason: 'folded artwork has no ghost tap target');
    expect(lyricTaps, 1, reason: 'the exposed lyric region is usable');
  });

  testWidgets(
    'repeated wake, held gestures, cancel and mode changes re-arm idle',
    (tester) async {
      final mode = await pumpScene(tester, reduceMotion: true);
      mode.value = true;
      await tester.pump();
      for (var cycle = 0; cycle < 3; cycle++) {
        await tester.pump(const Duration(milliseconds: 3500));
        expect(find.text('Play').hitTestable(), findsNothing);
        final gesture = await tester.startGesture(const Offset(100, 300));
        await gesture.moveBy(const Offset(0, 60));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        expect(find.text('Play').hitTestable(), findsOneWidget);
        if (cycle == 2) {
          mode.value = false;
          await tester.pump();
          mode.value = true;
          await tester.pump();
        }
        await gesture.moveTo(const Offset(-20, 420));
        if (cycle == 1) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pump(const Duration(milliseconds: 3499));
        expect(find.text('Play').hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 1));
        expect(find.text('Play').hitTestable(), findsNothing);
      }
    },
  );

  testWidgets('modal suspension holds card open then re-arms after dismissal', (
    tester,
  ) async {
    final suspended = ValueNotifier(false);
    addTearDown(suspended.dispose);
    final mode = await pumpScene(
      tester,
      reduceMotion: true,
      interactionSuspended: suspended,
    );
    mode.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.text('Play').hitTestable(), findsNothing);
    suspended.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('Play').hitTestable(), findsOneWidget);
    suspended.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3499));
    expect(find.text('Play').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Play').hitTestable(), findsNothing);
  });

  testWidgets(
    'lifecycle cannot activate a ticker-muted scene or retain a touch',
    (tester) async {
      final ticker = ValueNotifier(true);
      addTearDown(ticker.dispose);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final mode = await pumpScene(
        tester,
        reduceMotion: true,
        tickerEnabled: ticker,
      );
      mode.value = true;
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(100, 300));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      ticker.value = false;
      await tester.pump();
      await gesture.cancel();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('Play').hitTestable(), findsOneWidget);
      ticker.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3500));
      expect(find.text('Play').hitTestable(), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Play').hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 3500));
      expect(find.text('Play').hitTestable(), findsNothing);
    },
  );

  testWidgets(
    'visible card blank regions never seek or drag lyrics behind it',
    (tester) async {
      var lyricTaps = 0;
      var lyricDrags = 0;
      final mode = await pumpScene(
        tester,
        onLyricsTap: () => lyricTaps++,
        onLyricsDrag: (_) => lyricDrags++,
      );
      mode.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 641));
      final card = tester.getRect(
        find.byKey(const ValueKey('lyrics-control-card')),
      );
      final blank = Offset(card.left + 4, card.top + 24);
      await tester.tapAt(blank);
      await tester.dragFrom(blank, const Offset(0, 50));
      expect(lyricTaps, 0);
      expect(lyricDrags, 0);
    },
  );

  for (final step in [
    const Duration(microseconds: 16667),
    const Duration(microseconds: 8333),
  ]) {
    testWidgets(
      'card top retracts down nonlinearly with fixed usable footer at $step',
      (tester) async {
        var footerTaps = 0;
        final mode = await pumpScene(tester, onFooterTap: () => footerTaps++);
        mode.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 641));
        final cardFinder = find.byKey(const ValueKey('lyrics-control-card'));
        final expanded = tester.getRect(cardFinder);
        final footer = tester.getRect(find.byKey(const ValueKey('footer')));
        await tester.pump(const Duration(milliseconds: 3500));
        await tester.pump();
        var previousTop = expanded.top;
        var elapsed = Duration.zero;
        while (elapsed < PlayerLyricsMotion.foldDuration) {
          await tester.pump(step);
          elapsed += step;
          final card = tester.getRect(cardFinder);
          expect(card.top, greaterThanOrEqualTo(previousTop));
          expect(card.bottom, expanded.bottom);
          expect(tester.getRect(find.byKey(const ValueKey('footer'))), footer);
          if (elapsed >= const Duration(milliseconds: 70) &&
              elapsed <= const Duration(milliseconds: 90)) {
            expect(card.top, greaterThan((expanded.top + footer.top) / 2));
          }
          previousTop = card.top;
        }
        expect(tester.getRect(cardFinder).top, footer.top);
        expect(find.text('Play').hitTestable(), findsNothing);
        expect(find.text('Footer').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Footer'));
        expect(footerTaps, 1);
      },
    );
  }

  testWidgets('shared artwork and title move into the low card nonlinearly', (
    tester,
  ) async {
    final mode = await pumpScene(tester);
    final cover = find.byKey(const ValueKey('cover'));
    final title = find.byKey(const ValueKey('title'));
    final startCover = tester.getRect(cover);
    final startTitle = tester.getRect(title);
    mode.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final middleCover = tester.getRect(cover);
    final middleTitle = tester.getRect(title);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('lyrics'))).dy,
      greaterThan(56),
    );
    await tester.pump(const Duration(milliseconds: 480));
    final endCover = tester.getRect(cover);
    final endTitle = tester.getRect(title);
    expect(cover, findsOneWidget);
    expect(endCover.width, inInclusiveRange(56, 64));
    expect(endCover.top, greaterThan(500));
    expect(endCover.right + 8, lessThanOrEqualTo(endTitle.left));
    expect(
      middleCover.width,
      lessThan((startCover.width + endCover.width) / 2),
    );
    expect(
      middleTitle.left,
      greaterThan((startTitle.left + endTitle.left) / 2),
    );
    final card = tester.getRect(
      find.byKey(const ValueKey('lyrics-control-card')),
    );
    expect(card.bottom, 792);
    expect(
      tester.getBottomRight(find.byKey(const ValueKey('translation'))).dy,
      closeTo(card.top - 8, 0.01),
    );
    mode.value = false;
    await tester.pump();
    final toolbarOpacity = find.ancestor(
      of: find.byKey(const ValueKey('translation')),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(toolbarOpacity).opacity, 1);
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      tester.widget<Opacity>(toolbarOpacity).opacity,
      inExclusiveRange(0, 0.5),
    );
    await tester.pump(const Duration(milliseconds: 481));
    expect(tester.getRect(cover), startCover);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'idle hides card and toolbar; downward swipe reveals without playing',
    (tester) async {
      var presses = 0;
      final mode = await pumpScene(tester, onPlay: () => presses++);
      mode.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 641));
      final playPosition = tester.getCenter(find.text('Play'));
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(PlayerLyricsMotion.foldDuration);
      expect(find.text('Play').hitTestable(), findsNothing);
      expect(
        find.byKey(const ValueKey('translation')).hitTestable(),
        findsNothing,
      );
      final lyricsElement = tester.element(
        find.byKey(const ValueKey('lyrics')),
      );
      await tester.tapAt(playPosition);
      await tester.pump();
      expect(
        find.text('Play').hitTestable(),
        findsNothing,
        reason: 'a reveal must not activate controls before they are visible',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(presses, 0);
      expect(find.text('Play').hitTestable(), findsNothing);
      await tester.dragFrom(const Offset(100, 300), const Offset(0, 60));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Play').hitTestable(), findsOneWidget);
      expect(
        tester.element(find.byKey(const ValueKey('lyrics'))),
        lyricsElement,
      );
      await tester.tap(find.text('Play'));
      expect(presses, 1);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets('folded lyrics only reveal on a downward swipe ($reduced)', (
      tester,
    ) async {
      final mode = await pumpScene(tester, reduceMotion: reduced);
      mode.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 641));
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(PlayerLyricsMotion.foldDuration);
      final card = find.byKey(const ValueKey('lyrics-control-card'));
      final folded = tester.getRect(card);

      for (final movement in [
        Offset.zero,
        const Offset(0, -60),
        const Offset(60, 4),
      ]) {
        final gesture = await tester.startGesture(const Offset(100, 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.getRect(card), folded);
        await gesture.moveBy(movement);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.getRect(card), folded);
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.getRect(card), folded);
        expect(find.text('Play').hitTestable(), findsNothing);
      }

      final gesture = await tester.startGesture(const Offset(100, 300));
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(card), folded);
      await gesture.moveBy(const Offset(0, 32));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(card).top, lessThan(folded.top));
      expect(find.text('Play').hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Play').hitTestable(), findsOneWidget);
      await gesture.cancel();
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(PlayerLyricsMotion.foldDuration);
      expect(tester.getRect(card), folded);
      expect(find.text('Play').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final reduced in [false, true]) {
    testWidgets('upward swipes fold the visible lyrics card ($reduced)', (
      tester,
    ) async {
      var lyricDrags = 0;
      final mode = await pumpScene(
        tester,
        reduceMotion: reduced,
        onLyricsDrag: (_) => lyricDrags++,
      );
      mode.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 641));
      final card = find.byKey(const ValueKey('lyrics-control-card'));
      final expanded = tester.getRect(card);
      final footer = tester.getRect(find.byKey(const ValueKey('footer')));
      await tester.dragFrom(const Offset(100, 300), const Offset(0, -60));
      await tester.pump();
      await tester.pump(PlayerLyricsMotion.foldDuration);
      expect(tester.getRect(card).top, footer.top);
      expect(find.text('Play').hitTestable(), findsNothing);
      expect(lyricDrags, greaterThan(0));
      await tester.dragFrom(const Offset(100, 300), const Offset(0, 60));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(card), expanded);
      expect(find.text('Play').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('metadata never reverses direction during the card handoff', (
    tester,
  ) async {
    final mode = await pumpScene(tester);
    final title = find.byKey(const ValueKey('title'));
    var previous = tester.getRect(title);
    mode.value = true;
    await tester.pump();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final rect = tester.getRect(title);
      expect(
        rect.left,
        greaterThanOrEqualTo(previous.left),
        reason: 'handoff frame $frame',
      );
      expect(
        rect.width,
        lessThanOrEqualTo(previous.width),
        reason: 'handoff frame $frame',
      );
      previous = rect;
    }
  });

  for (final size in [const Size(320, 480), const Size(844, 390)]) {
    testWidgets('compact scene fits $size with reduced motion', (tester) async {
      final mode = await pumpScene(tester, size: size, reduceMotion: true);
      mode.value = true;
      await tester.pump();
      final card = tester.getRect(
        find.byKey(const ValueKey('lyrics-control-card')),
      );
      expect(card.top, greaterThanOrEqualTo(0));
      expect(card.bottom, lessThanOrEqualTo(size.height));
      final footer = tester.getRect(find.byKey(const ValueKey('footer')));
      await tester.pump(const Duration(milliseconds: 3500));
      final folded = tester.getRect(
        find.byKey(const ValueKey('lyrics-control-card')),
      );
      expect(folded.top, footer.top);
      expect(folded.bottom, footer.bottom);
      expect(find.text('Footer').hitTestable(), findsOneWidget);
      expect(find.text('Play').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'landscape details artwork is not cropped by the adjacent footer',
    (tester) async {
      await pumpScene(tester, size: const Size(844, 390));
      expect(
        find
            .byKey(const ValueKey('cover'))
            .hitTestable(at: const Alignment(0, 0.95)),
        findsOneWidget,
      );
    },
  );
}
