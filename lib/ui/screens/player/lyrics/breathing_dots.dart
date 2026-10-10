import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/theme/flutify_tokens.dart';
import 'apple_music_motion.dart';

/// 无人声片段（前奏 / 间奏）的三个呼吸点（Apple Music 风格）。
///
/// - 三点同步缓慢放大缩小，像呼吸；
/// - 一开始半透明，随片段推进从左到右依次变为纯白；
/// - 片段最后一刻先放大，再缩小直至消失，正好接上下一句歌词。
///
/// 进度流约 200ms 推送一次，这里按帧在两次推送之间外推，动画才不会一顿一顿；
/// 进度超过 [_staleAfter] 没有前进（暂停 / 缓冲）时停在原地，呼吸也随之停止。
class BreathingDots extends StatefulWidget {
  /// 播放进度。
  final ValueListenable<Duration> position;
  final bool isPlaying;

  /// 叠加到进度上的提前量（与歌词切行一致），呼吸点与下一句的出现严丝合缝。
  final int leadMs;

  /// 片段起止（毫秒）。
  final int startMs;
  final int endMs;

  /// 单个圆点直径。
  final double dotSize;

  /// 歌词居中对齐时以中心缩放，否则以左端缩放（与歌词行一致）。
  final bool centered;
  final bool appleMusicStyle;

  const BreathingDots({
    super.key,
    required this.position,
    required this.isPlaying,
    required this.startMs,
    required this.endMs,
    required this.dotSize,
    this.leadMs = 0,
    this.centered = false,
    this.appleMusicStyle = false,
  });

  @override
  State<BreathingDots> createState() => _BreathingDotsState();
}

class _BreathingDotsState extends State<BreathingDots>
    with SingleTickerProviderStateMixin {
  /// 一次呼吸（放大 + 缩小）的周期。
  static const double _breathPeriod = 2.8;

  /// 收尾「放大 → 缩小消失」的最长时长。
  static const int _finaleMs = 900;

  late final Ticker _ticker = createTicker(_onTick);
  int _anchorMs = 0;
  Duration _sincePosition = Duration.zero;
  bool _reduceMotion = false;
  bool _tickerEnabled = false;

  /// 呼吸相位（秒），只在播放时累加，暂停后恢复不跳变。
  double _breath = 0;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _anchorMs = _positionMs;
    widget.position.addListener(_onPosition);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = context.reduceMotion;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant BreathingDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    if (oldWidget.position != widget.position ||
        oldWidget.leadMs != widget.leadMs ||
        oldWidget.startMs != widget.startMs ||
        oldWidget.endMs != widget.endMs ||
        oldWidget.isPlaying != widget.isPlaying) {
      final pausing =
          widget.appleMusicStyle && oldWidget.isPlaying && !widget.isPlaying;
      _anchorMs = pausing ? _nowMs : _positionMs;
      _sincePosition = Duration.zero;
    }
    _syncTicker();
  }

  int get _positionMs => widget.position.value.inMilliseconds + widget.leadMs;

  void _onPosition() {
    setState(() {
      _anchorMs = _positionMs;
      _sincePosition = Duration.zero;
    });
  }

  void _syncTicker() {
    if (widget.isPlaying && !_reduceMotion && _tickerEnabled) {
      if (_ticker.isActive) return;
      _lastTick = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastTick;
    _lastTick = elapsed;
    setState(() {
      _sincePosition += delta;
      _breath += delta.inMicroseconds / 1e6;
    });
  }

  int get _nowMs => _anchorMs + _sincePosition.inMilliseconds;

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    if (widget.appleMusicStyle) return _appleDots(reduceMotion);
    final start = widget.startMs;
    final end = math.max(widget.endMs, start + 1);
    final now = _nowMs.clamp(start, end);
    final finale = math
        .min(_finaleMs, ((end - start) * 0.3).round())
        .clamp(1, _finaleMs);
    final fillEnd = end - finale;

    // 依次点亮：总进度三等分，每个点在自己那一段里从半透明变成纯白
    final fill = fillEnd <= start
        ? 1.0
        : ((now - start) / (fillEnd - start)).clamp(0.0, 1.0);

    // 呼吸：0.82 ↔ 1.0 之间缓慢起伏（余弦，起点即最小值，首帧不跳）
    final breathe = reduceMotion
        ? 1.0
        : 0.91 - 0.09 * math.cos(2 * math.pi * _breath / _breathPeriod);

    var scale = breathe;
    var fade = 1.0;
    if (!reduceMotion && now > fillEnd) {
      // 收尾：前 40% 放大到 1.3，后 60% 缩小到 0 并淡出
      final k = (now - fillEnd) / finale;
      if (k < 0.4) {
        scale = lerpDouble(
          breathe,
          1.3,
          Curves.easeOutCubic.transform(k / 0.4),
        )!;
      } else {
        final out = Curves.easeInCubic.transform(
          ((k - 0.4) / 0.6).clamp(0.0, 1.0),
        );
        scale = 1.3 * (1 - out);
        fade = 1 - out;
      }
    }

    final d = widget.dotSize;
    return SizedBox(
      // 预留放大到 1.3 倍的空间，收尾时不顶到相邻内容
      height: d * 1.4,
      child: Transform.scale(
        scale: scale,
        alignment: widget.centered ? Alignment.center : Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: d * 0.62),
              Container(
                width: d,
                height: d,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFFFFFF).withValues(
                    alpha:
                        lerpDouble(0.32, 1.0, (fill * 3 - i).clamp(0.0, 1.0))! *
                        fade,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _appleDots(bool reduceMotion) {
    final frame = AppleMusicMotion.dots(
      _nowMs - widget.startMs,
      widget.endMs - widget.startMs,
      reduceMotion: reduceMotion,
    );
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      label: '•••',
      child: SizedBox(
        height: 14,
        child: Transform.scale(
          scale: frame.scale,
          alignment: widget.centered
              ? Alignment.center
              : rtl
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(
                      0xFFFFFFFF,
                    ).withValues(alpha: frame.opacity[i] * frame.fade),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
