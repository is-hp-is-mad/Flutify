import 'package:flutter/material.dart';

import '../../core/theme/flutify_tokens.dart';

/// 桌面端三栏中的单块面板：圆角 16（随「圆角风格」缩放）、内容裁切、底色为 `surface`。
///
/// 面板浮在更深一级的窗口底色（`surfaceContainerLowest`）之上，
/// 靠色阶差而不是描边或阴影来分隔，与 Spotify 新版桌面端一致。
/// 使用 [Material] 而非 DecoratedBox，保证子树中的水波纹可见。
class PanelSurface extends StatelessWidget {
  final Widget child;

  const PanelSurface({super.key, required this.child});

  static const double baseRadius = 16;

  /// 当前主题下的面板圆角。
  static BorderRadius radiusOf(BuildContext context) => context.tokens.radius(baseRadius);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: radiusOf(context),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
