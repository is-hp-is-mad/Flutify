import 'package:flutify_app/ui/screens/player/android_player_scene.dart';
import 'package:flutify_app/ui/screens/player/player_lyrics_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

enum _View { details, lyrics, queue }

void main() {
  Future<ValueNotifier<_View>> scene(
    WidgetTester tester, {
    bool reduced = false,
    Size size = const Size(390, 800),
    ScrollController? scroll,
    VoidCallback? onQueueTap,
    VoidCallback? onLyricsTap,
    FocusNode? queueFocus,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mode = ValueNotifier(_View.details);
    addTearDown(mode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: reduced),
          child: Material(
            child: ValueListenableBuilder<_View>(
              valueListenable: mode,
              builder: (context, value, _) => AndroidPlayerScene(
                lyricsMode: value == _View.lyrics,
                queueMode: value == _View.queue,
                background: const ColoredBox(color: Colors.black),
                lyricsBackground: const ColoredBox(color: Colors.teal),
                topBar: const SizedBox(height: 56),
                title: const SizedBox(key: ValueKey('title'), height: 56),
                controls: const SizedBox(
                  key: ValueKey('controls'),
                  height: 100,
                ),
                footer: const SizedBox(key: ValueKey('footer'), height: 48),
                artworkBuilder: (context, size, progress) => const ColoredBox(
                  key: ValueKey('cover'),
                  color: Colors.blue,
                ),
                onArtworkTap: () => mode.value = _View.details,
                lyrics: GestureDetector(
                  onTap: onLyricsTap,
                  child: const ColoredBox(
                    key: ValueKey('lyrics'),
                    color: Colors.purple,
                  ),
                ),
                translation: Semantics(
                  label: 'Translation tools',
                  child: const SizedBox(width: 48, height: 48),
                ),
                queue: ListView.builder(
                  key: const ValueKey('queue'),
                  controller: scroll,
                  itemCount: 40,
                  itemExtent: 64,
                  itemBuilder: (context, index) => TextButton(
                    onPressed: onQueueTap,
                    focusNode: index == 0 ? queueFocus : null,
                    child: Text('Queue $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return mode;
  }

  testWidgets('queue automatically folds and gives its space to the list', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var taps = 0;
    final mode = await scene(tester, scroll: scroll, onQueueTap: () => taps++);
    final card = find.byKey(const ValueKey('lyrics-control-card'));
    final footer = find.byKey(const ValueKey('footer'));
    final queue = find.byKey(const ValueKey('queue'));
    mode.value = _View.queue;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump();
    final expanded = tester.getRect(card);
    final listBefore = tester.getRect(queue);
    final listElement = tester.element(queue);
    final footerBefore = tester.getRect(footer);
    scroll.jumpTo(400);
    await tester.pump();
    final rowBefore = tester.getRect(find.text('Queue 7'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getRect(card).top, greaterThan(expanded.top));
    expect(tester.getRect(queue).height, greaterThan(listBefore.height));
    await tester.pump(
      PlayerLyricsMotion.foldDuration - const Duration(milliseconds: 150),
    );
    expect(tester.getRect(card).top, footerBefore.top);
    expect(tester.getRect(footer), footerBefore);
    expect(tester.getRect(queue).bottom, footerBefore.top - 8);
    expect(scroll.offset, 400);
    expect(tester.getRect(find.text('Queue 7')), rowBefore);
    expect(tester.element(queue), same(listElement));

    await tester.tapAt(tester.getCenter(footer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(card), expanded);
    expect(scroll.offset, 400);
    expect(taps, 0, reason: 'waking from the footer cannot play a queue item');
    final hold = await tester.startGesture(tester.getCenter(footer));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.getRect(card), expanded);
    await hold.cancel();
    await tester.pump(const Duration(milliseconds: 3500));
    await tester.pump(PlayerLyricsMotion.foldDuration);
    expect(tester.getRect(card).top, footerBefore.top);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'queue entry and exit keep shared elements and the outgoing list alive',
    (tester) async {
      final mode = await scene(tester);
      final cover = find.byKey(const ValueKey('cover'));
      final start = tester.getRect(cover);
      final element = tester.element(cover);
      mode.value = _View.queue;
      await tester.pump();
      expect(
        cover,
        findsOneWidget,
        reason: 'do not remove artwork on the click frame',
      );
      expect(tester.element(cover), same(element));
      expect(tester.getRect(cover), start);
      await tester.pump(const Duration(milliseconds: 125));
      final middle = tester.getRect(cover);
      expect(middle.width, inExclusiveRange(64, start.width));
      await tester.pump(const Duration(milliseconds: 500));
      final small = tester.getRect(cover);
      expect(small.width, 64);
      expect(
        (start.width - middle.width) / (start.width - small.width),
        isNot(closeTo(0.25, 0.02)),
      );
      final queue = find.byKey(const ValueKey('queue'));
      final queueElement = tester.element(queue);
      final card = tester.getRect(
        find.byKey(const ValueKey('lyrics-control-card')),
      );
      expect(tester.getRect(queue).bottom, lessThanOrEqualTo(card.top));
      mode.value = _View.details;
      await tester.pump();
      expect(
        tester.element(queue),
        same(queueElement),
        reason: 'outgoing queue must paint until its exit finishes',
      );
      expect(tester.getRect(cover), small);
      await tester.pump(const Duration(milliseconds: 125));
      expect(
        tester.getRect(cover).width,
        inExclusiveRange(small.width, start.width),
      );
      expect(queue, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(queue, findsNothing);
      expect(tester.getRect(cover), start);
      expect(tester.element(cover), same(element));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('crossfading panes cannot accidentally play or seek', (
    tester,
  ) async {
    var queueTaps = 0;
    var lyricTaps = 0;
    final mode = await scene(
      tester,
      onQueueTap: () => queueTaps++,
      onLyricsTap: () => lyricTaps++,
    );
    mode.value = _View.lyrics;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    mode.value = _View.queue;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(150, 200));
    expect(queueTaps, 0, reason: 'incoming queue is not yet readable');
    expect(lyricTaps, 0, reason: 'outgoing lyrics cannot seek');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Queue 0'));
    expect(queueTaps, 1);
    mode.value = _View.lyrics;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final lyricsTop = tester.getTopLeft(find.byKey(const ValueKey('lyrics')));
    await tester.tapAt(lyricsTop + const Offset(150, 24));
    expect(
      lyricTaps,
      0,
      reason: 'incoming lyrics cannot seek during the handoff',
    );
    expect(queueTaps, 1);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tapAt(const Offset(150, 200));
    expect(lyricTaps, 1, reason: 'settled lyrics are interactive');
    expect(tester.takeException(), isNull);
  });

  testWidgets('only settled content is exposed to accessibility', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final mode = await scene(tester, onQueueTap: () {});
      mode.value = _View.queue;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.semantics.byLabel('Queue 0'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.semantics.byLabel('Queue 0'), findsOneWidget);
      mode.value = _View.lyrics;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.semantics.byLabel('Queue 0'), findsNothing);
      expect(find.semantics.byLabel('Translation tools'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.semantics.byLabel('Translation tools'), findsOneWidget);
      mode.value = _View.queue;
      await tester.pump();
      expect(find.semantics.byLabel('Translation tools'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'folded lyrics stay folded in queue and reveal continuously on return',
    (tester) async {
      final mode = await scene(tester);
      final card = find.byKey(const ValueKey('lyrics-control-card'));
      final cover = find.byKey(const ValueKey('cover'));
      mode.value = _View.lyrics;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      final expanded = tester.getRect(card);
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(PlayerLyricsMotion.foldDuration);
      final folded = tester.getRect(card);
      final foldedCover = tester.getRect(cover);
      expect(folded.top, greaterThan(expanded.top));
      mode.value = _View.queue;
      await tester.pump();
      expect(tester.getRect(card), folded);
      for (var frame = 0; frame < 32; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(card), folded);
        expect(tester.getRect(cover), foldedCover);
      }
      final queue = tester.getRect(find.byKey(const ValueKey('queue')));
      expect(queue.bottom, folded.top - 8);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.getRect(card), folded);
      expect(tester.getRect(find.byKey(const ValueKey('queue'))), queue);
      mode.value = _View.lyrics;
      await tester.pump();
      expect(tester.getRect(card), folded);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.getRect(card).top,
        inExclusiveRange(expanded.top, folded.top),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(card), expanded);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('outgoing queue loses focus and actions while still painting', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    try {
      var taps = 0;
      final mode = await scene(
        tester,
        queueFocus: focus,
        onQueueTap: () => taps++,
      );
      mode.value = _View.queue;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.tap(find.text('Queue 0'));
      expect(taps, 1);
      mode.value = _View.details;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      expect(find.text('Queue 0'), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(find.byKey(const ValueKey('player-queue-opacity')))
            .opacity,
        inExclusiveRange(0, 1),
      );
      expect(focus.hasFocus, isFalse);
      expect(find.semantics.byLabel('Queue 0'), findsNothing);
      await tester.tapAt(tester.getCenter(find.text('Queue 0')));
      expect(taps, 1, reason: 'fading content must not play a queued song');
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'lyrics and queue exchange content without expanding the shared card',
    (tester) async {
      final mode = await scene(tester);
      final cover = find.byKey(const ValueKey('cover'));
      mode.value = _View.lyrics;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      final small = tester.getRect(cover);
      final title = tester.getRect(find.byKey(const ValueKey('title')));
      mode.value = _View.queue;
      await tester.pump();
      for (var frame = 0; frame < 32; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(cover), small);
        expect(tester.getRect(find.byKey(const ValueKey('title'))), title);
      }
      expect(find.byKey(const ValueKey('lyrics')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(
        tester.getRect(cover).top,
        greaterThan(small.top),
        reason: 'queue automatically folds after the content handoff',
      );
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('footer'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(cover), small);
      mode.value = _View.lyrics;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getRect(cover), small);
      expect(find.byKey(const ValueKey('queue')), findsOneWidget);
      expect(find.byKey(const ValueKey('lyrics')), findsOneWidget);
      final before = tester.getRect(find.byKey(const ValueKey('queue')));
      mode.value = _View.queue;
      await tester.pump();
      expect(tester.getRect(find.byKey(const ValueKey('queue'))), before);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.getRect(cover), small);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'queue scroll survives exits and hidden content cannot act or announce',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        var taps = 0;
        final mode = await scene(
          tester,
          reduced: true,
          scroll: scroll,
          onQueueTap: () => taps++,
        );
        mode.value = _View.queue;
        await tester.pump();
        scroll.jumpTo(400);
        await tester.pump();
        final queueElement = tester.element(
          find.byKey(const ValueKey('queue')),
        );
        final item = find.text('Queue 7');
        await tester.tap(item);
        expect(taps, 1);
        mode.value = _View.details;
        await tester.pump();
        expect(find.byKey(const ValueKey('queue')), findsNothing);
        expect(find.semantics.byLabel('Queue 7'), findsNothing);
        mode.value = _View.queue;
        await tester.pump();
        await tester.pump();
        expect(scroll.offset, 400);
        expect(
          tester.element(find.byKey(const ValueKey('queue'))),
          same(queueElement),
        );
        expect(taps, 1);
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('footer'))),
        );
        await tester.pump();
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('cover'))),
        );
        await tester.pump();
        expect(mode.value, _View.details);
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );
}
