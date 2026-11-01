import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hyper_glass/hyper_ui.dart' show ArcMotion, menuRectFor;

import '../../../core/theme/flutify_tokens.dart';
import '../hyper_surface.dart';

/// 柔光玻璃模式下的弹出菜单路由：miuix 下拉菜单的 `ArcAnimation`（与 hyper_glass 的 `ArcMenu` 同一套）。
///
/// - 菜单从一条 5:1、宽为最终 69% 的横条展开，横条贴着菜单朝向锚点的一侧；
/// - 尺寸和位置各走一组弹簧，收起时互换（`ArcMotion`）；透明度线性，进 50 ms、出 200 ms；
/// - 内容按宽度等比缩放，不是逐项飞出；真实几何在变，混色模糊始终采样它下方的画面；
/// - 上游收起时内容还会模糊到 30dp，这里不做：Skia 每种模糊强度都要现编译程序，
///   动画里连续变化的 sigma 会让第一次关菜单卡顿。
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

  // 动画由 ArcMotion 驱动；路由动画只用来知道何时开始收起，
  // 收起弹簧（位置 0.35s 响应）与淡出（200 ms）在 320 ms 内基本落定。
  @override
  Duration get transitionDuration => const Duration(milliseconds: 1);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

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
  late final ArcMotion _motion = ArcMotion(this);

  /// 菜单项实际排版后的总高度：[PopupMenuEntry.height] 只是声明值，桌面上
  /// 菜单项实际更高，按声明值算会让菜单底部被截掉。
  double? _measured;

  /// miuix_appcompat_drop_down_menu_padding_small
  static const double _vPad = 11;
  static const double _inset = 12;

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

  /// PopupWindowStrategy.getYInWindowAlignTop：默认从锚点顶部向下展开；放不下时
  /// 下方空间更大就贴底，否则整个放到锚点上方。
  static Rect _place(Rect anchor, Size screen, double width, double height) {
    final x = menuRectFor(anchor, screen, width, height, growUp: false).left;
    final top = math.max(anchor.top, _inset);
    final double y;
    if (top + height < screen.height - _inset) {
      y = top;
    } else if (screen.height - anchor.top >= anchor.top) {
      y = screen.height - _inset - height;
    } else {
      y = anchor.top - height;
    }
    final maxY = math.max(_inset, screen.height - _inset - height);
    return Rect.fromLTWH(x, y.clamp(_inset, maxY), width, height);
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final height =
        _measured ??
        route.items.fold<double>(
          _vPad * 2,
          (total, item) => total + item.height,
        );
    return LayoutBuilder(
      builder: (context, box) {
        final screen = box.biggest;
        final anchor = route.anchor;
        final menu = _place(
          anchor,
          screen,
          math.min(route.width, screen.width - _inset * 2),
          math.min(height, screen.height - _inset * 2),
        );
        return AnimatedBuilder(
          animation: _motion.listenable,
          builder: (context, _) => _frame(context, anchor, menu),
        );
      },
    );
  }

  void _onContentHeight(double h) {
    final total = h + _vPad * 2;
    if (_measured != null && (total - _measured!).abs() < 0.5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _measured = total);
    });
  }

  Widget _frame(BuildContext context, Rect anchor, Rect menu) {
    final frame = _motion.frame(
      anchor,
      menu,
      endRadius: context.tokens.corner(24),
    );
    return Stack(
      children: [
        Positioned.fromRect(
          rect: frame.rect,
          child: Opacity(
            // 不可见时也留在树里：要靠它量出菜单项的真实高度
            opacity: frame.visible ? _motion.alpha.value : 0,
            child: HyperBlendSurface(
              material: HyperBlendSurface.menu(context),
              borderRadius: BorderRadius.circular(frame.radius),
              bloom: HyperBlendSurface.menuBloom(context),
              shadow: true,
              // 菜单项按最终尺寸排好，随宽度等比缩放
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: menu.width,
                maxWidth: menu.width,
                minHeight: menu.height,
                maxHeight: menu.height,
                child: Transform.scale(
                  alignment: Alignment.topLeft,
                  scale: frame.scale,
                  child: Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: _vPad),
                      // 与 showMenu 相同的语义：PopupMenuItem 要求父节点是 menu
                      child: Semantics(
                        scopesRoute: true,
                        namesRoute: true,
                        explicitChildNodes: true,
                        role: SemanticsRole.menu,
                        label: MaterialLocalizations.of(
                          context,
                        ).popupMenuLabel,
                        child: SingleChildScrollView(
                          child: _SizeReporter(
                            onHeight: _onContentHeight,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: widget.route.items,
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
        ),
      ],
    );
  }
}

/// 布局后报告子组件高度（用于按实际高度定位菜单）。
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter ro) =>
      ro.onHeight = onHeight;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onHeight);

  ValueChanged<double> onHeight;

  @override
  void performLayout() {
    super.performLayout();
    onHeight(size.height);
  }
}
