import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../hyper_surface.dart';

/// 柔光玻璃模式下的弹出菜单路由：澎湃 OS 4 的弹窗动画（与 hyper_glass 的 `MorphMenu` 同一套）。
///
/// - 菜单的真实几何从锚点（按钮本身，右键时为指针处的小方块）弹簧变形到最终位置，
///   不是缩放变换，所以混色模糊始终采样它下方的画面；
/// - 几何与透明度各有一组展开 / 收起弹簧（`PopupMotion`），可以略微过冲；
/// - 菜单项从锚点中心迸出、边飞边放大，收起时倒放回锚点；
/// - 锚点与菜单在变形的前 15% 交叉淡入（`menuSwap`）。
///
/// 菜单项仍是 [PopupMenuEntry]：点击时 `Navigator.pop(value)` 照常返回选中值。
class HyperMenuRoute<T> extends PopupRoute<T> {
  HyperMenuRoute({
    required this.anchor,
    required this.items,
    required this.theme,
    required this.capturedThemes,
    this.width = 280,
  });

  /// 锚点在 Overlay 坐标系中的矩形。
  final Rect anchor;
  final List<PopupMenuEntry<T>> items;
  final ThemeData theme;
  final CapturedThemes capturedThemes;
  final double width;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  // 动画由 PopupMotion 的弹簧驱动；路由动画只用来知道何时开始收起，
  // 收起弹簧（几何 0.28s、透明度 0.4s 响应）大约 450ms 后基本落定。
  @override
  Duration get transitionDuration => const Duration(milliseconds: 1);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 450);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return capturedThemes.wrap(
      Theme(
        data: theme,
        child: _HyperMenu<T>(route: this),
      ),
    );
  }
}

class _HyperMenu<T> extends StatefulWidget {
  const _HyperMenu({super.key, required this.route});

  final HyperMenuRoute<T> route;

  @override
  State<_HyperMenu<T>> createState() => _HyperMenuState<T>();
}

class _HyperMenuState<T> extends State<_HyperMenu<T>>
    with TickerProviderStateMixin {
  late final PopupMotion _motion = PopupMotion(this);

  /// 菜单项内容的水平中心（左内边距 16 + 图标 20 + 间距 12 + 约四个汉字），迸出起点对准它。
  static const double _contentX = 72;
  static const double _vPad = 6;

  @override
  void initState() {
    super.initState();
    widget.route.animation!.addStatusListener(_onRouteStatus);
    _motion.set(true);
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse && _motion.open) _motion.set(false);
  }

  @override
  void dispose() {
    widget.route.animation?.removeStatusListener(_onRouteStatus);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final height = route.items.fold<double>(
      _vPad * 2,
      (total, item) => total + item.height,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final screen = box.biggest;
        final anchor = route.anchor;
        final menu = menuRectFor(
          anchor,
          screen,
          math.min(route.width, screen.width - 24),
          math.min(height, screen.height - 24),
          growUp: anchor.center.dy > screen.height * 0.6,
        );
        return AnimatedBuilder(
          animation: _motion.listenable,
          builder: (context, _) => _frame(context, anchor, menu),
        );
      },
    );
  }

  Widget _frame(BuildContext context, Rect anchor, Rect menu) {
    final t = _motion.geometry.value;
    final fade = _motion.fade.value;
    // 真实几何插值（不是缩放），混色模糊始终采样当前覆盖的画面
    final rect = Rect.lerp(anchor, menu, t)!;
    final anchorRadius = math.min(anchor.shortestSide / 2, 24.0);
    final finalRadius = context.tokens.corner(24);
    final radius =
        anchorRadius + (finalRadius - anchorRadius) * t.clamp(0.0, 1.0);
    final q = math.max(0.0, t); // 1 为静止，过冲时略大于 1
    final itemOpacity = ((fade - 0.2) / 0.8).clamp(0.0, 1.0);

    var y = _vPad;
    final children = <Widget>[];
    for (final item in widget.route.items) {
      final h = item.height;
      // 从锚点中心到这一项内容中心的偏移：菜单项从这里飞出
      final fromTap =
          anchor.center - menu.topLeft - Offset(_contentX, y + h / 2);
      children.add(
        Opacity(
          opacity: itemOpacity,
          child: Transform.translate(
            offset: fromTap * (1 - q).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.3 + 0.7 * q,
              alignment: Alignment(_contentX / (menu.width / 2) - 1, 0),
              child: item,
            ),
          ),
        ),
      );
      y += h;
    }

    return Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: Opacity(
            // 前 15% 与锚点交叉淡入；收起落定在 0 附近时完全透明
            opacity: menuSwap(t),
            child: HyperBlendSurface(
              material: HyperBlendSurface.menu(context),
              borderRadius: BorderRadius.circular(radius),
              // 菜单项按最终尺寸排好，由变形中的矩形逐步露出
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: menu.width,
                  maxWidth: menu.width,
                  minHeight: menu.height,
                  maxHeight: menu.height,
                  child: Transform.translate(
                    offset: menu.topLeft - rect.topLeft,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: _vPad),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: children,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
