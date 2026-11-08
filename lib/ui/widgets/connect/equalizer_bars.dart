import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';

/// 「正在播放」跳动音柱：三根圆头竖条错相起伏；[playing] 为 false 或减弱动效时静止为三档高度。
class EqualizerBars extends StatefulWidget {
  final bool playing;
  final Color color;
  final double size;

  const EqualizerBars({super.key, required this.playing, required this.color, this.size = 16});

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  /// 静止时三根柱的相对高度。
  static const List<double> _rest = [0.45, 0.8, 0.6];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(EqualizerBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final animate = widget.playing && !context.reduceMotion;
    if (animate && !_controller.isAnimating) _controller.repeat();
    if (!animate && _controller.isAnimating) _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _BarsPainter(
              color: widget.color,
              heights: [
                for (var i = 0; i < 3; i++)
                  _controller.isAnimating
                      ? 0.3 +
                            0.7 * (0.5 + 0.5 * math.sin((_controller.value + i * 0.27) * 2 * math.pi * (1 + i * 0.35)))
                      : _rest[i],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final Color color;
  final List<double> heights;

  _BarsPainter({required this.color, required this.heights});

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = size.width / 5;
    final paint = Paint()..color = color;
    for (var i = 0; i < heights.length; i++) {
      final h = size.height * heights[i].clamp(0.15, 1.0);
      final left = barWidth * (i * 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(left, size.height - h, barWidth, h), Radius.circular(barWidth / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) => oldDelegate.color != color || oldDelegate.heights != heights;
}
