import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/flutify_tokens.dart';
import '../screens/player/player_expansion.dart';
import 'hyper_surface.dart';

/// 迷你播放器的外框（本机与远程共用）。
///
/// MD3E：横向铺满、封面取色的胶囊。柔光玻璃：与底栏等宽、等高的浮动控件材质，下方内容透过模糊可见。
abstract final class MiniPlayerStyle {
  /// 与底栏（miuix BottomNavigator）相同：自适应宽度（小屏横向填满留 20dp 边距，大屏最大 480）。
  static const double _hyperMaxWidth = 480;

  static double artworkSize(BuildContext context) =>
      context.tokens.hyperMaterial ? 36 : 44;

  static EdgeInsets rowPadding(BuildContext context) =>
      context.tokens.hyperMaterial
      ? const EdgeInsets.fromLTRB(8, 5, 6, 5)
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
    // Android 悬浮栏自己定位和定宽
    if (MiniPlayerDock.maybeOf(context) != null) return child;
    if (!context.tokens.hyperMaterial) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: child,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 自适应宽度：与底部 Tab 栏完全一致（小屏两侧留 20dp，大屏等比例最大 480）
        final avail = math.max(0.0, constraints.maxWidth - 40);
        final barW = avail.clamp(280.0, MiniPlayerStyle._hyperMaxWidth);
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
          child: Center(
            child: SizedBox(
              width: barW,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Android 悬浮栏里的迷你播放器：外框由悬浮栏定位（不加 [MiniPlayerBounds] 的边距），
/// [fold] 是下沉进度（0 在导航上方，1 收在两枚圆钮之间）。
class MiniPlayerDock extends InheritedWidget {
  final Animation<double> fold;

  const MiniPlayerDock({super.key, required this.fold, required super.child});

  /// 不登记依赖：只读一次动画对象，进度由 [MiniPlayerFoldAway] 自己监听。
  static Animation<double>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MiniPlayerDock>()?.fold;

  @override
  bool updateShouldNotify(MiniPlayerDock oldWidget) => fold != oldWidget.fold;
}

/// 播放器下沉时先淡出的部分（心形、进度线）。[fold] 为 null 时原样显示。
class MiniPlayerFoldAway extends StatelessWidget {
  final Animation<double>? fold;

  /// 同时让出宽度（行内的按钮）。
  final bool collapse;
  final Widget child;

  const MiniPlayerFoldAway({
    super.key,
    required this.fold,
    this.collapse = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final fold = this.fold;
    if (fold == null) return child;
    return AnimatedBuilder(
      animation: fold,
      child: child,
      builder: (context, child) {
        final shown = (1 - fold.value.clamp(0.0, 1.0) * 2).clamp(0.0, 1.0);
        if (shown == 0) return const SizedBox.shrink();
        final faded = Opacity(opacity: shown, child: child);
        if (!collapse) return faded;
        return ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: shown,
            child: faded,
          ),
        );
      },
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
            : BorderRadius.circular(24),
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

  const MiniPlayerSwipe({
    super.key,
    required this.onSwipe,
    required this.child,
  });

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
      onHorizontalDragUpdate: (d) =>
          _offset.value = (_offset.value + d.delta.dx).clamp(-_reach, _reach),
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
