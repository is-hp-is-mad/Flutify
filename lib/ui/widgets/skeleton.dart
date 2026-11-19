import 'package:flutter/material.dart';

/// 加载占位（骨架屏）。
///
/// [SkeletonPulse] 驱动一次呼吸动画，子树中所有 [SkeletonBox] 共享同一个
/// 动画值，避免每个方块各自创建 AnimationController。
class SkeletonPulse extends StatefulWidget {
  final Widget child;

  const SkeletonPulse({super.key, required this.child});

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    lowerBound: 0.45,
    upperBound: 1.0,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FadeTransition 只改合成层透明度，不会重建子树
    return FadeTransition(opacity: _controller, child: widget.child);
  }
}

/// 骨架方块。
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final BorderRadius borderRadius;
  final bool circular;

  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.circular = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circular ? null : borderRadius,
      ),
    );
  }
}

/// 横向卡架的骨架（与主页卡架 + ExpressiveCard 尺寸一致，加载完成时不跳动）。
class SkeletonShelf extends StatelessWidget {
  final int count;
  final bool circular;

  const SkeletonShelf({super.key, this.count = 5, this.circular = false});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: SkeletonBox(width: 160, height: 20),
          ),
          SizedBox(
            height: 230,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: count,
              itemBuilder: (context, _) => Padding(
                padding: const EdgeInsets.only(right: 14, top: 6, left: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(
                      width: 136,
                      height: 136,
                      circular: circular,
                      borderRadius: const BorderRadius.all(Radius.circular(16)),
                    ),
                    const SizedBox(height: 12),
                    const SkeletonBox(width: 110, height: 12),
                    const SizedBox(height: 8),
                    const SkeletonBox(width: 76, height: 10),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 网格骨架（搜索页流派卡等）。
class SkeletonGrid extends StatelessWidget {
  final int count;
  final double aspectRatio;

  const SkeletonGrid({super.key, this.count = 8, this.aspectRatio = 1.6});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final columns = width >= 1000 ? 4 : width >= 640 ? 3 : 2;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: aspectRatio,
            ),
            itemCount: count,
            itemBuilder: (context, _) => const SkeletonBox(
              height: double.infinity,
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
          );
        },
      ),
    );
  }
}
