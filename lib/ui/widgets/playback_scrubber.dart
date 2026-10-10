import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../providers/playback_provider.dart';
import 'text_metrics.dart';

/// 播放进度条（全屏播放器 / 桌面播放栏共用）。
///
/// - 仅本组件订阅高频的 positionNotifier，父组件不会因进度变化重建。
/// - 拖动过程中只更新本地值，松手（onChangeEnd）时才真正 seek，
///   避免每一帧都向音频引擎发送 seek 请求。
class PlaybackScrubber extends StatefulWidget {
  /// true：桌面样式（时间在两侧，单行）；false：移动端样式（时间在下方）。
  final bool compact;
  /// Android shared-element morph: 0 = original detail, 1 = lyrics card.
  /// Null preserves the existing desktop/mobile layout and behavior.
  final double? compactProgress;
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? labelColor;

  const PlaybackScrubber({
    super.key,
    this.compact = false,
    this.compactProgress,
    this.activeColor,
    this.inactiveColor,
    this.labelColor,
  });

  static double expandedLabelHeight(BuildContext context) =>
      TextMetrics.lineHeight(
        context,
        DefaultTextStyle.of(context).style.merge(const TextStyle(fontSize: 11)),
      );

  @override
  State<PlaybackScrubber> createState() => _PlaybackScrubberState();
}

class _PlaybackScrubberState extends State<PlaybackScrubber> {
  /// 拖动中的临时值（毫秒）；为 null 表示未在拖动。
  double? _dragValueMs;

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    final durationMs = context.select<PlaybackProvider, int>((p) => p.duration.inMilliseconds);
    final colorScheme = Theme.of(context).colorScheme;
    final labelColor = widget.labelColor ?? colorScheme.onSurfaceVariant;
    final labelStyle = TextStyle(
      color: labelColor,
      fontSize: 11,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final compactness = widget.compactProgress ?? (widget.compact ? 1.0 : 0.0);
    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: lerpDouble(3.5, 3, compactness),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: lerpDouble(6, 5, compactness)!),
      overlayShape: RoundSliderOverlayShape(overlayRadius: lerpDouble(14, 10, compactness)!),
      activeTrackColor: widget.activeColor,
      inactiveTrackColor: widget.inactiveColor,
      thumbColor: widget.activeColor,
    );

    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playback.positionNotifier,
        builder: (context, position, _) {
          final maxMs = durationMs > 0 ? durationMs.toDouble() : 1.0;
          final valueMs = (_dragValueMs ?? position.inMilliseconds.toDouble()).clamp(0.0, maxMs);
          final shown = Duration(milliseconds: valueMs.round());

          final slider = SliderTheme(
            data: sliderTheme,
            child: Slider(
              value: valueMs,
              max: maxMs,
              onChangeStart: (v) => setState(() => _dragValueMs = v),
              onChanged: (v) => setState(() => _dragValueMs = v),
              onChangeEnd: (v) {
                playback.seekTo(Duration(milliseconds: v.round()));
                setState(() => _dragValueMs = null);
              },
            ),
          );

          final remaining = Duration(milliseconds: (durationMs - valueMs).round().clamp(0, durationMs));
          if (widget.compactProgress != null) {
            return _MorphingScrubber(
              progress: compactness,
              labelStyle: labelStyle,
              elapsed: Formatters.formatDuration(shown),
              remaining: '-${Formatters.formatDuration(remaining)}',
              total: Formatters.formatDurationMs(durationMs),
              slider: slider,
            );
          }

          if (widget.compact) {
            return Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(Formatters.formatDuration(shown), style: labelStyle, textAlign: TextAlign.right),
                ),
                const SizedBox(width: 8),
                Expanded(child: slider),
                const SizedBox(width: 8),
                SizedBox(
                  width: 40,
                  child: Text(Formatters.formatDurationMs(durationMs), style: labelStyle),
                ),
              ],
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              slider,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(Formatters.formatDuration(shown), style: labelStyle),
                    Text('-${Formatters.formatDuration(remaining)}', style: labelStyle),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One slider and stable label subtrees throughout the flight. Reparenting a
/// Slider between a Column and Row would cancel a live drag and reset its state.
class _MorphingScrubber extends StatelessWidget {
  const _MorphingScrubber({
    required this.progress,
    required this.labelStyle,
    required this.elapsed,
    required this.remaining,
    required this.total,
    required this.slider,
  });

  final double progress;
  final TextStyle labelStyle;
  final String elapsed;
  final String remaining;
  final String total;
  final Widget slider;

  @override
  Widget build(BuildContext context) {
    final labelHeight = PlaybackScrubber.expandedLabelHeight(context);
    final painter = TextPainter(
      text: TextSpan(
        text: total.length > 5 ? '-00:00:00' : '-00:00',
        style: DefaultTextStyle.of(context).style.merge(labelStyle),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final labelWidth = math.max(40.0, painter.width);
    painter.dispose();
    return LayoutBuilder(
      builder: (context, box) {
        final side = math.min(labelWidth, box.maxWidth * 0.35);
        final inset = (side + 8) * progress;
        final labelY = lerpDouble(48, (48 - labelHeight) / 2, progress)!;
        final labelInset = lerpDouble(14, 0, progress)!;
        return SizedBox(
          height: 48 + labelHeight * (1 - progress),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(left: inset, right: inset, top: 0, height: 48, child: slider),
              Positioned(
                left: labelInset,
                top: labelY,
                width: side,
                height: labelHeight,
                child: Align(
                  alignment: Alignment.lerp(Alignment.centerLeft, Alignment.centerRight, progress)!,
                  child: Text(elapsed, style: labelStyle, maxLines: 1),
                ),
              ),
              Positioned(
                right: labelInset,
                top: labelY,
                width: side,
                height: labelHeight,
                child: Stack(
                  alignment: Alignment.lerp(Alignment.centerRight, Alignment.centerLeft, progress)!,
                  children: [
                    ExcludeSemantics(
                      excluding: progress >= 0.5,
                      child: Opacity(opacity: 1 - progress, child: Text(remaining, style: labelStyle, maxLines: 1)),
                    ),
                    ExcludeSemantics(
                      excluding: progress < 0.5,
                      child: Opacity(opacity: progress, child: Text(total, style: labelStyle, maxLines: 1)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 细进度线（MiniPlayer 底部），同样只局部订阅进度。
class PlaybackProgressLine extends StatelessWidget {
  final double height;
  final Color? color;
  final Color? backgroundColor;

  const PlaybackProgressLine({super.key, this.height = 2.5, this.color, this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    final durationMs = context.select<PlaybackProvider, int>((p) => p.duration.inMilliseconds);
    final colorScheme = Theme.of(context).colorScheme;

    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: playback.positionNotifier,
        builder: (context, position, _) {
          final fraction = durationMs <= 0 ? 0.0 : (position.inMilliseconds / durationMs).clamp(0.0, 1.0);
          return LinearProgressIndicator(
            value: fraction,
            minHeight: height,
            backgroundColor: backgroundColor ?? colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(color ?? colorScheme.primary),
          );
        },
      ),
    );
  }
}
