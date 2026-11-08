import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Hy, HyperTheme, SpringValue;
import 'package:provider/provider.dart';

import '../../../core/perf_flags.dart';
import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../providers/playback_provider.dart';
import '../../widgets/connect/connect_actions.dart';
import '../../widgets/hyper_surface.dart';
import '../../widgets/mini_player.dart';
import '../../widgets/mini_player_frame.dart';

/// 页面纵向滚动驱动的收起状态：往下读收起底栏，回到顶部才展开，往回滚保持收起。
class FloatingBarFold extends ValueNotifier<bool> {
  FloatingBarFold() : super(false);

  /// 往下累计滚过这么远才收起，手指轻微抖动不会收起。
  static const double _threshold = 24;
  double _travel = 0;

  /// 手动展开后，正在进行的这次滚动（多半是惯性）不再把栏收回去，下一次滚动开始才恢复。
  bool _held = false;

  /// 点按圆钮或换 Tab 时展开。
  void expand() {
    _travel = 0;
    _held = true;
    value = false;
  }

  /// 给 `NotificationListener<ScrollNotification>` 用，不拦截通知。
  bool handle(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    if (notification is ScrollStartNotification) {
      _travel = 0;
      _held = false;
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    if (metrics.pixels <= metrics.minScrollExtent) {
      _travel = 0;
      value = false;
      return false;
    }
    final delta = notification.scrollDelta ?? 0;
    if (_held || metrics.outOfRange) return false;
    if (delta <= 0) {
      _travel = 0;
      return false;
    }
    _travel += delta;
    if (_travel > _threshold) value = true;
    return false;
  }
}

/// Android 柔光玻璃的底部悬浮栏：迷你播放器胶囊 + 三项导航药丸（iOS 26 Apple Music 的布局与动效）。
///
/// - 展开：左右各留 16，播放器（高 56）在导航（高 64）上方，间隔 8；
/// - 往下滚动收起：导航药丸向左缩成当前 Tab 的圆形按钮，右端分裂出搜索圆钮，其余项淡出；
///   播放器下沉到两枚圆钮之间并变窄，心形与进度线收起；回到顶部或点按圆钮沿原路展开。全部由弹簧驱动；
/// - 选中胶囊的两条边各走一根弹簧，移动时拉长、落位回弹；移动或拖动时胶囊浮起、放大下方内容并亮起边缘。
///
/// 材质、图标与配色和 [HyperBottomBar] 相同。报给 Scaffold 的高度固定为展开时的高度，
/// 收放不会改变页面的底部留白。
class AndroidFloatingBar extends StatefulWidget {
  const AndroidFloatingBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.fold,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 由页面滚动驱动的收起状态；为 null 时只能保持展开。
  final FloatingBarFold? fold;

  static const int searchIndex = 1;

  static bool get platformSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool enabled(BuildContext context) =>
      platformSupported && context.tokens.hyperMaterial;

  @override
  State<AndroidFloatingBar> createState() => _AndroidFloatingBarState();
}

class _AndroidFloatingBarState extends State<AndroidFloatingBar>
    with TickerProviderStateMixin {
  static const double _margin = 16;
  static const double _gap = 8;
  static const double _bottomGap = 12;
  static const double _playerHeight = 56;
  static const double _navHeight = 64;
  static const double _dock = 56; // 收起后两枚圆钮的直径，与播放器同高
  static const double _inset = 3; // 选中胶囊离药丸边缘
  static const double _iconSize = 26;
  static const double _labelHeight = Hy.footnote * 1.2;

  // 收起进度：导航（缩小、分裂）与播放器（下沉）各一根弹簧，播放器慢半拍
  late final _fold = SpringValue(
    this,
    value: _foldTarget,
    damping: 0.86,
    response: 0.42,
  );
  late final _sink = SpringValue(
    this,
    value: _foldTarget,
    damping: 0.82,
    response: 0.5,
  );

  // 选中胶囊的左右边（单位：项）。前沿快、后沿慢，移动时拉长；阻尼低于 1，落位时回弹
  late final _left = SpringValue(this, value: widget.selectedIndex.toDouble());
  late final _right = SpringValue(this, value: widget.selectedIndex + 1.0);

  /// 拖动时胶囊浮起。
  late final _lift = SpringValue(this, damping: 0.6, response: 0.3);

  /// 收起后左侧圆钮显示的 Tab：当前 Tab；在搜索页时是上一个非搜索 Tab。
  late int _anchor = widget.selectedIndex == AndroidFloatingBar.searchIndex
      ? 0
      : widget.selectedIndex;

  /// 胶囊跟手时的位置（单位：项），没在拖动时为 null。
  double? _drag;

  double get _foldTarget => (widget.fold?.value ?? false) ? 1 : 0;

  @override
  void initState() {
    super.initState();
    widget.fold?.addListener(_onFold);
  }

  @override
  void didUpdateWidget(AndroidFloatingBar old) {
    super.didUpdateWidget(old);
    if (old.fold != widget.fold) {
      old.fold?.removeListener(_onFold);
      widget.fold?.addListener(_onFold);
      _onFold();
    }
    if (old.selectedIndex != widget.selectedIndex) {
      final i = widget.selectedIndex;
      if (i != AndroidFloatingBar.searchIndex) _anchor = i;
      _settle(i, forward: i > old.selectedIndex);
      // 换了 Tab 就展开（收起时只能经搜索圆钮换 Tab）
      widget.fold?.expand();
    }
  }

  @override
  void dispose() {
    widget.fold?.removeListener(_onFold);
    _fold.dispose();
    _sink.dispose();
    _left.dispose();
    _right.dispose();
    _lift.dispose();
    super.dispose();
  }

  void _onFold() {
    final to = _foldTarget;
    if (context.reduceMotion) {
      _fold.c.value = to;
      _sink.c.value = to;
      return;
    }
    _fold.to(to);
    _sink.to(to, response: to == 1 ? 0.5 : 0.42);
  }

  void _settle(int i, {required bool forward}) {
    if (context.reduceMotion) {
      _left.c.value = i.toDouble();
      _right.c.value = i + 1.0;
      return;
    }
    _left.to(
      i.toDouble(),
      damping: forward ? 0.7 : 0.62,
      response: forward ? 0.45 : 0.32,
    );
    _right.to(
      i + 1.0,
      damping: forward ? 0.62 : 0.7,
      response: forward ? 0.32 : 0.45,
    );
  }

  void _expand() => widget.fold?.expand();

  void _dragStart() {
    if (!context.reduceMotion) _lift.to(1);
  }

  void _dragUpdate(DragUpdateDetails d, double item) {
    final to = ((_drag ?? widget.selectedIndex.toDouble()) + d.delta.dx / item)
        .clamp(0.0, 2.0);
    _left.c.value = to;
    _right.c.value = to + 1;
    setState(() => _drag = to);
  }

  void _dragEnd() {
    final to = _drag?.round();
    final from = _drag ?? widget.selectedIndex.toDouble();
    setState(() => _drag = null);
    _lift.to(0);
    if (to == null) return;
    if (to != widget.selectedIndex) {
      widget.onSelected(to);
    } else {
      _settle(to, forward: from < to);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = [
      (l10n.navHome, Icons.home_outlined, Icons.home_filled),
      (l10n.navSearch, Icons.search_rounded, Icons.search_rounded),
      (
        l10n.navLibrary,
        Icons.library_music_outlined,
        Icons.library_music_rounded,
      ),
    ];
    final hasTrack = context.select<PlaybackProvider, bool>(
      (p) => p.currentTrack != null,
    );
    final hasPlayer = ConnectActions.showRemote(context) || hasTrack;
    final bottom = MediaQuery.paddingOf(context).bottom + _bottomGap;
    final height = bottom + _navHeight + (hasPlayer ? _gap + _playerHeight : 0);
    final player = MiniPlayerDock(fold: _sink.c, child: const MiniPlayer());

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: Listenable.merge([
            _fold.c,
            _sink.c,
            _left.c,
            _right.c,
            _lift.c,
          ]),
          child: player,
          builder: (context, player) => _layout(
            context,
            items: items,
            width: constraints.maxWidth,
            height: height,
            bottom: bottom,
            player: hasPlayer ? player : null,
          ),
        ),
      ),
    );
  }

  Widget _layout(
    BuildContext context, {
    required List<(String, IconData, IconData)> items,
    required double width,
    required double height,
    required double bottom,
    required Widget? player,
  }) {
    final dark = HyperTheme.isDark(context);
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final ink = Hy.text(dark);
    final capsuleColor = dark
        ? const Color(0x1fffffff)
        : const Color(0x0f000000);
    final index = widget.selectedIndex;
    final selected = _drag?.round() ?? index;

    // 弹簧可能略微冲过头：位置跟着冲，透明度和开关按 [0, 1] 算
    final t = _fold.value.clamp(-0.1, 1.1);
    final s = _sink.value.clamp(-0.1, 1.1);
    // 弹簧停在目标的容差内：贴近 0 时当作完全展开，不再多叠一块搜索圆钮
    final folded = t < 0.01 ? 0.0 : t.clamp(0.0, 1.0);
    final open = folded < 0.5;

    final navBottom = height - bottom;
    final full = Rect.fromLTRB(
      _margin,
      navBottom - _navHeight,
      width - _margin,
      navBottom,
    );
    final leftDock = Rect.fromLTWH(_margin, navBottom - _dock, _dock, _dock);
    final rightDock = Rect.fromLTWH(
      width - _margin - _dock,
      navBottom - _dock,
      _dock,
      _dock,
    );
    final pill = Rect.lerp(full, leftDock, t)!;
    // 搜索圆钮从药丸右端分裂出去
    final search = Rect.lerp(
      Rect.fromLTWH(full.right - _navHeight, full.top, _navHeight, _navHeight),
      rightDock,
      t,
    )!;
    final searchAlpha = (folded / 0.3).clamp(0.0, 1.0);

    final item = (full.width - 2 * _inset) / items.length;
    double slotCenter(int i) => full.left + _inset + item * (i + 0.5);
    final iconOpen = full.top + (_navHeight - _iconSize - _labelHeight) / 2;
    final iconTop = _lerp(iconOpen, leftDock.center.dy - _iconSize / 2, t);

    // 选中胶囊：拉长时变扁、挤短时变高（果冻感），浮起时略放大
    final edgeLeft = full.left + _inset + _left.value * item;
    final edgeRight = full.left + _inset + _right.value * item;
    final stretch = ((edgeRight - edgeLeft) / item - 1).clamp(-0.3, 1.0);
    final squash = (_navHeight - 2 * _inset) * 0.08 * stretch;
    final velocity = (_left.c.velocity + _right.c.velocity).abs() / 2;
    final lift =
        math.max(_lift.value.clamp(0.0, 1.2), (velocity / 6).clamp(0.0, 1.0)) *
        (1 - folded);
    final capsuleOpen = Rect.fromLTRB(
      edgeLeft,
      full.top + _inset + squash,
      edgeRight,
      full.bottom - _inset - squash,
    );
    final capsule = Rect.lerp(
      capsuleOpen.inflate(2 * lift),
      leftDock.deflate(_inset),
      t,
    )!;
    final capsuleAlpha = (1 - folded * 1.5).clamp(0.0, 1.0);

    final pillContent = <Widget>[
      if (capsuleAlpha > 0)
        Positioned.fromRect(
          rect: capsule.shift(-pill.topLeft),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: capsuleColor.withValues(
                alpha: capsuleColor.a * capsuleAlpha,
              ),
              borderRadius: BorderRadius.circular(capsule.shortestSide / 2),
            ),
          ),
        ),
      for (final (i, (label, icon, selectedIcon)) in items.indexed)
        ..._item(
          center: _lerp(slotCenter(i), leftDock.center.dx, t) - pill.left,
          iconTop: iconTop - pill.top,
          width: item,
          icon: i == selected ? selectedIcon : icon,
          label: label,
          ink: ink,
          iconAlpha: i == _anchor
              ? 1
              : (1 - folded / (i == AndroidFloatingBar.searchIndex ? 0.3 : 0.5))
                    .clamp(0.0, 1.0),
          labelAlpha: (1 - folded * 2.5).clamp(0.0, 1.0),
        ),
      // 点按区域：展开时每项一块；收起后整枚圆钮点按展开
      if (open)
        for (final (i, (label, _, _)) in items.indexed)
          Positioned(
            left: slotCenter(i) - item / 2 - pill.left,
            width: item,
            top: 0,
            bottom: 0,
            child: Semantics(
              button: true,
              selected: i == index,
              label: label,
              child: GestureDetector(
                key: ValueKey('floating-bar-tab-$i'),
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onSelected(i),
              ),
            ),
          )
      else
        Positioned.fill(
          child: Semantics(
            button: true,
            label: items[_anchor].$1,
            child: GestureDetector(
              key: const ValueKey('floating-bar-expand'),
              behavior: HitTestBehavior.opaque,
              onTap: _expand,
            ),
          ),
        ),
    ];

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 与原底栏相同的底部渐变，托住导航下方的内容
        Positioned(
          key: const ValueKey('floating-bar-scrim'),
          left: 0,
          right: 0,
          bottom: 0,
          height: bottom + _navHeight,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colorScheme.surface.withAlpha(0),
                    colorScheme.surface.withAlpha(120),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned.fromRect(
          key: const ValueKey('floating-bar-nav'),
          rect: pill,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: open ? (_) => _dragStart() : null,
            onHorizontalDragUpdate: open ? (d) => _dragUpdate(d, item) : null,
            onHorizontalDragEnd: open ? (_) => _dragEnd() : null,
            onHorizontalDragCancel: open ? _dragEnd : null,
            child: HyperBlendSurface(
              material: HyperBlendSurface.bar(context),
              borderRadius: BorderRadius.circular(pill.height / 2),
              bloom: HyperBlendSurface.barBloom(context),
              shadow: true,
              child: SizedBox.expand(child: Stack(children: pillContent)),
            ),
          ),
        ),
        if (searchAlpha > 0)
          Positioned.fromRect(
            key: const ValueKey('floating-bar-search'),
            rect: search,
            child: IgnorePointer(
              ignoring: searchAlpha < 0.5,
              child: Opacity(
                opacity: searchAlpha,
                child: Semantics(
                  button: true,
                  selected: index == AndroidFloatingBar.searchIndex,
                  label: items[AndroidFloatingBar.searchIndex].$1,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      widget.onSelected(AndroidFloatingBar.searchIndex);
                      _expand();
                    },
                    child: HyperBlendSurface(
                      material: HyperBlendSurface.bar(context),
                      borderRadius: BorderRadius.circular(search.height / 2),
                      bloom: HyperBlendSurface.barBloom(context),
                      shadow: true,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (index == AndroidFloatingBar.searchIndex)
                            Padding(
                              padding: const EdgeInsets.all(_inset),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: capsuleColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ExcludeSemantics(
                            child: Icon(
                              Icons.search_rounded,
                              size: _iconSize,
                              color: ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (lift > 0.01)
          Positioned.fromRect(
            key: const ValueKey('floating-bar-lens'),
            rect: capsuleOpen.inflate(4 * lift),
            child: _SliderLens(
              size: capsuleOpen.inflate(4 * lift).size,
              lift: lift.clamp(0.0, 1.0),
              refract:
                  !tokens.powerSaving &&
                  !PerfFlags.noBackdrop &&
                  !context.reduceMotion,
            ),
          ),
        if (player != null)
          Positioned.fromRect(
            key: const ValueKey('floating-bar-player'),
            rect: _player(full, leftDock, rightDock, navBottom, s),
            child: player,
          ),
      ],
    );
  }

  /// 展开时在导航上方铺满两侧边距之间，收起后在两枚圆钮之间、与圆钮底对齐。
  Rect _player(
    Rect full,
    Rect leftDock,
    Rect rightDock,
    double navBottom,
    double s,
  ) {
    final open = Rect.fromLTRB(
      full.left,
      full.top - _gap - _playerHeight,
      full.right,
      full.top - _gap,
    );
    final docked = Rect.fromLTRB(
      leftDock.right + _gap,
      navBottom - _playerHeight,
      math.max(leftDock.right + _gap, rightDock.left - _gap),
      navBottom,
    );
    return Rect.lerp(open, docked, s)!;
  }

  List<Widget> _item({
    required double center,
    required double iconTop,
    required double width,
    required IconData icon,
    required String label,
    required Color ink,
    required double iconAlpha,
    required double labelAlpha,
  }) => [
    if (iconAlpha > 0)
      Positioned(
        left: center - _iconSize,
        width: _iconSize * 2,
        top: iconTop,
        height: _iconSize,
        child: ExcludeSemantics(
          child: Opacity(
            opacity: iconAlpha,
            child: Icon(icon, size: _iconSize, color: ink),
          ),
        ),
      ),
    if (labelAlpha > 0)
      Positioned(
        left: center - width / 2,
        width: width,
        top: iconTop + _iconSize,
        child: ExcludeSemantics(
          child: Opacity(
            opacity: labelAlpha,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: ink, fontSize: Hy.footnote, height: 1.2),
            ),
          ),
        ),
      ),
  ];

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// 浮起的选中胶囊：放大下方的图标和背景（折射），边缘随浮起程度亮起。
class _SliderLens extends StatelessWidget {
  const _SliderLens({
    required this.size,
    required this.lift,
    required this.refract,
  });

  final Size size;
  final double lift;

  /// 省电模式、关闭背景模糊或减弱动效时不放大，只画边缘高光。
  final bool refract;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (refract)
          RawMagnifier(
            size: size,
            magnificationScale: 1 + 0.1 * lift,
            decoration: const MagnifierDecoration(shape: StadiumBorder()),
          ),
        CustomPaint(painter: _LensRimPainter(lift)),
      ],
    ),
  );
}

class _LensRimPainter extends CustomPainter {
  const _LensRimPainter(this.lift);

  final double lift;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.shortestSide / 2),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = Colors.white.withValues(alpha: 0.06 * lift),
    );
    // 光从左上来：左上沿最亮，中段收暗，右下沿是一道弱反光
    canvas.drawRRect(
      rrect.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.7 * lift),
            Colors.white.withValues(alpha: 0.12 * lift),
            Colors.white.withValues(alpha: 0.45 * lift),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_LensRimPainter old) => old.lift != lift;
}
