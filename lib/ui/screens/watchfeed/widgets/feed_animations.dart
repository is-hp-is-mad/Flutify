import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// 官方 feed 的三段 Lottie 动画按关键帧自绘（不引入 lottie 依赖）。

/// 官方 Lottie 的 ease（出 0.333/0、入 0.667/1）。
const Cubic _kLottieEase = Cubic(0.333, 0, 0.667, 1);

/// 叠加层入场 / 引导文字的官方缓动 `Cubic(0.3, 0, 0.4, 1)`。
const Cubic kFeedEase = Cubic(0.3, 0, 0.4, 1);

// -----------------------------------------------------------------------------
// 波形：misc.spotifycdn.com/watch-feed/playback-animation.json
// -----------------------------------------------------------------------------

/// 播放波形：20 根白色圆头竖条，106×15 设计尺寸、0.67 秒一循环（60fps 下 40 帧）。
/// 每根竖条在第 0/10/20/30/40 帧的高度取自官方 Lottie。
class FeedWaveform extends StatefulWidget {
  const FeedWaveform({
    super.key,
    this.playing = true,
    this.color = Colors.white,
  });

  final bool playing;
  final Color color;

  /// 每根竖条在 5 个关键帧上的高度（设计尺寸，最高 15）。
  static const List<List<double>> bars = [
    [5, 12, 8, 10, 5],
    [3, 8, 10, 5, 3],
    [6, 8, 10, 8, 6],
    [8, 12, 10, 4, 8],
    [4, 6, 4, 8, 4],
    [2, 3, 6, 10, 2],
    [5, 6, 8, 12, 5],
    [7, 4, 6, 10, 7],
    [8, 6, 8, 10, 8],
    [7, 4, 6, 2, 7],
    [6, 2, 4, 10, 6],
    [12, 8, 10, 6, 12],
    [15, 12, 10, 7, 15],
    [12, 8, 6, 8, 12],
    [8, 5, 7, 12, 8],
    [4, 6, 8, 6, 4],
    [2, 4, 6, 4, 2],
    [6, 8, 10, 14, 6],
    [8, 14, 8, 12, 8],
    [2, 8, 6, 8, 2],
  ];

  @override
  State<FeedWaveform> createState() => _FeedWaveformState();
}

class _FeedWaveformState extends State<FeedWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 667),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant FeedWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.playing) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 106 / 15,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _WaveformPainter(_controller, widget.color),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.progress, this.color) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 106;
    final t = progress.value * 4; // 0~4：落在第几个关键帧区间
    final segment = t.floor().clamp(0, 3);
    final local = _kLottieEase.transform((t - segment).clamp(0.0, 1.0));
    final paint = Paint()..color = color;
    const barWidth = 1.5;
    for (var i = 0; i < FeedWaveform.bars.length; i++) {
      final keys = FeedWaveform.bars[i];
      final h = lerpDouble(keys[segment], keys[segment + 1], local)!;
      final cx = (0.75 + i * 5.5) * scale;
      final rect = Rect.fromCenter(
        center: Offset(cx, size.height / 2),
        width: barWidth * scale,
        height: h * scale,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barWidth * scale / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.progress != progress;
}

// -----------------------------------------------------------------------------
// 双击保存的彩纸（官方 plus_selected_confetti，162dp、居中、播一次）
// -----------------------------------------------------------------------------

/// 双击保存时的反馈：中心「✓」圆章弹出 + 一圈彩纸向外迸散后淡出，约 0.9 秒后回调 [onDone]。
class FeedSaveBurst extends StatefulWidget {
  const FeedSaveBurst({super.key, required this.onDone, this.size = 162});

  final VoidCallback onDone;
  final double size;

  @override
  State<FeedSaveBurst> createState() => _FeedSaveBurstState();
}

class _FeedSaveBurstState extends State<FeedSaveBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 系统减弱动效：不播放，直接结束（保存本身已生效）。
      if (MediaQuery.disableAnimationsOf(context)) {
        widget.onDone();
      } else {
        _controller.forward().whenComplete(widget.onDone);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(painter: _BurstPainter(_controller, accent)),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  _BurstPainter(this.progress, this.accent) : super(repaint: progress);

  final Animation<double> progress;
  final Color accent;

  static const _palette = [
    Color(0xFF1ED760),
    Color(0xFFFFFFFF),
    Color(0xFFFFC864),
    Color(0xFF9CF0E1),
    Color(0xFFF573A0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    // 圆章：0~30% 弹出（0.4 → 1.15 → 1），70% 后淡出。
    final pop = t < 0.2
        ? lerpDouble(0.4, 1.15, Curves.easeOut.transform(t / 0.2))!
        : t < 0.3
        ? lerpDouble(1.15, 1.0, (t - 0.2) / 0.1)!
        : 1.0;
    final fade = t < 0.7 ? 1.0 : 1 - (t - 0.7) / 0.3;
    final badge = radius * 0.34 * pop;
    canvas.drawCircle(
      center,
      badge,
      Paint()..color = accent.withValues(alpha: fade),
    );
    final check = Path()
      ..moveTo(center.dx - badge * 0.42, center.dy + badge * 0.02)
      ..lineTo(center.dx - badge * 0.1, center.dy + badge * 0.34)
      ..lineTo(center.dx + badge * 0.45, center.dy - badge * 0.3);
    canvas.drawPath(
      check,
      Paint()
        ..color = Colors.black.withValues(alpha: fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = badge * 0.18
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 彩纸：14 片从圆章边缘沿放射方向飞出，15%~100% 区间运动并渐隐。
    if (t < 0.15) return;
    final p = Curves.easeOutCubic.transform(((t - 0.15) / 0.85).clamp(0, 1));
    for (var i = 0; i < 14; i++) {
      final angle = i / 14 * 2 * math.pi + (i.isEven ? 0.12 : -0.08);
      final distance = radius * (0.38 + 0.55 * p) * (i % 3 == 0 ? 0.85 : 1);
      final pos = center + Offset(math.cos(angle), math.sin(angle)) * distance;
      final paint = Paint()
        ..color = _palette[i % _palette.length].withValues(alpha: 1 - p);
      final piece = radius * (i % 2 == 0 ? 0.05 : 0.035);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(angle + p * 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: piece * 2.4,
            height: piece,
          ),
          Radius.circular(piece / 2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.progress != progress;
}

// -----------------------------------------------------------------------------
// 上滑引导：fex.spotifycdn.com/vertical-onboarding-animation.json
// -----------------------------------------------------------------------------

/// 手指上滑引导（3 秒一循环，30fps 90 帧）：
/// 第 5~15 帧触点圆放大 → 第 25~34 帧手指按下 → 第 55~65 帧手指上移并拖出轨迹 →
/// 第 70~78 帧触点收起 → 第 80~85 帧手指回到起点。
class FeedSwipeUpHint extends StatefulWidget {
  const FeedSwipeUpHint({super.key, this.playing = true});

  final bool playing;

  @override
  State<FeedSwipeUpHint> createState() => _FeedSwipeUpHintState();
}

class _FeedSwipeUpHintState extends State<FeedSwipeUpHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant FeedSwipeUpHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.playing) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// [frames] 内按官方 ease 插值（帧号为 30fps 下的第几帧）。
  static double _seg(double frame, double from, double to) =>
      _kLottieEase.transform(((frame - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    // 设计尺寸 480×820；手指起点 y≈754、顶点 y≈142。
    return AspectRatio(
      aspectRatio: 480 / 820,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final f = _controller.value * 90;
          return LayoutBuilder(
            builder: (context, constraints) {
              final s = constraints.maxWidth / 480;
              // 手指位置：25~34 帧轻按（-8,-8），55~65 帧上移到顶点，71~85 帧回到起点。
              final press = _seg(f, 25, 34) - _seg(f, 71, 85);
              final rise = _seg(f, 55, 65) - _seg(f, 71, 85);
              final fingerX = 300 - 8 * press - 16 * rise;
              final fingerY = 754 - 8 * press - 604 * rise;
              final touch = _seg(f, 5, 15) - _seg(f, 70.5, 78);
              final trail = f < 51
                  ? 0.0
                  : f < 55
                  ? (f - 51) / 4
                  : f < 68
                  ? 1.0
                  : (1 - (f - 68) / 3.5).clamp(0.0, 1.0);
              final tipY = fingerY - 40;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // 拖尾：从起点到当前指尖的渐隐竖条。
                  if (trail > 0)
                    Positioned(
                      left: (fingerX - 6) * s,
                      top: tipY * s,
                      width: 28 * s,
                      height: math.max(0, 754 - 40 - tipY) * s + 28 * s,
                      child: Opacity(
                        opacity: trail,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14 * s),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.white.withValues(alpha: 0.6),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 触点圆。
                  Positioned(
                    left: (fingerX + 8 - 36) * s,
                    top: (tipY + 14 - 36) * s,
                    width: 72 * s,
                    height: 72 * s,
                    child: Transform.scale(
                      scale: touch,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
                  // 手指（官方 -35° → 上移时 -22°）。
                  Positioned(
                    left: (fingerX - 40) * s,
                    top: (fingerY - 60) * s,
                    child: Transform.rotate(
                      angle: (-35 + 13 * rise) * math.pi / 180,
                      child: Icon(
                        Icons.touch_app_rounded,
                        size: 120 * s,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
