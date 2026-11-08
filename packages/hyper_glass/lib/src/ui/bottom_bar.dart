import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'kit.dart';
import 'theme.dart';

class HyperBottomBarItem {
  const HyperBottomBarItem(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon, selectedIcon;
}

/// miuix.bottomnavigation.BottomNavigator, as in Clock, Notes, Files, Themes and Calendar: internal-pured-thin-glass,
/// black labels whether selected or not, and a grey pill inset 3dp that marks the current tab.
///
/// Lays itself out at the bottom of its parent (BottomNavigatorLayoutHelper: 24dp from the edges, compact 88dp-per-item
/// with -10dp overlap for 2–3 tabs, at most 344dp wide for 4–5 tabs, 24dp above the bottom, plus a 100dp bottom-to-top
/// gradient scrim behind the pill), so it goes in [HyperOverlay.floating] or any other full-size layer inside a scene.
class HyperBottomBar extends StatefulWidget {
  const HyperBottomBar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    this.gradientBackground = true,
    this.surface,
  });
  final List<HyperBottomBarItem> items;
  final int index;
  final ValueChanged<int> onChanged;
  final bool gradientBackground;

  /// Optional custom surface painter for backwards compatibility.
  final Widget Function(Widget child)? surface;

  @override
  State<HyperBottomBar> createState() => _HyperBottomBarState();
}

class _HyperBottomBarState extends State<HyperBottomBar> with TickerProviderStateMixin {
  // OverlayView: the edge in front runs on the fast spring and the one behind on the slow one, so the pill stretches
  late final _left = SpringValue(this, value: widget.index.toDouble());
  late final _right = SpringValue(this, value: widget.index.toDouble());
  late final _press = SpringValue(this, value: 0, damping: 0.85, response: 0.2);
  bool _dragging = false;

  @override
  void didUpdateWidget(HyperBottomBar old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    _moveTo(widget.index, old.index);
  }

  void _moveTo(int i, int from) {
    final forward = i >= from;
    _left.to(i.toDouble(), damping: forward ? 0.75 : 0.7, response: forward ? 0.5 : 0.4);
    _right.to(i.toDouble(), damping: forward ? 0.7 : 0.75, response: forward ? 0.4 : 0.5);
  }

  @override
  void dispose() {
    _left.dispose();
    _right.dispose();
    _press.dispose();
    super.dispose();
  }

  // NavigationItemViewHelper.setupItemMargins: item 0 starts at 3dp, each subsequent item has marginStart = -10dp,
  // and item n-1 has marginEnd = 3dp.
  ({double barWidth, double itemWidth, double step}) _metrics(double maxWidth) {
    final n = widget.items.length;
    // 自适应宽度：小屏幕自适应填充（与上方 MiniPlayer 胶囊宽度一致，左右留 40dp 边距），大屏幕按比例最大 480
    final avail = math.max(0.0, maxWidth - 40);
    final barW = avail.clamp(280.0, 480.0);
    final itemW = (barW - 6) / n;
    return (barWidth: barW, itemWidth: itemW, step: itemW);
  }

  int _hitIndex(double dx, double step, int n) => ((dx - 3) / step).floor().clamp(0, n - 1);

  Widget _bar(bool dark, double barWidth, double itemWidth, double step) {
    final n = widget.items.length;
    // NavigatorColorUtils: #ff000000 light, #f2ffffff (miuix_color_white_level1_1) dark
    final itemColor = dark ? const Color(0xf2ffffff) : const Color(0xff000000);
    Widget inner = Stack(
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([_left.c, _right.c, _press.c]),
          builder: (_, _) {
            final l = 3 + math.min(_left.value, _right.value) * step;
            final r = 3 + math.max(_left.value, _right.value) * step + itemWidth;
            final w = math.max(itemWidth, r - l);
            const h = 50.0;
            // OverlayView.pressOverlay: mPressScaleOffset = 6dp, alpha 0.06 -> 0.16 light / 0.12 -> 0.26 dark
            final p = _press.value.clamp(0.0, 1.0);
            final sx = 1.0 - (6.0 / w) * p;
            final sy = 1.0 - (6.0 / h) * p;
            final alpha = dark ? (0.12 + 0.14 * p) : (0.06 + 0.10 * p);
            return Positioned(
              left: l,
              top: 3,
              bottom: 3,
              width: w,
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(sx, sy, 1),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: (dark ? Colors.white : Colors.black).withValues(alpha: alpha),
                    borderRadius: BorderRadius.circular(29),
                  ),
                ),
              ),
            );
          },
        ),
        for (final (i, item) in widget.items.indexed)
          Positioned(
            left: 3 + i * step,
            top: 0,
            bottom: 0,
            width: itemWidth,
            // bottom_navigator_item.xml: 28x28dp icon frame (symbolIconSize 21dp), 11sp w500 title,
            // solid icon in both normal and selected states across HyperOS 4 system apps.
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: Icon(item.selectedIcon, size: 22, color: itemColor),
                    ),
                  ),
                  Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: itemColor,
                      fontSize: Hy.footnote,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );

    final wrapped = widget.surface != null
        ? widget.surface!(inner)
        : FloatSurface(radius: 32, child: inner);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        _press.to(1);
        final hit = _hitIndex(d.localPosition.dx, step, n);
        if (hit != widget.index) _moveTo(hit, widget.index);
      },
      onTapUp: (d) {
        _press.to(0);
        final hit = _hitIndex(d.localPosition.dx, step, n);
        if (hit != widget.index) {
          widget.onChanged(hit);
        } else {
          _moveTo(widget.index, widget.index);
        }
      },
      onTapCancel: () {
        if (_dragging) return;
        _press.to(0);
        _moveTo(widget.index, widget.index);
      },
      onHorizontalDragStart: (d) {
        _dragging = true;
        _press.to(1);
        final hit = _hitIndex(d.localPosition.dx, step, n);
        if (hit != widget.index) {
          _moveTo(hit, widget.index);
          widget.onChanged(hit);
        }
      },
      onHorizontalDragUpdate: (d) {
        final hit = _hitIndex(d.localPosition.dx, step, n);
        if (hit != widget.index) {
          _moveTo(hit, widget.index);
          widget.onChanged(hit);
        }
      },
      onHorizontalDragEnd: (_) {
        _dragging = false;
        _press.to(0);
        _moveTo(widget.index, widget.index);
      },
      onHorizontalDragCancel: () {
        if (!_dragging) return;
        _dragging = false;
        _press.to(0);
        _moveTo(widget.index, widget.index);
      },
      child: wrapped,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final dark = HyperTheme.isDark(context);
      final bottom = MediaQuery.paddingOf(context).bottom;
      final m = _metrics(c.maxWidth);
      if (widget.surface != null) {
        return Center(
          child: SizedBox(
            width: m.barWidth,
            height: 64,
            child: _bar(dark, m.barWidth, m.itemWidth, m.step),
          ),
        );
      }
      // BottomNavigator.applyOuterBackground: BOTTOM_TOP gradient from #f5f3f3f3 (light) / #f5000000 (dark) to 0
      final gradColor = dark ? const Color(0xf5000000) : const Color(0xf5f3f3f3);
      return Stack(
        children: [
          if (widget.gradientBackground)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 100 + bottom,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [gradColor, gradColor.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: (c.maxWidth - m.barWidth) / 2,
            width: m.barWidth,
            bottom: 24 + bottom,
            height: 64,
            child: _bar(dark, m.barWidth, m.itemWidth, m.step),
          ),
        ],
      );
    },
  );
}
