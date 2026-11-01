import 'package:flutter/material.dart';

import '../../core/theme/flutify_tokens.dart';
import '../screens/player/player_expansion.dart';
import 'hyper_surface.dart';

/// 迷你播放器的外框（本机与远程共用）。
///
/// MD3E：横向铺满、封面取色的胶囊。柔光玻璃：与底栏等宽、等高的浮动控件材质，下方内容透过模糊可见。
abstract final class MiniPlayerStyle {
  /// 与底栏（miuix BottomNavigator）相同：最宽 344，左右留 24。
  static const double _hyperMaxWidth = 344;

  static double artworkSize(BuildContext context) =>
      context.tokens.hyperMaterial ? 40 : 44;

  static EdgeInsets rowPadding(BuildContext context) =>
      context.tokens.hyperMaterial
      ? const EdgeInsets.fromLTRB(8, 8, 6, 8)
      : const EdgeInsets.fromLTRB(7, 7, 8, 9);

  /// 文字和图标颜色。[onSurface] 为 false 时画在封面色上（展开动画里的那一份）。
  static Color foreground(BuildContext context, {bool onSurface = true}) =>
      onSurface && context.tokens.hyperMaterial
      ? Theme.of(context).colorScheme.onSurface
      : Colors.white;

  static Color secondary(BuildContext context, {bool onSurface = true}) =>
      onSurface && context.tokens.hyperMaterial
      ? Theme.of(context).colorScheme.onSurfaceVariant
      : Colors.white70;
}

/// 外边距与宽度。
class MiniPlayerBounds extends StatelessWidget {
  final Widget child;

  const MiniPlayerBounds({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!context.tokens.hyperMaterial) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: child,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
      child: Align(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: MiniPlayerStyle._hyperMaxWidth,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 胶囊表面。
class MiniPlayerSurface extends StatelessWidget {
  final Color background;
  final ShapeBorder shape;
  final Widget child;

  const MiniPlayerSurface({
    super.key,
    required this.background,
    required this.shape,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    if (tokens.hyperMaterial) {
      return HyperBlendSurface(
        material: HyperBlendSurface.bar(context),
        borderRadius: tokens.squareCorners
            ? tokens.radius(16)
            : BorderRadius.circular(28),
        bloom: HyperBlendSurface.barBloom(context),
        shadow: true,
        child: child,
      );
    }
    return AnimatedContainer(
      duration: context.motion(const Duration(milliseconds: 400)),
      curve: PlayerExpansionMotion.curve,
      decoration: ShapeDecoration(
        color: background,
        shape: shape,
        shadows: [
          BoxShadow(
            color: Colors.black.withAlpha(90),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 左右滑动切歌。MD3E：只看松手速度。柔光玻璃：内容跟手移动，过半或甩动才切歌，否则弹回。
class MiniPlayerSwipe extends StatefulWidget {
  final ValueChanged<bool> onSwipe; // true = 下一首
  final Widget child;

  const MiniPlayerSwipe({super.key, required this.onSwipe, required this.child});

  @override
  State<MiniPlayerSwipe> createState() => _MiniPlayerSwipeState();
}

class _MiniPlayerSwipeState extends State<MiniPlayerSwipe>
    with SingleTickerProviderStateMixin {
  static const double _reach = 72; // 内容最多跟手这么远
  static const double _trigger = 48;

  late final AnimationController _offset;

  @override
  void initState() {
    super.initState();
    _offset = AnimationController.unbounded(vsync: this);
  }

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  void _end(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    final next = _offset.value < -_trigger || v < -300;
    final previous = _offset.value > _trigger || v > 300;
    if (next || previous) widget.onSwipe(next);
    _offset.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!context.tokens.hyperMaterial) {
      return GestureDetector(
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v.abs() < 300) return;
          widget.onSwipe(v < 0);
        },
        child: widget.child,
      );
    }
    return GestureDetector(
      onHorizontalDragUpdate: (d) => _offset.value =
          (_offset.value + d.delta.dx).clamp(-_reach, _reach),
      onHorizontalDragEnd: _end,
      child: AnimatedBuilder(
        animation: _offset,
        child: widget.child,
        builder: (context, child) => Opacity(
          opacity: 1 - (_offset.value.abs() / _reach) * 0.4,
          child: Transform.translate(
            offset: Offset(_offset.value, 0),
            child: child,
          ),
        ),
      ),
    );
  }
}
