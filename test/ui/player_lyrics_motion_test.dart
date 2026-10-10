import 'package:flutify_app/ui/screens/player/player_lyrics_motion.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'queue folds after entry and re-arms idle after a manual reveal',
    (tester) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      addTearDown(motion.dispose);
      motion.setView(lyrics: false, queue: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 499));
      expect(motion.controlsVisible, isTrue);
      expect(motion.chrome.value, 1);
      await tester.pump(const Duration(milliseconds: 2));
      expect(motion.queueTransition.value, 1);
      expect(motion.controlsVisible, isFalse);
      expect(
        motion.chrome.value,
        1,
        reason: 'folding starts from the visible card',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(motion.chrome.value, inExclusiveRange(0, 0.5));
      await tester.pump(
        PlayerLyricsMotion.foldDuration - const Duration(milliseconds: 75),
      );
      expect(motion.chrome.value, 0);

      motion.activity();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(motion.chrome.value, 1);
      await tester.pump(const Duration(milliseconds: 3199));
      expect(motion.controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(motion.controlsVisible, isFalse);
      await tester.pump(
        PlayerLyricsMotion.foldDuration + const Duration(milliseconds: 1),
      );
      expect(motion.chrome.value, 0);
    },
  );

  testWidgets('queue entry keeps folded lyrics closed after a footer touch', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    try {
      motion.setLyrics(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 641));
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump(PlayerLyricsMotion.foldDuration);
      expect(motion.chrome.value, 0);
      motion.pointerDown(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      var previous = motion.chrome.value;
      expect(previous, 0);
      motion.pointerUp(1);
      motion.setView(lyrics: false, queue: true);
      expect(motion.chrome.value, previous);
      await tester.pump();
      for (var frame = 0; frame < 33; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(motion.chrome.value, lessThanOrEqualTo(previous));
        previous = motion.chrome.value;
      }
      expect(motion.queueTransition.value, 1);
      expect(motion.chrome.value, 0);
      expect(motion.controlsVisible, isFalse);
    } finally {
      motion.dispose();
    }
  });

  testWidgets(
    'entering queue under accessibility never defers a one-shot fold',
    (tester) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      try {
        motion.configure(reduceMotion: true, accessibleNavigation: true);
        motion.setView(lyrics: false, queue: true);
        await tester.pump(const Duration(seconds: 5));
        expect(motion.controlsVisible, isTrue);
        motion.configure(reduceMotion: true, accessibleNavigation: false);
        expect(motion.controlsVisible, isTrue);
        await tester.pump(const Duration(milliseconds: 3499));
        expect(motion.controlsVisible, isTrue);
        await tester.pump(const Duration(milliseconds: 1));
        expect(motion.controlsVisible, isFalse);
      } finally {
        motion.dispose();
      }
    },
  );

  testWidgets('queue entry cannot fold while a second pointer is still held', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    try {
      motion.configure(reduceMotion: true, accessibleNavigation: false);
      motion.setLyrics(true);
      await tester.pump(const Duration(milliseconds: 3500));
      expect(motion.controlsVisible, isFalse);
      motion.pointerDown(1);
      motion.pointerDown(2);
      motion.pointerUp(1);
      motion.setView(lyrics: false, queue: true);
      await tester.pump(const Duration(seconds: 5));
      expect(motion.controlsVisible, isTrue);
      motion.pointerUp(2);
      await tester.pump(const Duration(milliseconds: 3499));
      expect(motion.controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(motion.controlsVisible, isFalse);
    } finally {
      motion.dispose();
    }
  });

  for (final modal in [true, false]) {
    testWidgets('queue entry folding waits for modal/background ($modal)', (
      tester,
    ) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      try {
        motion.setView(lyrics: false, queue: true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        if (modal) {
          motion.setInteractionSuspended(true);
        } else {
          motion.setActive(false);
        }
        await tester.pump(const Duration(seconds: 5));
        expect(motion.controlsVisible, isTrue);
        if (modal) {
          motion.setInteractionSuspended(false);
        } else {
          motion.setActive(true);
        }
        await tester.pump(const Duration(milliseconds: 3499));
        expect(motion.controlsVisible, isTrue);
        await tester.pump(const Duration(milliseconds: 1));
        expect(motion.controlsVisible, isFalse);
      } finally {
        motion.dispose();
      }
    });
  }

  testWidgets(
    'queue entry folding respects touch, accessibility and reversal',
    (tester) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      addTearDown(motion.dispose);
      motion.setView(lyrics: false, queue: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      motion.pointerDown(7);
      await tester.pump(const Duration(seconds: 5));
      expect(motion.controlsVisible, isTrue);
      motion.pointerUp(7);
      await tester.pump(const Duration(milliseconds: 3499));
      expect(motion.controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(motion.controlsVisible, isFalse);

      motion.configure(reduceMotion: true, accessibleNavigation: true);
      await tester.pump(const Duration(seconds: 5));
      expect(motion.chrome.value, 1);
      motion.setView(lyrics: false, queue: false);
      motion.configure(reduceMotion: false, accessibleNavigation: false);
      motion.setView(lyrics: false, queue: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      motion.setView(lyrics: false, queue: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(motion.transition.value, 0);
      expect(motion.chrome.value, 1);
      expect(motion.controlsVisible, isTrue);
    },
  );

  testWidgets(
    'three-way retargeting keeps pane weights bounded and continuous',
    (tester) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      addTearDown(motion.dispose);
      for (final (lyrics, queue) in [
        (false, true),
        (true, false),
        (false, false),
        (false, true),
        (false, false),
        (true, false),
      ]) {
        final before = (
          motion.transition.value,
          motion.queueTransition.value,
          motion.lyricsProgress,
        );
        motion.setView(lyrics: lyrics, queue: queue);
        expect((
          motion.transition.value,
          motion.queueTransition.value,
          motion.lyricsProgress,
        ), before);
        await tester.pump();
        for (var frame = 0; frame < 11; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            motion.queueTransition.value,
            lessThanOrEqualTo(motion.transition.value + 0.00001),
          );
          expect(
            motion.lyricsProgress + motion.queueTransition.value,
            closeTo(motion.transition.value, 0.00001),
          );
        }
      }
      motion.configure(reduceMotion: true, accessibleNavigation: false);
      expect(motion.transition.value, 1);
      expect(motion.lyricsProgress, 1);
      expect(motion.queueTransition.value, 0);
      motion.setView(lyrics: false, queue: true);
      expect(motion.transition.value, 1);
      expect(motion.queueTransition.value, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(motion.controlsVisible, isFalse);
      expect(motion.chrome.value, 0);
    },
  );

  testWidgets('unchanged dependency configuration cannot restart idle', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    motion.configure(reduceMotion: true, accessibleNavigation: false);
    motion.setLyrics(true);
    for (var cycle = 0; cycle < 3; cycle++) {
      motion.activity();
      for (var second = 0; second < 3; second++) {
        await tester.pump(const Duration(seconds: 1));
        motion.configure(reduceMotion: true, accessibleNavigation: false);
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(motion.controlsVisible, isFalse, reason: 'idle cycle $cycle');
      motion.configure(reduceMotion: true, accessibleNavigation: false);
      expect(motion.chrome.value, 0);
    }
    motion.dispose();
  });

  testWidgets('untracked pointer events do not reveal an idle card', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    motion.configure(reduceMotion: true, accessibleNavigation: false);
    motion.setLyrics(true);
    await tester.pump(const Duration(milliseconds: 3500));
    motion.pointerMove(99, const Offset(0, 60));
    motion.pointerUp(99);
    expect(motion.controlsVisible, isFalse);
    motion.dispose();
  });

  testWidgets('folded lyrics accumulate downward motion per pointer', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    addTearDown(motion.dispose);
    motion.configure(reduceMotion: true, accessibleNavigation: false);
    motion.setLyrics(true);
    await tester.pump(PlayerLyricsMotion.idleDelay);
    final movement = Offset(0, kTouchSlop / 2 + 1);
    motion.pointerDown(1);
    motion.pointerDown(2);
    motion.pointerMove(1, movement);
    motion.pointerMove(2, movement);
    expect(motion.controlsVisible, isFalse);
    motion.pointerUp(1);
    motion.pointerDown(1);
    motion.pointerMove(1, movement);
    expect(motion.controlsVisible, isFalse);
    motion.pointerMove(1, movement);
    expect(motion.controlsVisible, isTrue);
    motion.pointerUp(1);
    await tester.pump(const Duration(seconds: 5));
    expect(motion.controlsVisible, isTrue);
    motion.pointerUp(2);
    await tester.pump(PlayerLyricsMotion.idleDelay);
    expect(motion.controlsVisible, isFalse);
  });

  for (final reduced in [false, true]) {
    testWidgets('upward swipes fold lyrics and reverse in place ($reduced)', (
      tester,
    ) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      addTearDown(motion.dispose);
      motion.configure(reduceMotion: reduced, accessibleNavigation: false);
      motion.setLyrics(true);
      await tester.pump();
      await tester.pump(
        PlayerLyricsMotion.duration + const Duration(milliseconds: 1),
      );
      motion.pointerDown(1);
      motion.pointerMove(1, const Offset(0, -8));
      expect(motion.controlsVisible, isTrue);
      motion.pointerMove(1, const Offset(0, -32));
      expect(motion.controlsVisible, isFalse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final folding = motion.chrome.value;
      motion.pointerMove(1, const Offset(0, 32));
      expect(motion.controlsVisible, isTrue);
      expect(motion.chrome.value, reduced ? 1 : folding);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final revealing = motion.chrome.value;
      motion.pointerMove(1, const Offset(0, -32));
      expect(motion.controlsVisible, isFalse);
      expect(motion.chrome.value, reduced ? 0 : revealing);
      motion.pointerUp(1);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(motion.chrome.value, 0);
      expect(motion.controlsVisible, isFalse);
    });
  }

  testWidgets('fold animation keeps a soft tail past 300 milliseconds', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    addTearDown(motion.dispose);
    motion.setLyrics(true);
    await tester.pump();
    await tester.pump(
      PlayerLyricsMotion.duration + const Duration(milliseconds: 1),
    );
    await tester.pump(PlayerLyricsMotion.idleDelay);
    expect(motion.controlsVisible, isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    final early = motion.chrome.value;
    expect(early, inExclusiveRange(0, 0.5));
    await tester.pump(const Duration(milliseconds: 225));
    expect(motion.chrome.value, inExclusiveRange(0, early));
    await tester.pump(const Duration(milliseconds: 121));
    expect(motion.chrome.value, 0);
  });

  testWidgets('continuous swipes do not restart chrome animations', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    addTearDown(motion.dispose);
    motion.setLyrics(true);
    await tester.pump();
    await tester.pump(
      PlayerLyricsMotion.duration + const Duration(milliseconds: 1),
    );
    motion.pointerDown(1);
    motion.pointerMove(1, const Offset(0, -40));
    await tester.pump();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 70));
      motion.pointerMove(1, const Offset(0, -4));
    }
    expect(motion.controlsVisible, isFalse);
    expect(motion.chrome.value, 0);
    motion.pointerMove(1, const Offset(0, 40));
    await tester.pump();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      motion.pointerMove(1, const Offset(0, 4));
    }
    expect(motion.controlsVisible, isTrue);
    expect(motion.chrome.value, 1);
    motion.pointerUp(1);
    await tester.pump(
      PlayerLyricsMotion.idleDelay - const Duration(milliseconds: 1),
    );
    expect(motion.controlsVisible, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(motion.controlsVisible, isFalse);
    await tester.pump(
      PlayerLyricsMotion.foldDuration + const Duration(milliseconds: 1),
    );
    expect(motion.chrome.value, 0);
  });

  for (final guard in ['accessibility', 'inactive', 'modal', 'queue']) {
    testWidgets('upward swipe preserves visible controls for $guard', (
      tester,
    ) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      addTearDown(motion.dispose);
      motion.configure(
        reduceMotion: true,
        accessibleNavigation: guard == 'accessibility',
      );
      motion.setView(lyrics: guard != 'queue', queue: guard == 'queue');
      await tester.pump();
      motion.activity();
      motion.setActive(guard != 'inactive');
      motion.setInteractionSuspended(guard == 'modal');
      expect(motion.controlsVisible, isTrue);
      motion.pointerDown(1);
      motion.pointerMove(1, const Offset(0, -40));
      motion.pointerUp(1);
      expect(motion.controlsVisible, isTrue);
      expect(motion.chrome.value, 1);
      motion.setActive(false);
    });
  }

  testWidgets('all scene motion eases nonlinearly and reverses in place', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    motion.setLyrics(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(motion.transition.value, greaterThan(0.5));
    final before = motion.transition.value;
    motion.setLyrics(false);
    expect(motion.transition.value, before);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 641));
    expect(motion.transition.value, 0);
    expect(motion.controlsVisible, isTrue);
    motion.dispose();
  });

  testWidgets('idle begins after entry finishes and hides after 3.5 seconds', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    motion.setLyrics(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 641));
    await tester.pump(const Duration(milliseconds: 3499));
    expect(motion.controlsVisible, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(motion.controlsVisible, isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(motion.chrome.value, lessThan(0.5));
    await tester.pump(PlayerLyricsMotion.foldDuration);
    expect(motion.chrome.value, 0);
    motion.dispose();
  });

  testWidgets('held gestures keep controls awake until release', (
    tester,
  ) async {
    final motion = PlayerLyricsController(vsync: const TestVSync());
    motion.setLyrics(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 641));
    motion.pointerDown(1);
    motion.pointerDown(2);
    await tester.pump(const Duration(seconds: 5));
    expect(motion.controlsVisible, isTrue);
    motion.pointerUp(1);
    await tester.pump(const Duration(seconds: 5));
    expect(motion.controlsVisible, isTrue);
    motion.pointerUp(2);
    await tester.pump(const Duration(milliseconds: 3500));
    expect(motion.controlsVisible, isFalse);
    motion.activity();
    expect(motion.controlsVisible, isTrue);
    await tester.pump(const Duration(milliseconds: 3400));
    motion.activity();
    await tester.pump(const Duration(milliseconds: 3400));
    expect(motion.controlsVisible, isTrue);
    motion.dispose();
  });

  testWidgets(
    'reduced motion, accessibility, lifecycle and disposal are safe',
    (tester) async {
      final motion = PlayerLyricsController(vsync: const TestVSync());
      motion.configure(reduceMotion: true, accessibleNavigation: false);
      motion.setLyrics(true);
      expect(motion.transition.value, 1);
      motion.setActive(false);
      await tester.pump(const Duration(seconds: 8));
      expect(motion.controlsVisible, isTrue);
      motion.setActive(true);
      await tester.pump(const Duration(milliseconds: 3500));
      expect(motion.chrome.value, 0);
      motion.configure(reduceMotion: true, accessibleNavigation: true);
      await tester.pump(const Duration(seconds: 8));
      expect(motion.controlsVisible, isTrue);
      motion.setLyrics(false);
      expect(motion.transition.value, 0);
      motion.dispose();
      await tester.pump(const Duration(seconds: 8));
      expect(tester.takeException(), isNull);
    },
  );
}
