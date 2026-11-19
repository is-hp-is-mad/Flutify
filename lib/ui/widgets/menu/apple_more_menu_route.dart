import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/physics.dart';

import '../../../core/theme/flutify_tokens.dart';

/// 「⋯」更多菜单：Apple Music 上下文菜单式的「源按钮 → 玻璃团块 → 菜单」形变
/// （分析与依据见 docs/apple-music-player-and-more-motion-analysis-and-plan.md §4、§7.5–7.7）。
///
/// 展开（[O] 实测阶段）：
/// 1. ⋯ 按钮处先出现近圆形玻璃团块，按钮本身隐去；
/// 2. 团块先横向、再纵向地连续拉成菜单，圆角与裁切同步变化；
/// 3. 菜单内容按最终排版提前布局，早期带模糊、缩放与不完整裁切，随后才清晰可点。
///
/// 收回不是展开的倒放：内容先退场 → 外壳缩回源点 → 最后才恢复 ⋯ 按钮。
/// 收回从当前视觉状态出发（展开途中关闭也不跳）。
///
/// 层级菜单（[submenus]）在同一个外壳里切换，不收回再重新弹出（参考 Sort By）。
///
/// 时长与曲线为 **[E] 工程拟合**：展开主形变约 380 ms、尾部约 460 ms。
/// 收回按录像的 150 ms 做太急（手机上看着「傻快」），拉长到约 380 ms，
/// 内容、高度、宽度依次错开收拢。不是 AnimationKit 的私有 spring 原值。
///
/// 菜单内容按 [AppleMoreMenu.contentScale] 缩小绘制（参照 iOS 上下文菜单的
/// 行高、字号、图标比例），外框宽度不变。
class AppleMoreMenu {
  AppleMoreMenu._();

  /// 菜单内容的绘制比例：菜单项按原尺寸排版，再整体缩小到这个比例。
  /// 参考 iOS 截图（菜单宽约 250pt、行距约 43pt、图标约 19pt），原来的 50dp 行高、
  /// 24dp 图标、16sp 字偏大；乘 0.88 后是 44 / 21 / 14。外框宽度不变。[E]
  static const double contentScale = 0.88;

  /// 从 [context] 所在组件（⋯ 按钮）弹出；返回选中项的值。
  ///
  /// [submenus] 里的值被点按时不关闭菜单，而是在原位切换到它的二级菜单。
  static Future<T?> show<T>(
    BuildContext context,
    List<PopupMenuEntry<T>> items, {
    Map<T, AppleSubmenu<T>> submenus = const {},
    double width = 250,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
    final box = context.findRenderObject();
    final Rect anchor;
    if (box is RenderBox && box.hasSize && box.attached) {
      anchor = MatrixUtils.transformRect(
        box.getTransformTo(overlay),
        Offset.zero & box.size,
      );
    } else {
      anchor = Rect.fromCenter(
        center: overlay.size.topRight(const Offset(-32, 64)),
        width: 40,
        height: 40,
      );
    }
    return navigator.push(
      AppleMoreMenuRoute<T>(
        anchor: anchor,
        items: items,
        submenus: submenus,
        width: width,
        sourceOpacity: context
            .findAncestorStateOfType<_AppleMoreMenuSourceState>()
            ?._opacity,
        reduceMotion: context.reduceMotion,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
      ),
    );
  }
}

/// 二级菜单：标题 + 懒加载的菜单项。
class AppleSubmenu<T> {
  const AppleSubmenu({required this.title, required this.items});

  final String title;
  final List<PopupMenuEntry<T>> Function() items;
}

/// 包住 ⋯ 按钮：菜单展开时把按钮本身藏起来（它变成了团块），收回最后再显示。
class AppleMoreMenuSource extends StatefulWidget {
  const AppleMoreMenuSource({super.key, required this.child});

  final Widget child;

  @override
  State<AppleMoreMenuSource> createState() => _AppleMoreMenuSourceState();
}

class _AppleMoreMenuSourceState extends State<AppleMoreMenuSource> {
  /// 不随 State 销毁：菜单路由可能比按钮活得久（例如点了「删除」后页面先退出），
  /// 之后再写入它也无害。
  final ValueNotifier<double> _opacity = ValueNotifier(1);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: _opacity,
    child: widget.child,
    builder: (context, opacity, child) =>
        Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
  );
}

class AppleMoreMenuRoute<T> extends PopupRoute<T> {
  AppleMoreMenuRoute({
    required this.anchor,
    required this.items,
    required this.capturedThemes,
    this.submenus = const {},
    this.width = 250,
    this.reduceMotion = false,
    this.sourceOpacity,
  });

  /// 源按钮在 Overlay 坐标系中的矩形。
  final Rect anchor;
  final List<PopupMenuEntry<T>> items;
  final Map<T, AppleSubmenu<T>> submenus;
  final CapturedThemes capturedThemes;
  final double width;
  final bool reduceMotion;

  /// 源按钮的不透明度（[AppleMoreMenuSource] 提供）；没有包装时为 null。
  final ValueNotifier<double>? sourceOpacity;

  _AppleMoreMenuState<T>? _menu;

  /// 展开：主形变 ~380 ms，内容尾部稳定到 ~460 ms。[M]→[E]
  @override
  Duration get transitionDuration =>
      reduceMotion ? const Duration(milliseconds: 150) : _openDuration;

  /// 收回：内容先退、外壳归拢、⋯ 恢复，共 ~380 ms。[E]
  @override
  Duration get reverseTransitionDuration =>
      reduceMotion ? const Duration(milliseconds: 150) : _closeDuration;

  static const _openDuration = Duration(milliseconds: 460);
  static const _closeDuration = Duration(milliseconds: 380);

  @override
  Color? get barrierColor => const Color(0x14000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  void install() {
    super.install();
    animation!.addListener(_syncSource);
  }

  void _syncSource() {
    final source = sourceOpacity;
    if (source == null) return;
    final menu = _menu;
    source.value = menu == null || !menu.mounted
        ? 0
        : menu._lookFor(animation!).source;
  }

  @override
  bool didPop(T? result) {
    // 点到二级菜单入口：原地切换层级，不关闭菜单。
    final menu = _menu;
    if (result != null &&
        submenus.containsKey(result) &&
        menu != null &&
        menu.mounted &&
        menu._level == null &&
        animation!.status != AnimationStatus.reverse) {
      menu._enter(result);
      return false;
    }
    return super.didPop(result);
  }

  @override
  void dispose() {
    animation?.removeListener(_syncSource);
    sourceOpacity?.value = 1;
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => capturedThemes.wrap(_AppleMoreMenu<T>(route: this));
}

/// 每一帧各通道的值。`w`/`h`：外壳横向/纵向从团块(0)到菜单(1)的进度。
class _Look {
  const _Look({
    required this.w,
    required this.h,
    required this.blob,
    required this.content,
    required this.blur,
    required this.scale,
    required this.source,
  });

  final double w, h, blob, content, blur, scale, source;

  static const closed = _Look(
    w: 0,
    h: 0,
    blob: 0,
    content: 0,
    blur: 1,
    scale: 0.9,
    source: 1,
  );

  static double _in(double v, double a, double b, [Curve c = Curves.linear]) =>
      c.transform(((v - a) / (b - a)).clamp(0.0, 1.0));

  /// 展开：先横向拉开（快），再向下展开（稍慢）；内容在形变后段才清晰。
  static _Look open(double v) {
    final blob = _in(v, 0, 0.12, Curves.easeOut);
    return _Look(
      w: _in(v, 0, 0.72, const Cubic(0.25, 0.9, 0.3, 1)),
      h: _in(v, 0.06, 0.86, Curves.easeOutCubic),
      blob: blob,
      content: _in(v, 0.26, 0.72, Curves.easeOut),
      blur: 1 - _in(v, 0.22, 0.86, Curves.easeOut),
      scale: lerpDouble(0.9, 1, _in(v, 0.15, 0.9, Curves.easeOutCubic))!,
      source: 1 - blob,
    );
  }

  /// 收回：[t]∈[0,1] 是从开始收回算起的进度；从 [from] 出发。
  ///
  /// 内容先淡出并轻微模糊，外壳先收高度、再收宽度，最后团块淡出、⋯ 恢复。
  /// 各通道用缓入缓出并互相重叠，避免一下子缩没。
  static _Look close(_Look from, double t) {
    double to(double a, double b, double start, double end, [Curve? c]) =>
        lerpDouble(a, b, _in(t, start, end, c ?? Curves.easeInOut))!;
    const shrink = Cubic(0.45, 0, 0.25, 1);
    return _Look(
      content: to(from.content, 0, 0, 0.42, Curves.easeInOut),
      blur: to(from.blur, 0.7, 0, 0.5),
      scale: to(from.scale, 0.9, 0, 0.85, Curves.easeInOutCubic),
      h: to(from.h, 0, 0.06, 0.82, shrink),
      w: to(from.w, 0, 0.16, 0.92, shrink),
      blob: to(from.blob, 0, 0.74, 1),
      source: to(from.source, 1, 0.78, 1),
    );
  }
}

class _AppleMoreMenu<T> extends StatefulWidget {
  const _AppleMoreMenu({super.key, required this.route});

  final AppleMoreMenuRoute<T> route;

  @override
  State<_AppleMoreMenu<T>> createState() => _AppleMoreMenuState<T>();
}

class _AppleMoreMenuState<T> extends State<_AppleMoreMenu<T>>
    with SingleTickerProviderStateMixin {
  static const double _inset = 12;
  static const double _vPad = 6;
  static const double _radius = 20;
  static const double _scale = AppleMoreMenu.contentScale;

  /// 层级切换（0 = 主菜单，1 = 二级菜单）。
  late final AnimationController _levelT = AnimationController.unbounded(
    vsync: this,
  );

  T? _level;
  List<PopupMenuEntry<T>>? _childItems;

  /// 实测内容高度：主菜单 / 二级菜单。
  double? _mainHeight;
  double? _childHeight;

  /// 开始收回时的状态（展开途中关闭不跳）。
  _Look? _closingFrom;
  double _closingAt = 1;

  _Look _look = _Look.closed;

  @override
  void initState() {
    super.initState();
    widget.route._menu = this;
    widget.route.animation!.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse && _closingFrom == null) {
      _closingFrom = _look;
      _closingAt = math.max(widget.route.animation!.value, 0.001);
    }
  }

  @override
  void dispose() {
    widget.route.animation?.removeStatusListener(_onStatus);
    if (widget.route._menu == this) widget.route._menu = null;
    _levelT.dispose();
    super.dispose();
  }

  void _enter(T key) {
    setState(() {
      _level = key;
      _childItems = widget.route.submenus[key]!.items();
      _childHeight = null;
    });
    _animateLevel(1);
  }

  void _back() => _animateLevel(0).then((_) {
    if (mounted && _levelT.value <= 0.001) {
      setState(() {
        _level = null;
        _childItems = null;
      });
    }
  });

  TickerFuture _animateLevel(double to) {
    if (widget.route.reduceMotion) {
      _levelT.value = to;
      return TickerFuture.complete();
    }
    return _levelT.animateWith(
      SpringSimulation(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: math.pow(2 * math.pi / 0.36, 2).toDouble(),
          ratio: 1,
        ),
        _levelT.value,
        to,
        _levelT.velocity,
        snapToEnd: true,
        tolerance: const Tolerance(distance: 0.002, velocity: 0.05),
      ),
    );
  }

  _Look _lookFor(Animation<double> animation) {
    final v = animation.value;
    if (widget.route.reduceMotion) {
      return _Look(
        w: 1,
        h: 1,
        blob: v,
        content: v,
        blur: 0,
        scale: 1,
        source: v >= 1 ? 0 : 1 - v,
      );
    }
    final from = _closingFrom;
    if (from != null) return _Look.close(from, 1 - v / _closingAt);
    return _Look.open(v);
  }

  /// 菜单最终位置：贴着 ⋯ 按钮的一角向屏幕内侧展开，放不下时翻向另一侧。
  Rect _place(Size screen, EdgeInsets safe, double height) {
    final anchor = widget.route.anchor;
    final width = math.min(widget.route.width, screen.width - _inset * 2);
    final maxHeight = math.max(
      48.0,
      screen.height - safe.top - safe.bottom - _inset * 2,
    );
    final h = math.min(height, maxHeight);
    final growLeft = anchor.center.dx > screen.width / 2;
    final left = growLeft ? anchor.right + 4 - width : anchor.left - 4;
    final minTop = safe.top + _inset;
    final maxBottom = screen.height - safe.bottom - _inset;
    final growDown = anchor.center.dy < screen.height / 2;
    var top = growDown ? anchor.top - 4 : anchor.bottom + 4 - h;
    top = top.clamp(minTop, math.max(minTop, maxBottom - h));
    return Rect.fromLTWH(
      left.clamp(_inset, math.max(_inset, screen.width - _inset - width)),
      top,
      width,
      h,
    );
  }

  /// 菜单排版高度（未缩小）。
  double _estimate(List<PopupMenuEntry<T>> items) =>
      items.fold<double>(_vPad * 2, (sum, item) => sum + item.height);

  /// [contentHeight] 是排版高度；外壳按缩小后的高度定位。
  void _report(bool child, double contentHeight) {
    final total = (contentHeight + _vPad * 2) * _scale;
    final current = child ? _childHeight : _mainHeight;
    if (current != null && (current - total).abs() < 0.5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => child ? _childHeight = total : _mainHeight = total);
    });
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: Listenable.merge([route.animation!, _levelT]),
        builder: (context, _) {
          final screen = box.biggest;
          final look = _look = _lookFor(route.animation!);
          final main = _place(
            screen,
            media.padding,
            _mainHeight ?? _estimate(route.items) * _scale,
          );
          final childItems = _childItems;
          final level = _levelT.value.clamp(0.0, 1.0);
          final child = childItems == null
              ? null
              : _place(
                  screen,
                  media.padding,
                  _childHeight ??
                      (_estimate(childItems) + _headerHeight) * _scale,
                );
          final menu = child == null ? main : Rect.lerp(main, child, level)!;
          return _frame(context, look, menu, main, child, level);
        },
      ),
    );
  }

  static const double _headerHeight = 50;

  Widget _frame(
    BuildContext context,
    _Look look,
    Rect menu,
    Rect mainRect,
    Rect? childRect,
    double level,
  ) {
    final anchor = widget.route.anchor;
    final d = anchor.shortestSide.clamp(28.0, 44.0);
    final blob = Rect.fromCenter(center: anchor.center, width: d, height: d);
    final shell = Rect.fromLTRB(
      lerpDouble(blob.left, menu.left, look.w)!,
      lerpDouble(blob.top, menu.top, look.h)!,
      lerpDouble(blob.right, menu.right, look.w)!,
      lerpDouble(blob.bottom, menu.bottom, look.h)!,
    );
    final radius = math.min(
      lerpDouble(d / 2, _radius, math.min(look.w, look.h))!,
      shell.shortestSide / 2,
    );
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark ? const Color(0xC72C2C2E) : const Color(0xCCF7F7F8);
    // 内容从靠近 ⋯ 的那一角长出来
    final alignment = Alignment(
      anchor.center.dx >= menu.center.dx ? 1 : -1,
      anchor.center.dy >= menu.center.dy ? 1 : -1,
    );
    final interactive =
        widget.route.animation!.status == AnimationStatus.completed ||
        (_closingFrom == null && look.content > 0.9);

    Widget layer(Rect rect, Widget content, double opacity, double dx) {
      final sigma = look.blur * 8 + (1 - opacity) * 4;
      // 按 1/_scale 的尺寸排版，再缩小绘制：行高、图标、文字同比例变小
      final sized = OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: rect.width / _scale,
        maxWidth: rect.width / _scale,
        minHeight: rect.height / _scale,
        maxHeight: rect.height / _scale,
        child: Transform.scale(
          alignment: Alignment.topLeft,
          scale: _scale,
          child: content,
        ),
      );
      Widget child = Transform.scale(
        alignment: alignment,
        scale: look.scale,
        child: sized,
      );
      if (sigma > 0.3 && !widget.route.reduceMotion) {
        child = ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: child,
        );
      }
      return Positioned(
        left: rect.left - shell.left + dx,
        top: rect.top - shell.top,
        width: rect.width,
        height: rect.height,
        child: Opacity(
          // 不可见时也留在树里：要靠它量出菜单项的真实高度
          opacity: (look.content * opacity).clamp(0.0, 1.0),
          child: child,
        ),
      );
    }

    final layers = <Widget>[
      layer(
        mainRect,
        _content(context, widget.route.items, false, header: null),
        1 - level,
        -24 * level,
      ),
      if (childRect != null && _childItems != null)
        layer(
          childRect,
          _content(
            context,
            _childItems!,
            true,
            header: widget.route.submenus[_level]?.title,
          ),
          level,
          24 * (1 - level),
        ),
    ];

    Widget surface = ClipRRect(
      key: const ValueKey('apple-more-menu-shell'),
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: ColoredBox(
          color: fill,
          child: IgnorePointer(
            ignoring: !interactive,
            child: Stack(clipBehavior: Clip.hardEdge, children: layers),
          ),
        ),
      ),
    );
    if (look.blob < 1) {
      surface = Opacity(opacity: look.blob.clamp(0.0, 1.0), child: surface);
    }
    final shadow = (math.min(look.w, look.h) * look.blob).clamp(0.0, 1.0);
    return Stack(
      children: [
        Positioned.fromRect(
          rect: shell,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                if (shadow > 0)
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: (dark ? 0.35 : 0.16) * shadow,
                    ),
                    blurRadius: 40,
                    offset: const Offset(0, 12),
                  ),
              ],
            ),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerTheme: DividerThemeData(
                  color: scheme.onSurface.withValues(alpha: 0.12),
                ),
              ),
              child: surface,
            ),
          ),
        ),
      ],
    );
  }

  Widget _content(
    BuildContext context,
    List<PopupMenuEntry<T>> items,
    bool child, {
    required String? header,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        role: SemanticsRole.menu,
        label: MaterialLocalizations.of(context).popupMenuLabel,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: _vPad),
          child: _SizeReporter(
            onHeight: (h) => _report(child, h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (header != null) ...[
                  InkWell(
                    key: const ValueKey('apple-more-menu-back'),
                    onTap: _back,
                    child: SizedBox(
                      height: _headerHeight - 13,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Icon(
                              Icons.chevron_left_rounded,
                              size: 24,
                              color: scheme.onSurface,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                header,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 13, indent: 20, endIndent: 20),
                ],
                ...items,
              ],
            ),
          ),
        ),
      ),
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
