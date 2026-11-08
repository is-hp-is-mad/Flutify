import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Shared Apple-style timing for the Android player's coordinated transitions.
abstract final class PlayerLyricsMotion {
  // Responsive takeoff with a long, gentle landing; no bounce.
  // The scene's geometry receives this already-eased value.
  static const curve = Cubic(0.22, 0.8, 0.22, 1);

  /// Glass frame and translation chip. UIKit ease-in-out, so the material
  /// forms and dissolves across the whole flight. The geometry curve above
  /// is front-loaded; using it for opacity makes the frame pop in and vanish
  /// while the metadata is still moving.
  static const frameCurve = Cubic(0.42, 0.0, 0.58, 1);
  static const duration = Duration(milliseconds: 640);
  static const chromeDuration = Duration(milliseconds: 300);
  static const foldCurve = Cubic(0.32, 0.72, 0, 1);
  static const foldDuration = Duration(milliseconds: 420);

  /// Translation chip while the card folds. [chrome] is already on [foldCurve],
  /// which drops most of the way in the first 100ms. This ease-out keeps the
  /// chip readable as it rides the card, then settles it away.
  static const chipFoldCurve = Cubic(0.0, 0.6, 0.2, 1.0);

  static double chipFold(double chrome) =>
      chipFoldCurve.transform(chrome.clamp(0.0, 1.0));
  static const idleDelay = Duration(milliseconds: 3500);
}

/// Apple Music 6.5.3's content transition timing, adapted to one shared flight.
abstract final class PlayerQueueMotion {
  static const curve = Cubic(0.25, 0.1, 0.25, 1);
  static const duration = Duration(milliseconds: 500);
  static const rise = 24.0;
}

/// UI-only motion and inactivity state; playback ticks must not call [activity].
class PlayerLyricsController extends ChangeNotifier {
  PlayerLyricsController({required TickerProvider vsync})
    : transition = AnimationController(vsync: vsync),
      queueTransition = AnimationController(vsync: vsync),
      frame = AnimationController(vsync: vsync),
      translationReveal = AnimationController(vsync: vsync),
      chrome = AnimationController(vsync: vsync, value: 1) {
    transition.addListener(notifyListeners);
    queueTransition.addListener(notifyListeners);
    frame.addListener(notifyListeners);
    translationReveal.addListener(notifyListeners);
    chrome.addListener(notifyListeners);
  }

  final AnimationController transition;
  final AnimationController queueTransition;

  /// 0–1 presence of the glass frame. Same flight length as [transition],
  /// eased with [PlayerLyricsMotion.frameCurve].
  final AnimationController frame;

  /// 0–1 presence of the lyrics translation chip. Tracks lyrics only, so it
  /// pops back when leaving lyrics for the queue while the frame stays.
  final AnimationController translationReveal;
  final AnimationController chrome;
  final Map<int, Offset> _pointers = {};
  Timer? _timer;
  bool _lyrics = false;
  bool _queue = false;
  bool _foldQueueAfterEntry = false;
  bool _gestureStartedFolded = false;
  bool _idle = false;
  bool _active = true;
  bool _reduceMotion = false;
  bool _accessibleNavigation = false;
  bool _interactionSuspended = false;
  bool _pinned = false;
  bool _disposed = false;

  bool get controlsVisible => !_idle;
  double get lyricsProgress =>
      (transition.value - queueTransition.value).clamp(0.0, 1.0);

  void configure({
    required bool reduceMotion,
    required bool accessibleNavigation,
  }) {
    if (_reduceMotion == reduceMotion &&
        _accessibleNavigation == accessibleNavigation) {
      return;
    }
    _reduceMotion = reduceMotion;
    _accessibleNavigation = accessibleNavigation;
    _gestureStartedFolded = false;
    if (reduceMotion) {
      transition.value = _lyrics || _queue ? 1 : 0;
      queueTransition.value = _queue ? 1 : 0;
      frame.value = _lyrics || _queue ? 1 : 0;
      translationReveal.value = _lyrics ? 1 : 0;
      chrome.value = _idle ? 0 : 1;
    }
    if (accessibleNavigation) {
      activity();
    } else {
      _scheduleIdle();
    }
  }

  void setLyrics(bool value) => setView(lyrics: value, queue: false);

  void setView({required bool lyrics, required bool queue}) {
    assert(!lyrics || !queue);
    if (_lyrics == lyrics && _queue == queue) return;
    final queueFlight = queue || _queue;
    // A footer onTap changes views after pointer-down. Retain
    // that gesture's origin even with reduced motion, where chrome snaps to 1.
    // Another held finger cannot reopen the queue card either.
    final keepFolded =
        queue &&
        !_accessibleNavigation &&
        !_interactionSuspended &&
        (_idle || _gestureStartedFolded);
    _gestureStartedFolded = false;
    _lyrics = lyrics;
    _queue = queue;
    // An already-folded lyrics card stays folded when entering the queue.
    // Otherwise finish the shared-element flight before retracting the card.
    _foldQueueAfterEntry =
        queue &&
        !keepFolded &&
        _active &&
        !_accessibleNavigation &&
        !_interactionSuspended;
    _timer?.cancel();
    if (keepFolded) {
      _fold();
    } else {
      _reveal();
    }
    final duration = _reduceMotion
        ? Duration.zero
        : queueFlight
        ? PlayerQueueMotion.duration
        : PlayerLyricsMotion.duration;
    final curve = queueFlight
        ? PlayerQueueMotion.curve
        : PlayerLyricsMotion.curve;
    // Easing the controller itself starts every reversal at its current value.
    // Switching between forward/reverse CurvedAnimations can otherwise jump.
    transition
        .animateTo(lyrics || queue ? 1 : 0, duration: duration, curve: curve)
        .whenCompleteOrCancel(() {
          if (!_disposed) _scheduleIdle();
        });
    // Retarget from both current values, even on a three-way interruption.
    // Equal timing keeps queue <= shared progress; the remainder is lyrics.
    queueTransition
        .animateTo(queue ? 1 : 0, duration: duration, curve: curve)
        .whenCompleteOrCancel(() {
          if (!_disposed) _scheduleIdle();
        });
    // Material uses its own curve but the same duration, so a reversal
    // continues from the current value and still lands with the geometry.
    frame
        .animateTo(
          lyrics || queue ? 1 : 0,
          duration: duration,
          curve: PlayerLyricsMotion.frameCurve,
        )
        .whenCompleteOrCancel(() {
          if (!_disposed) _scheduleIdle();
        });
    translationReveal
        .animateTo(
          lyrics ? 1 : 0,
          duration: duration,
          curve: PlayerLyricsMotion.frameCurve,
        )
        .whenCompleteOrCancel(() {
          if (!_disposed) _scheduleIdle();
        });
    notifyListeners();
  }

  void _reveal() {
    if (!_idle) return;
    _idle = false;
    chrome.animateTo(
      1,
      duration: _reduceMotion
          ? Duration.zero
          : PlayerLyricsMotion.chromeDuration,
      curve: PlayerLyricsMotion.curve,
    );
    notifyListeners();
  }

  void activity() {
    _timer?.cancel();
    // Explicit interaction during entry takes precedence over automatic folding.
    _foldQueueAfterEntry = false;
    if (!_active) return;
    _reveal();
    _scheduleIdle();
  }

  /// Hover and wheel input; like touches, it cannot reopen a folded queue.
  void passiveActivity() => _queue ? _scheduleIdle() : activity();

  void pointerDown(int pointer) {
    if (_pointers.isEmpty) _gestureStartedFolded = _idle;
    _pointers[pointer] = Offset.zero;
    _touch();
  }

  void pointerMove(int pointer, Offset delta) {
    final previous = _pointers[pointer];
    if (previous == null) return;
    final reversing =
        (previous.dy < 0 && delta.dy > 0) || (previous.dy > 0 && delta.dy < 0);
    final movement = reversing ? delta : previous + delta;
    _pointers[pointer] = movement;
    if (_lyrics &&
        movement.dy.abs() > kTouchSlop &&
        movement.dy.abs() > movement.dx.abs()) {
      if (movement.dy < 0) {
        if (_active && !_accessibleNavigation && !_interactionSuspended) {
          _fold();
        }
      } else {
        activity();
      }
      return;
    }
    _touch();
  }

  void pointerUp(int pointer) {
    // Global release/cancel recovery also observes unrelated pointers.
    if (_pointers.remove(pointer) == null) return;
    _touch();
  }

  void _touch() {
    // Queue touches and scrolls only keep a visible card awake; a card tap
    // ([activity]) is the sole way to reopen it, and they do not cancel the
    // default fold after entry, which runs once every finger is released.
    if (_queue) {
      _scheduleIdle();
    } else if (!_lyrics || !_idle) {
      activity();
    }
  }

  /// 固定控制区：不再因静止或上滑而收起成底部小条。
  void setPinned(bool pinned) {
    if (_pinned == pinned) return;
    _pinned = pinned;
    if (pinned) {
      _timer?.cancel();
      _reveal();
    } else {
      _scheduleIdle();
    }
  }

  void setInteractionSuspended(bool suspended) {
    if (_interactionSuspended == suspended) return;
    _interactionSuspended = suspended;
    _gestureStartedFolded = false;
    activity();
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _timer?.cancel();
    _pointers.clear();
    _gestureStartedFolded = false;
    if (!active) return;
    // Returning to the queue keeps a folded card folded.
    if (_queue) {
      _scheduleIdle();
    } else {
      activity();
    }
  }

  void _scheduleIdle() {
    _timer?.cancel();
    if (!_active ||
        _pinned ||
        (!_lyrics && !_queue) ||
        _idle ||
        _accessibleNavigation ||
        _interactionSuspended ||
        _pointers.isNotEmpty ||
        transition.isAnimating ||
        queueTransition.isAnimating ||
        frame.isAnimating ||
        translationReveal.isAnimating ||
        transition.value != 1 ||
        queueTransition.value != (_queue ? 1 : 0)) {
      return;
    }
    if (_foldQueueAfterEntry) {
      _foldQueueAfterEntry = false;
      _fold();
    } else {
      _timer = Timer(PlayerLyricsMotion.idleDelay, _fold);
    }
  }

  void _fold() {
    if (_idle || _pinned) return;
    _timer?.cancel();
    _idle = true;
    chrome.animateTo(
      0,
      duration: _reduceMotion ? Duration.zero : PlayerLyricsMotion.foldDuration,
      curve: PlayerLyricsMotion.foldCurve,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    transition.dispose();
    queueTransition.dispose();
    frame.dispose();
    translationReveal.dispose();
    chrome.dispose();
    super.dispose();
  }
}
