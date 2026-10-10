import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/animation.dart';

/// Measured Android 6.5.3 line-synced choreography; no synthetic word timing.
abstract final class AppleMusicMotion {
  static const moveDuration = Duration(milliseconds: 750);
  static const moveCurve = Cubic(.4, .1, 0, 1);
  static const focusCurve = Cubic(.39, .575, .565, 1);
  static const minimumGapMs = 7000;

  static int delayMs(int distance) =>
      const [0, 25, 44, 56, 63][distance.clamp(0, 4)];

  static double remainingMove(int distance, double elapsedMs) =>
      1 -
      moveCurve.transform(((elapsedMs - delayMs(distance)) / 750).clamp(0, 1));

  static int leadMs({int? silentGapMs}) => silentGapMs == null
      ? 500
      : (480 + 270 * (silentGapMs.clamp(200, 750) - 200) / 550).round();

  static ({List<double> opacity, double scale, double fade}) dots(
    int elapsedMs,
    int gapMs, {
    bool reduceMotion = false,
  }) {
    final elapsed = elapsedMs.clamp(0, math.max(1, gapMs)).toInt();
    final e = math.max(1, gapMs - 800);
    final segment = ((e + 750) / 3).round();
    final exitStart = math.max(0, gapMs - 1300);
    const fillCurve = Cubic(0, .25, 1, .58);
    double fill(int i, int time) => fillCurve.transform(
      ((time - segment * i) / math.max(1, i == 2 ? e - segment * 2 : segment))
          .clamp(0, 1),
    );
    final opacity = [
      for (var i = 0; i < 3; i++)
        lerpDouble(
              .18,
              .94,
              i == 2 && elapsed >= exitStart
                  ? lerpDouble(
                      fill(i, exitStart),
                      1,
                      ((elapsed - exitStart) / 750).clamp(0, 1),
                    )!
                  : fill(i, elapsed),
            )! *
            (reduceMotion
                ? 1
                : math.pow(((elapsed - i * 50) / 750).clamp(0, 1), 2)),
    ];
    if (reduceMotion) return (opacity: opacity, scale: 1, fade: 1);
    final cycles = math.max(1, e ~/ 4000);
    double breathe(int time) {
      final phase = (time / (e / cycles)) % 1;
      final triangle = 1 - (2 * phase - 1).abs();
      return 1 + .2 * triangle * triangle * (3 - 2 * triangle);
    }

    var scale = breathe(elapsed);
    var fade = 1.0;
    if (elapsed >= exitStart) {
      final exit = elapsed - exitStart;
      if (exit < 750) {
        scale = lerpDouble(
          breathe(exitStart),
          1.2,
          const Cubic(.25, .1, .25, 1).transform(exit / 750),
        )!;
      } else {
        final t = const Cubic(
          .25,
          0,
          1,
          .2,
        ).transform(((exit - 750) / 250).clamp(0, 1));
        scale = lerpDouble(1.2, .5, t)!;
        fade = 1 - t;
      }
    }
    return (opacity: opacity, scale: scale, fade: fade);
  }
}
