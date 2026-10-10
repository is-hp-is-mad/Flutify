import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// Shared Apple-style timing for the Android player's coordinated transitions.
abstract final class PlayerLyricsMotion {
  // Responsive takeoff with a long, gentle landing; no bounce or second easing
  // on any component. The scene's geometry receives this already-eased value.
  static const curve = Cubic(0.22, 0.8, 0.22, 1);
  static const duration = Duration(milliseconds: 640);
  static const chromeDuration = Duration(milliseconds: 300);
  static const foldCurve = Cubic(0.32, 0.72, 0, 1);
  static const foldDuration = Duration(milliseconds: 420);
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
      chrome = AnimationController(vsync: vsync, value: 1) {
    transition.addListener(notifyListeners);
    queueTransition.addListener(notifyListeners);
    chrome.addListener(notifyListeners);
  }

  final AnimationController transition;
  final AnimationController queueTransition;
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
    final keepFolded =
        queue &&
        _pointers.isEmpty &&
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

  void pointerDown(int pointer) {
    if (_pointers.isEmpty) _gestureStartedFolded = _idle;
    _pointers[pointer] = Offset.zero;
    if (!_lyrics || !_idle) activity();
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
    if (!_lyrics || !_idle) activity();
  }

  void pointerUp(int pointer) {
    // Global release/cancel recovery also observes unrelated pointers.
    if (_pointers.remove(pointer) == null) return;
    if (!_lyrics || !_idle) activity();
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
    if (active) activity();
  }

  void _scheduleIdle() {
    _timer?.cancel();
    if (!_active ||
        (!_lyrics && !_queue) ||
        _idle ||
        _accessibleNavigation ||
        _interactionSuspended ||
        _pointers.isNotEmpty ||
        transition.isAnimating ||
        queueTransition.isAnimating ||
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
    if (_idle) return;
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
    chrome.dispose();
    super.dispose();
  }
}
