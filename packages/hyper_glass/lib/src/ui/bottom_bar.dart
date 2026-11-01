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
/// black labels whether selected or not, and a grey pill inset 3dp that marks the current tab. The icon also turns
/// solid. Selecting is not a colour change, which is the Gallery's own design.
///
/// Lays itself out at the bottom of its parent (BottomNavigatorLayoutHelper: 24dp from the edges, at most 344dp wide,
/// 24dp above the bottom), so it goes in [HyperOverlay.floating] or any other full-size layer inside a scene.
class HyperBottomBar extends StatefulWidget {
  const HyperBottomBar({super.key, required this.items, required this.index, required this.onChanged, this.surface});
  final List<HyperBottomBarItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  /// Draws the pill's surface for a host without a scene; the bar then fills its parent instead of laying itself
  /// out at the bottom of it.
  final Widget Function(Widget child)? surface;

  @override
  State<HyperBottomBar> createState() => _HyperBottomBarState();
}

class _HyperBottomBarState extends State<HyperBottomBar> with TickerProviderStateMixin {
  // OverlayView: the edge in front runs on the fast spring and the one behind on the slow one, so the pill stretches
  late final _left = SpringValue(this, value: widget.index.toDouble());
  late final _right = SpringValue(this, value: widget.index + 1.0);

  /// The pill's position in tabs while it follows the finger; null otherwise.
  double? _drag;

  void _dragTo(double position) {
    final to = position.clamp(0.0, widget.items.length - 1.0);
    _left.c.value = to;
    _right.c.value = to + 1;
    setState(() => _drag = to);
  }

  void _dragEnd() {
    final to = _drag?.round();
    setState(() => _drag = null);
    if (to == null) return;
    if (to != widget.index) {
      widget.onChanged(to);
    } else {
      _left.to(to.toDouble());
      _right.to(to + 1.0);
    }
  }

  @override
  void didUpdateWidget(HyperBottomBar old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    final i = widget.index, forward = i >= old.index;
    _left.to(i.toDouble(), damping: forward ? 0.75 : 0.7, response: forward ? 0.5 : 0.4);
    _right.to(i + 1.0, damping: forward ? 0.7 : 0.75, response: forward ? 0.4 : 0.5);
  }

  @override
  void dispose() {
    _left.dispose();
    _right.dispose();
    super.dispose();
  }

  Widget _bar(bool dark) {
    final content = _content(dark);
    return widget.surface?.call(content) ?? FloatSurface(radius: 28, child: content);
  }

  Widget _content(bool dark) => LayoutBuilder(
      builder: (context, c) {
        final item = (c.maxWidth - 6) / widget.items.length;
        final selected = _drag?.round() ?? widget.index;
        // the pill follows the finger and settles on the nearest tab (BottomNavigator's drag)
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => _dragTo((_drag ?? widget.index.toDouble()) + d.delta.dx / item),
          onHorizontalDragEnd: (_) => _dragEnd(),
          onHorizontalDragCancel: _dragEnd,
          child: Stack(
          children: [
            AnimatedBuilder(
              animation: Listenable.merge([_left.c, _right.c]),
              builder: (_, _) {
                final left = 3 + _left.value * item, right = 3 + _right.value * item;
                return Positioned(
                  left: left,
                  top: 3,
                  bottom: 3,
                  width: right - left,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: dark ? const Color(0x1fffffff) : const Color(0x0f000000),
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                );
              },
            ),
            Row(
              children: [
                const SizedBox(width: 3),
                for (final (i, item) in widget.items.indexed)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onChanged(i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(i == selected ? item.selectedIcon : item.icon, size: 26, color: Hy.text(dark)),
                          Text(
                            item.label,
                            style: TextStyle(color: Hy.text(dark), fontSize: Hy.footnote, height: 1.2),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(width: 3),
              ],
            ),
          ],
          ),
        );
      },
  );

  @override
  Widget build(BuildContext context) => widget.surface != null ? _bar(HyperTheme.isDark(context)) : LayoutBuilder(
    builder: (context, c) {
      final width = math.min(c.maxWidth - 48, 344.0);
      return Stack(
        children: [
          Positioned(
            left: (c.maxWidth - width) / 2,
            width: width,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
            height: 56,
            child: _bar(HyperTheme.isDark(context)),
          ),
        ],
      );
    },
  );
}
