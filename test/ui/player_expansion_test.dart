import 'package:flutify_app/ui/screens/player/player_expansion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = Rect.fromLTWH(10, 654, 370, 64);
  const screen = Size(390, 844);

  Future<AnimationController> pumpTransition(
    WidgetTester tester, {
    PlayerExpansionOrigin origin = const PlayerExpansionOrigin(
      bounds: source,
      color: Colors.black,
      borderRadius: BorderRadius.all(Radius.circular(32)),
      compactChild: SizedBox.shrink(),
    ),
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AnimationController(vsync: tester);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerExpansionTransition(
          animation: controller,
          origin: origin,
          child: const ColoredBox(color: Colors.blue),
        ),
      ),
    );
    return controller;
  }

  Path surfacePath(WidgetTester tester) => tester
      .widget<ClipPath>(find.byKey(const ValueKey('player-expansion-surface')))
      .clipper!
      .getClip(screen);
  Rect surface(WidgetTester tester) => surfacePath(tester).getBounds();

  final compact = find.byKey(const ValueKey('player-expansion-compact'));
  double compactOpacity(WidgetTester tester) =>
      compact.evaluate().isEmpty ? 0 : tester.widget<Opacity>(compact).opacity;

  for (final frameRate in [60, 120]) {
    testWidgets(
      'player surface has continuous $frameRate Hz expansion and collapse',
      (tester) async {
        final controller = await pumpTransition(tester);
        expect(surface(tester), source);
        expect(compactOpacity(tester), 1);

        controller.animateWith(
          PlayerExpansionMotion.simulation(from: 0, to: 1),
        );
        await tester.pump();
        final tick = Duration(microseconds: (1000000 / frameRate).round());
        var previous = source;
        var previousOpacity = 1.0;
        while (controller.isAnimating) {
          await tester.pump(tick);
          final bounds = surface(tester);
          expect(bounds.top, lessThanOrEqualTo(previous.top));
          expect(bounds.bottom, greaterThanOrEqualTo(previous.bottom));
          expect(bounds.left, lessThanOrEqualTo(previous.left));
          expect(bounds.right, greaterThanOrEqualTo(previous.right));
          expect(previous.top - bounds.top, lessThan(source.top * 0.15));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(844));
          // The pill's row leaves on the same progress as the shell.
          final opacity = compactOpacity(tester);
          expect(opacity, lessThanOrEqualTo(previousOpacity));
          expect(
            opacity,
            closeTo(
              PlayerExpansionMotion.compactOpacity(controller.value),
              1e-9,
            ),
          );
          previous = bounds;
          previousOpacity = opacity;
        }
        // The spring lands exactly on the full screen, not at 0.9996.
        expect(controller.value, 1);
        expect(surface(tester), const Rect.fromLTWH(0, 0, 390, 844));
        expect(surfacePath(tester).contains(const Offset(0.1, 0.1)), isTrue);
        expect(compact, findsNothing);

        controller.animateBackWith(
          PlayerExpansionMotion.simulation(from: 1, to: 0),
        );
        await tester.pump();
        expect(surface(tester), previous);
        var sawCompact = false;
        while (controller.isAnimating) {
          await tester.pump(tick);
          final bounds = surface(tester);
          expect(bounds.top, greaterThanOrEqualTo(previous.top));
          expect(bounds.bottom, lessThanOrEqualTo(previous.bottom));
          expect(bounds.left, greaterThanOrEqualTo(previous.left));
          expect(bounds.right, lessThanOrEqualTo(previous.right));
          final opacity = compactOpacity(tester);
          expect(opacity, greaterThanOrEqualTo(previousOpacity));
          if (compact.evaluate().isNotEmpty) {
            sawCompact = true;
            // The row rides on the shell's top edge, already lined up with the
            // pill horizontally, so it lands right on the pill.
            expect(tester.getTopLeft(compact).dx, closeTo(source.left, 1e-3));
            expect(
              tester.getTopLeft(compact).dy,
              closeTo(bounds.top - 12 * (1 - opacity), 1e-3),
            );
          }
          previous = bounds;
          previousOpacity = opacity;
        }
        expect(sawCompact, isTrue);
        expect(controller.value, 0);
        expect(surface(tester), source);
        expect(surfacePath(tester).contains(source.topLeft), isFalse);
        expect(compactOpacity(tester), 1);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'the pill grows into a floating card before it fills the screen',
    (tester) async {
      final controller = await pumpTransition(tester);
      final shadow = find.byKey(const ValueKey('player-expansion-shadow'));
      expect(shadow, findsNothing);
      // Half-way through the morph band every edge is already moving outwards.
      controller.value = PlayerExpansionMotion.morphEnd / 2;
      await tester.pump();
      final morphing = surface(tester);
      expect(
        morphing.left,
        inExclusiveRange(PlayerExpansionMotion.cardInset, source.left),
      );
      expect(morphing.bottom, inExclusiveRange(source.bottom, 836));
      expect(shadow, findsOneWidget);
      // Past it the shell is a card: inset from the screen on three sides and
      // rounded on all four corners, with only its top still travelling.
      controller.value = PlayerExpansionMotion.settleStart;
      await tester.pump();
      final card = surface(tester);
      expect(card.left, closeTo(8, 1e-6));
      expect(card.right, closeTo(382, 1e-6));
      expect(card.bottom, closeTo(836, 1e-6));
      expect(card.top, closeTo(source.top * 0.4, 1e-3));
      expect(
        surfacePath(tester).contains(card.bottomLeft + const Offset(1, -1)),
        isFalse,
      );
      expect(
        surfacePath(tester).contains(card.topRight + const Offset(-1, 1)),
        isFalse,
      );
      // The card closes its margins on the way to the full screen.
      controller.value = 0.9;
      await tester.pump();
      final settling = surface(tester);
      expect(settling.left, inExclusiveRange(0, 8));
      expect(settling.bottom, inExclusiveRange(836, 844));
      controller.value = 1;
      await tester.pump();
      expect(shadow, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the player is pinned to the card and scales with its width', (
    tester,
  ) async {
    final controller = await pumpTransition(tester);
    final content = find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color == Colors.blue,
    );
    for (final value in [0.0, 0.3, 0.6, 0.85, 1.0]) {
      controller.value = value;
      await tester.pump();
      final card = surface(tester);
      final rect = tester.getRect(content);
      expect(rect.topLeft.dx, closeTo(card.left, 1e-3));
      expect(rect.topLeft.dy, closeTo(card.top, 1e-3));
      expect(rect.width, closeTo(card.width, 1e-3));
      // Laid out for the full screen: the card's bottom edge cuts it off.
      expect(rect.height, closeTo(844 * card.width / 390, 1e-3));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a glass pill is the shell itself and dissolves into the colour',
    (tester) async {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = AnimationController(vsync: tester);
      addTearDown(controller.dispose);
      final radii = <BorderRadius>[];
      final origin = ValueNotifier<PlayerExpansionOrigin?>(null);
      addTearDown(origin.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              Positioned.fromRect(
                rect: source,
                child: PlayerExpansionSource(
                  color: Colors.red,
                  translucent: true,
                  borderRadius: const BorderRadius.all(Radius.circular(24)),
                  compactChild: const Text('tinted'),
                  material: (
                    surface: (context, radius) {
                      radii.add(radius);
                      return const SizedBox.expand(key: ValueKey('glass'));
                    },
                    row: const Text('resting'),
                  ),
                  child: const SizedBox.expand(key: ValueKey('pill')),
                ),
              ),
              Positioned.fill(
                child: ValueListenableBuilder(
                  valueListenable: origin,
                  builder: (context, origin, _) => origin == null
                      ? const SizedBox.shrink()
                      : PlayerExpansionTransition(
                          animation: controller,
                          origin: origin,
                          child: const SizedBox.expand(),
                        ),
                ),
              ),
            ],
          ),
        ),
      );
      double opacityOf(String key) {
        final finder = find.byKey(ValueKey(key));
        return finder.evaluate().isEmpty
            ? 0
            : tester.widget<Opacity>(finder).opacity;
      }

      double pillOpacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('pill')),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;

      // The route takes the pill over: the real one is hidden, the shell draws
      // the same glass in the same place with the same row on it.
      final captured = PlayerExpansionSource.capture(
        tester.element(find.byKey(const ValueKey('pill'))),
      )!;
      expect(captured.bounds, source);
      expect(pillOpacity(), 1);
      captured.setArtworkHidden!(true);
      origin.value = captured;
      await tester.pump();
      expect(pillOpacity(), 0);
      final glass = find.byKey(const ValueKey('glass'));
      expect(tester.getRect(glass), source);
      expect(radii.last, BorderRadius.circular(24));
      expect(opacityOf('player-expansion-dissolve'), 0);
      expect(opacityOf('player-expansion-compact'), 1);
      expect(opacityOf('player-expansion-resting-row'), 1);
      expect(opacityOf('player-expansion-tinted-row'), 0);

      // Part-way through the dissolve the glass grows with the shell while the
      // colour and the white row fade in over it.
      controller.value = PlayerExpansionMotion.dissolveEnd / 2;
      await tester.pump();
      expect(
        tester.getRect(glass),
        rectMoreOrLessEquals(surface(tester), epsilon: 1e-3),
      );
      expect(opacityOf('player-expansion-dissolve'), closeTo(0.5, 0.01));
      expect(opacityOf('player-expansion-resting-row'), closeTo(0.5, 0.01));
      expect(opacityOf('player-expansion-tinted-row'), closeTo(0.5, 0.01));
      expect(
        opacityOf('player-expansion-compact'),
        PlayerExpansionMotion.compactOpacity(controller.value),
      );

      // Once the colour covers it the glass is no longer drawn at all.
      controller.value = PlayerExpansionMotion.dissolveEnd;
      await tester.pump();
      expect(glass, findsNothing);
      expect(find.text('resting'), findsNothing);
      expect(opacityOf('player-expansion-dissolve'), 1);
      expect(opacityOf('player-expansion-tinted-row'), 1);

      captured.setArtworkHidden!(false);
      await tester.pump();
      expect(pillOpacity(), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a reversed spring continues from where it was, without a jump', (
    tester,
  ) async {
    final controller = await pumpTransition(tester);
    controller.animateWith(PlayerExpansionMotion.simulation(from: 0, to: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final before = surface(tester);
    final value = controller.value;
    expect(value, inExclusiveRange(0, 1));
    controller.animateBackWith(
      PlayerExpansionMotion.simulation(from: value, to: 0, velocity: 3),
    );
    await tester.pump();
    expect(surface(tester), before);
    await tester.pump(const Duration(milliseconds: 16));
    // The opening velocity is inherited: the shell keeps rising for a moment.
    expect(surface(tester).top, lessThanOrEqualTo(before.top));
    await tester.pumpAndSettle();
    expect(controller.value, 0);
    expect(surface(tester), source);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('release rule follows position and flick direction', () {
    // Opening from the pill: a quarter of the way, or any upward flick.
    expect(PlayerExpansionMotion.shouldExpand(0.3, 0, opening: true), isTrue);
    expect(PlayerExpansionMotion.shouldExpand(0.1, 0, opening: true), isFalse);
    expect(PlayerExpansionMotion.shouldExpand(0.05, 2, opening: true), isTrue);
    // Dismissing from the player: a quarter of the way down, or a downward flick.
    expect(PlayerExpansionMotion.shouldExpand(0.9, 0), isTrue);
    expect(PlayerExpansionMotion.shouldExpand(0.7, 0), isFalse);
    expect(PlayerExpansionMotion.shouldExpand(0.95, -2), isFalse);
    expect(PlayerExpansionMotion.shouldExpand(0.6, 2), isTrue);
  });

  testWidgets('collapse follows the pill as it is now, not as it was opened', (
    tester,
  ) async {
    PlayerExpansionLook look = (
      color: Colors.red,
      compactChild: const Text('opened with', textDirection: TextDirection.ltr),
    );
    final controller = await pumpTransition(
      tester,
      origin: PlayerExpansionOrigin(
        bounds: source,
        color: look.color,
        borderRadius: const BorderRadius.all(Radius.circular(32)),
        compactChild: look.compactChild,
        currentLook: () => look,
      ),
    );
    controller.animateWith(PlayerExpansionMotion.simulation(from: 0, to: 1));
    await tester.pumpAndSettle();
    expect(controller.isCompleted, isTrue);

    // The track changes while the player covers the pill.
    look = (
      color: Colors.green,
      compactChild: const Text('playing now', textDirection: TextDirection.ltr),
    );
    controller.animateBackWith(
      PlayerExpansionMotion.simulation(from: 1, to: 0),
    );
    await tester.pump();
    final shell = find.byKey(const ValueKey('player-expansion-surface'));
    Color pillColor() => tester
        .widget<ColoredBox>(
          find.descendant(of: shell, matching: find.byType(ColoredBox)).first,
        )
        .color;
    var sawCompact = false;
    while (controller.isAnimating) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(pillColor(), Colors.green);
      if (compact.evaluate().isEmpty) continue;
      sawCompact = true;
      expect(find.text('opened with'), findsNothing);
      expect(
        find.descendant(of: compact, matching: find.text('playing now')),
        findsOneWidget,
      );
    }
    expect(sawCompact, isTrue);

    // Without a live source the opening snapshot is all there is.
    const snapshot = PlayerExpansionOrigin(
      bounds: source,
      color: Colors.red,
      borderRadius: BorderRadius.all(Radius.circular(32)),
      compactChild: Text('opened with', textDirection: TextDirection.ltr),
    );
    expect(snapshot.look.color, Colors.red);
    expect(snapshot.look.compactChild, same(snapshot.compactChild));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final frameRate in [60, 120]) {
    testWidgets(
      'collapse settles within sub-pixel tolerance without a final-frame snap ($frameRate Hz)',
      (tester) async {
        final controller = await pumpTransition(tester);
        controller.value = 1;
        await tester.pump();

        // When fully expanded, path clipping and content RepaintBoundary are bypassed
        // so fullscreen BackdropGroup scenes are not rasterized into an offscreen subpass.
        final expandedClip = tester.widget<ClipPath>(
          find.byKey(const ValueKey('player-expansion-surface')),
        );
        expect(expandedClip.clipBehavior, Clip.none);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('player-expansion-surface')),
            matching: find.byType(RepaintBoundary),
          ),
          findsNothing,
        );

        controller.animateBackWith(
          PlayerExpansionMotion.simulation(from: 1, to: 0),
        );
        await tester.pump();
        final tick = Duration(microseconds: (1000000 / frameRate).round());
        var previous = surface(tester);
        var preSnapDeltaHeight = double.infinity;
        while (controller.isAnimating) {
          previous = surface(tester);
          await tester.pump(tick);
          if (!controller.isAnimating) {
            preSnapDeltaHeight = (previous.height - source.height).abs();
          }
        }
        expect(controller.value, 0);
        expect(surface(tester), source);
        // Previously p snapped from ~0.00216 to 0 (~2.6dp height jump in 1 frame).
        expect(preSnapDeltaHeight, lessThan(0.5));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'live source bounds and Frame-0 artwork flight track without a 1-frame lag',
    (tester) async {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = AnimationController(vsync: tester, value: 0.25);
      addTearDown(controller.dispose);
      final pillRect = ValueNotifier<Rect>(source);
      addTearDown(pillRect.dispose);
      final origin = ValueNotifier<PlayerExpansionOrigin?>(null);
      addTearDown(origin.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              ValueListenableBuilder<Rect>(
                valueListenable: pillRect,
                builder: (context, rect, _) => Positioned.fromRect(
                  rect: rect,
                  child: PlayerExpansionSource(
                    color: Colors.black,
                    borderRadius: const BorderRadius.all(Radius.circular(24)),
                    compactChild: const SizedBox.shrink(),
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: PlayerArtworkHero(
                        imageUrl: 'https://example.com/cover.jpg',
                        child: SizedBox(
                          key: ValueKey('mini-art'),
                          width: 36,
                          height: 36,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: ValueListenableBuilder<PlayerExpansionOrigin?>(
                  valueListenable: origin,
                  builder: (context, captured, _) => captured == null
                      ? const SizedBox.shrink()
                      : PlayerExpansionTransition(
                          animation: controller,
                          origin: captured,
                          child: LayoutBuilder(
                            builder: (context, _) => const Align(
                              alignment: Alignment.topCenter,
                              child: Padding(
                                padding: EdgeInsets.only(top: 80),
                                child: PlayerArtworkHero(
                                  imageUrl: 'https://example.com/cover.jpg',
                                  child: SizedBox(width: 320, height: 320),
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      );

      final captured = PlayerExpansionSource.capture(
        tester.element(find.byKey(const ValueKey('mini-art'))),
      )!;
      origin.value = captured;
      // Single pump (Frame 0 of interactive drag-open at p = 0.25):
      await tester.pump();
      final flight = find.byKey(const ValueKey('player-artwork-flight'));
      expect(flight, findsOneWidget);
      // Must already interpolate towards the 320dp target on Frame 0 instead of
      // staying stuck at 36dp for 1 frame.
      expect(tester.getRect(flight).width, greaterThan(60));

      // Move the underlying pill while covered, then land on the new position.
      const shifted = Rect.fromLTWH(24, 712, 342, 56);
      pillRect.value = shifted;
      controller.value = 0;
      await tester.pump();
      expect(surface(tester), shifted);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
