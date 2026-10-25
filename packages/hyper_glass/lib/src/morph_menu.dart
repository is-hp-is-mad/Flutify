import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'blend_material.dart';
import 'hyper_glass.dart';

/// HyperOS springs are given as SpringCurveParams(damping ratio, response in seconds), like iOS.
SpringDescription hyperSpring(double damping, double response) => SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: math.pow(2 * math.pi / response, 2).toDouble(),
  ratio: damping,
);

/// `HyperUI#PopupAnimation` springs (MIUIWeather pp+0x38a70 / pp+0x38a78, class sEa): one
/// (show, hide) pair per animated property. Which pair drives which property is inferred: the
/// geometry uses (0.8, 0.4) / (0.8, 0.28) and the fade (0.8, 0.25) / (0.8, 0.4).
final _geometryShow = hyperSpring(0.8, 0.4), _geometryHide = hyperSpring(0.8, 0.28);
final _fadeShow = hyperSpring(0.8, 0.25), _fadeHide = hyperSpring(0.8, 0.4);

/// Drives one HyperOS popup: [geometry] (morph from the anchor, item burst) and [fade] (surface and
/// item opacity), each with its own show / hide spring. Unbounded so the springs can overshoot.
class PopupMotion {
  PopupMotion(TickerProvider vsync)
    : geometry = AnimationController.unbounded(vsync: vsync),
      fade = AnimationController.unbounded(vsync: vsync);

  final AnimationController geometry, fade;
  bool open = false;

  Listenable get listenable => Listenable.merge([geometry, fade]);
  bool get active => open || geometry.value > 0.001 || fade.value > 0.001;

  void set(bool value) {
    open = value;
    geometry.animateWith(
      SpringSimulation(value ? _geometryShow : _geometryHide, geometry.value, value ? 1 : 0, geometry.velocity),
    );
    fade.animateWith(SpringSimulation(value ? _fadeShow : _fadeHide, fade.value, value ? 1 : 0, fade.velocity));
  }

  void dispose() {
    geometry.dispose();
    fade.dispose();
  }
}

class MorphMenuItem {
  const MorphMenuItem(this.label, this.onTap, {this.icon, this.selected = false});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool selected;
}

/// Cross-fade between the anchor (button / row) and the frosted menu while the menu is still about
/// the anchor's size (first 15% of the morph). The spring settles around 0 when closing; there the
/// menu is fully transparent, so the anchor never shows through a frosted layer.
double menuSwap(double t) => (t / 0.15).clamp(0.0, 1.0);

/// Final menu rect for [anchor]: aligned with the anchor's own edge when it sits near a screen edge
/// (HyperOS puts such buttons at an edge or corner, and the menu then spreads out of that corner),
/// growing up when [growUp] (anchor near the bottom) and down otherwise, kept inside [screen].
Rect menuRectFor(Rect anchor, Size screen, double width, double height, {required bool growUp}) {
  final double left;
  if (anchor.center.dx > screen.width * 2 / 3) {
    left = anchor.right - width;
  } else if (anchor.center.dx < screen.width / 3) {
    left = anchor.left;
  } else {
    left = anchor.center.dx - width / 2;
  }
  final top = growUp ? anchor.bottom - height : anchor.top;
  return Rect.fromLTWH(
    left.clamp(12.0, screen.width - width - 12),
    top.clamp(12.0, math.max(12.0, screen.height - height - 12)),
    width,
    height,
  );
}

/// The popup driven by [motion]: a frosted HyperBlendBlur surface whose real geometry morphs from
/// [anchor] to [menu], with the items bursting out of the tap point (the anchor centre).
class MorphMenu extends StatelessWidget {
  const MorphMenu({
    super.key,
    required this.motion,
    required this.anchor,
    required this.menu,
    required this.dark,
    required this.items,
    required this.onDismiss,
    this.anchorRadius = 32,
    this.itemHeight = 56,
  });

  final PopupMotion motion;
  final Rect anchor, menu;
  final bool dark;
  final List<MorphMenuItem> items;
  final VoidCallback onDismiss;
  final double anchorRadius, itemHeight;

  /// x of an item's icon+label centre inside the menu (22 inset, 22 icon, 14 gap, ~4 CJK chars).
  static const _contentX = 72.0;

  double get t => motion.geometry.value;
  double get fade => motion.fade.value;

  @override
  Widget build(BuildContext context) {
    if (!motion.active) return const SizedBox.shrink();
    final fg = dark ? Colors.white.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.9);
    // Real geometry morph (not a scale transform): the blur surface keeps sampling what is under it.
    final rect = Rect.lerp(anchor, menu, t)!;
    return Stack(
      children: [
        if (motion.open) Positioned.fill(child: GestureDetector(onTap: onDismiss)),
        Positioned.fromRect(
          rect: rect,
          child: ClipRect(
            child: HyperBlendBlur(
              material: dark ? BlendMaterial.popupMenuDark : BlendMaterial.popupMenuLight,
              borderRadius: anchorRadius + (24 - anchorRadius) * t.clamp(0.0, 1.0),
              opacity: menuSwap(t),
              // items are laid out at the final size and revealed by the growing clip
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: menu.width,
                maxWidth: menu.width,
                minHeight: menu.height,
                maxHeight: menu.height,
                child: Transform.translate(
                  offset: menu.topLeft - rect.topLeft,
                  // InkWell needs its own Material here: otherwise hover / splash ink is painted on a
                  // far ancestor, outside this clip and transform, and shows up offset from the item.
                  child: Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          for (final (i, item) in items.indexed)
                            InkWell(
                              onTap: item.onTap,
                              child: SizedBox(
                                height: itemHeight,
                                child: _popItem(
                                  // from the tap point (anchor centre) to this item's content
                                  anchor.center - menu.topLeft - Offset(_contentX, 8 + itemHeight * (i + 0.5)),
                                  Row(
                                    children: [
                                      const SizedBox(width: 22),
                                      if (item.icon != null) ...[
                                        Icon(item.icon, color: fg, size: 22),
                                        const SizedBox(width: 14),
                                      ],
                                      Expanded(
                                        child: Text(
                                          item.label,
                                          style: TextStyle(
                                            color: item.selected ? const Color(0xff3482ff) : fg,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      if (item.selected) const Icon(Icons.check, color: Color(0xff3482ff), size: 20),
                                      const SizedBox(width: 20),
                                    ],
                                  ),
                                ),
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
        ),
      ],
    );
  }

  /// Items burst out of the tap point: each starts at the anchor centre ([fromTap] is the offset from
  /// its resting place to there), small and transparent, and flies outward to its slot while growing,
  /// all driven by the menu spring (its overshoot makes them pop slightly past 100%). Closing replays
  /// it backwards, so they collapse into the anchor again.
  Widget _popItem(Offset fromTap, Widget child) {
    final q = math.max(0.0, t); // 1 at rest, slightly >1 while overshooting
    return Opacity(
      opacity: ((fade - 0.2) / 0.8).clamp(0.0, 1.0),
      child: Transform.translate(
        offset: fromTap * (1 - q).clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.3 + 0.7 * q,
          alignment: Alignment(_contentX / (menu.width / 2) - 1, 0),
          child: child,
        ),
      ),
    );
  }
}
