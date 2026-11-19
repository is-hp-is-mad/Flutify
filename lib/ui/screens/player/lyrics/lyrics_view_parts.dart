import 'package:flutter/material.dart';

import '../../../widgets/skeleton.dart';

/// 一段无人声片段：[entry] 为显示呼吸点的行（-1 为第一句之前的前奏）。
@immutable
class LyricsGap {
  final int entry;
  final int startMs;
  final int endMs;

  const LyricsGap(this.entry, this.startMs, this.endMs);
}

class LyricsReflowScrollController extends ScrollController {
  final double? Function() reflowTarget;

  LyricsReflowScrollController({required this.reflowTarget});

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _LyricsReflowScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    reflowTarget: reflowTarget,
  );
}

class _LyricsReflowScrollPosition extends ScrollPositionWithSingleContext {
  final double? Function() reflowTarget;

  _LyricsReflowScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    required this.reflowTarget,
  });

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final target = reflowTarget();
    if (target != null && hasPixels) {
      final corrected = target.clamp(minScrollExtent, maxScrollExtent);
      if (corrected != pixels) correctBy(corrected - pixels);
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// 歌词加载中的骨架（白色半透明横条，适配深色流动背景）。
class LyricsLoadingLines extends StatelessWidget {
  final double topInset;

  const LyricsLoadingLines({super.key, required this.topInset});

  static const List<double> _widths = [0.82, 0.64, 0.9, 0.48, 0.74, 0.58];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(28, topInset + 24, 28, 0),
      child: SkeletonPulse(
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final w in _widths)
                Container(
                  width: constraints.maxWidth * w,
                  height: 26,
                  margin: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 歌词区上下边缘渐隐用的 dstIn 遮罩；[enabled] 为 false 时不套任何图层（仅诊断用）。
class LyricsEdgeMask extends StatelessWidget {
  const LyricsEdgeMask({
    super.key,
    required this.enabled,
    required this.shaderCallback,
    required this.child,
  });

  final bool enabled;
  final ShaderCallback shaderCallback;
  final Widget child;

  @override
  Widget build(BuildContext context) => enabled
      ? ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: shaderCallback,
          child: child,
        )
      : child;
}
