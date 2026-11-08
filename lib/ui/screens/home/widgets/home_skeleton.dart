import 'package:flutter/material.dart';

import '../../../widgets/skeleton.dart';

/// 主页首次加载的骨架：快捷入口网格 + 两个卡架，布局与真实内容一致，加载完成时不跳动。
class HomeSkeleton extends StatelessWidget {
  final bool desktop;

  const HomeSkeleton({super.key, required this.desktop});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = desktop && constraints.maxWidth >= 720 ? 4 : 2;
                final tileWidth = (constraints.maxWidth - 8 * (columns - 1)) / columns;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (var i = 0; i < 8; i++) SkeletonBox(width: tileWidth, height: desktop ? 64 : 56)],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          const SkeletonShelf(),
          const SkeletonShelf(),
        ],
      ),
    );
  }
}
