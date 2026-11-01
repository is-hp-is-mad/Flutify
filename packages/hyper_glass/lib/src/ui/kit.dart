import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

import '../../hyper_glass.dart';
import 'arc_menu.dart';
import 'theme.dart';

/// miuix design tokens (MIUIDeskClock res/values, identical across the ROM's miuix apps).
abstract final class Hy {
  // miuix_theme_radius_*
  static const rTiny = 8.0, rSmall = 12.0, rCommon = 16.0, rMedium = 20.0, rDemiBig = 24.0, rBig = 36.0;
  // miuix_font_size_*
  static const title1 = 32.0, title2 = 24.0, title3 = 20.0, title4 = 18.0;
  static const headline1 = 17.0, body1 = 16.0, body2 = 14.0, subtitle = 13.0, footnote = 11.0;
  // miuix_theme_*_horizontal_common, miuix_theme_container_margin_*
  static const marginBase = 12.0, marginList = 16.0;
  static const barHeight = 56.0;

  /// MIUIGallery pp+0x55570, the bloom of its floating bars: far brighter than miuix's Glass_Stroke_Middle.
  static const flutterBloom = BloomStroke(
    width: 1.2,
    color: Color(0xb3ffffff),
    innerBlur: 1.2,
    lightDir1: [0.2, 0.5, 0],
    lightColor1: Color(0xb3ffffff),
    lightDir2: [0.8, 0.9, 0],
    lightColor2: Color(0x1affffff),
    strokeFade: true, // gradient degree 180 in the same record
  );

  /// miuix's action bar on HyperOS 3+: Mask.Pured_Regular (mask blur 40 / 60) under maskColor #f3f3f3 / #000000.
  static BlendMaterial actionBarBlur(bool dark) => BlendMaterial(
    sigma: dark ? 60 : 40,
    fallback: window(dark),
    layers: dark ? BlendMaterial.dialogDark.layers : BlendMaterial.dialogLight.layers,
  );

  /// The material of floating controls: `internal-pured-thin-glass` in miuix, and the same layers with sigma 20
  /// in MIUIGallery's bottom bar (0xdfca30). Despite the name it is a blend blur, not refraction: the Gallery's
  /// snapshot has no ImageFilter glass entry at all.
  static BlendMaterial thinGlass(bool dark) => BlendMaterial(
    sigma: 20,
    fallback: dark ? BlendMaterial.popupMenuDark.fallback : BlendMaterial.popupMenuLight.fallback,
    layers: dark ? BlendMaterial.popupMenuDark.layers : BlendMaterial.popupMenuLight.layers,
  );

  static Color primary(bool dark) => dark ? const Color(0xff277af7) : const Color(0xff3482ff);
  static Color window(bool dark) => dark ? const Color(0xff000000) : const Color(0xfff7f7f7);
  static Color card(bool dark) => dark ? const Color(0xff1f1f1f) : const Color(0xffffffff);
  static Color text(bool dark) => dark ? const Color(0xe6ffffff) : const Color(0xe6000000);
  static Color sub(bool dark) => dark ? const Color(0x99ffffff) : const Color(0x99000000);
  static Color hint(bool dark) => dark ? const Color(0x66ffffff) : const Color(0x66000000);
  static Color divider(bool dark) => dark ? const Color(0x14ffffff) : const Color(0x0f000000);
  // miuix_color_*_level8 pressed state
  static Color pressed(bool dark) => dark ? const Color(0x14ffffff) : const Color(0x14000000);
}

/// A value driven by a HyperOS spring (damping ratio + response), retargetable mid-flight.
class SpringValue {
  SpringValue(TickerProvider vsync, {double value = 0, this.damping = 0.8, this.response = 0.4})
    : c = AnimationController.unbounded(vsync: vsync, value: value);
  final AnimationController c;
  double damping, response;

  double get value => c.value;
  void to(double v, {double? damping, double? response}) =>
      c.animateWith(SpringSimulation(hyperSpring(damping ?? this.damping, response ?? this.response), c.value, v, c.velocity));
  void dispose() => c.dispose();
}

/// android.view.animation.DecelerateInterpolator.
class Decelerate extends Curve {
  const Decelerate(this.factor);
  final double factor;
  @override
  double transformInternal(double t) => 1 - math.pow(1 - t, 2 * factor).toDouble();
}

/// Touch feedback of miuix (FolmeTouch): the longest side sinks by 10dp, never below 90%, on spring (0.99, 0.15);
/// release runs on (0.99, 0.3). [scale] lowers that floor further for small targets that want more travel.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.scale = 0.94});
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final _s = SpringValue(this, value: 1, damping: 0.72, response: 0.3);

  double get _pressed {
    final size = context.size;
    if (size == null || size.longestSide <= 0) return 0.9;
    return math.max((size.longestSide - 10) / size.longestSide, math.min(0.9, widget.scale));
  }

  @override
  void dispose() {
    _s.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => _s.to(_pressed, damping: 0.99, response: 0.15),
    onTapCancel: () => _s.to(1, damping: 0.99, response: 0.3),
    onTapUp: (_) => _s.to(1, damping: 0.99, response: 0.3),
    onTap: widget.onTap,
    child: AnimatedBuilder(
      animation: _s.c,
      builder: (_, c) => Transform.scale(scale: _s.value, child: c),
      child: widget.child,
    ),
  );
}

/// Pressable glass surface: scale, uHit (refraction rises by up to 0.2) and the press light at the finger.
class GlassPress extends StatefulWidget {
  const GlassPress({
    super.key,
    this.filter = const GlassFilter(),
    this.radius = 24,
    this.onTap,
    this.bloom,
    this.scale = 0.96,
    this.opacity = 1,
    this.fx = const GlassFx(),
    this.mask,
    this.child,
  });
  final GlassFilter filter;
  final double radius, scale, opacity;
  final VoidCallback? onTap;
  final BloomStroke? bloom;

  /// [GlassFx.hit] is raised while pressed; the rest is passed through.
  final GlassFx fx;
  final ui.Image? mask;
  final Widget? child;
  @override
  State<GlassPress> createState() => _GlassPressState();
}

class _GlassPressState extends State<GlassPress> with SingleTickerProviderStateMixin {
  late final _s = SpringValue(this, damping: 0.75, response: 0.3);
  Offset _at = Offset.zero;

  void _down(Offset p) {
    _at = p;
    _s.to(1);
  }

  @override
  void dispose() {
    _s.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (d) => _down(d.localPosition),
    onTapCancel: () => _s.to(0),
    onTapUp: (_) => _s.to(0),
    onTap: widget.onTap,
    child: AnimatedBuilder(
      animation: _s.c,
      builder: (_, _) {
        final t = _s.value;
        final fx = widget.fx;
        return Transform.scale(
          scale: 1 - (1 - widget.scale) * t,
          child: HyperGlass(
            filter: widget.filter,
            borderRadius: widget.radius,
            opacity: widget.opacity,
            fx: GlassFx(
              hit: math.max(t.clamp(0.0, 1.0), fx.hit),
              rotation: fx.rotation,
              iconRect: fx.iconRect,
              iconStrength: fx.iconStrength,
              iconMode: fx.iconMode,
              iconRadius: fx.iconRadius,
              dynamicLight: fx.dynamicLight,
            ),
            mask: widget.mask,
            bloom: widget.bloom,
            press: const PressLight(),
            pressAt: _at,
            pressOpacity: t.clamp(0.0, 1.0),
            child: widget.child,
          ),
        );
      },
    ),
  );
}

/// A floating control: thin-glass material, `Glass_Stroke_Middle_*` bloom and ShadowToken.Regular.
class FloatSurface extends StatelessWidget {
  const FloatSurface({super.key, required this.radius, this.opacity = 1, this.onTap, this.bloom, this.child});
  final double radius, opacity;
  final VoidCallback? onTap;

  /// Defaults to miuix's stroke; Flutter apps pass [Hy.flutterBloom].
  final BloomStroke? bloom;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    final surface = ViewShadow(
      radius: radius,
      opacity: opacity,
      child: HyperBlendBlur(
        material: Hy.thinGlass(dark),
        borderRadius: radius,
        opacity: opacity,
        bloom: bloom ?? (dark ? BloomTokens.strokeMiddleDark : BloomTokens.strokeMiddleLight),
        child: child,
      ),
    );
    return onTap == null ? surface : Pressable(scale: 0.92, onTap: onTap, child: surface);
  }
}

/// miuix sliding button (off bar 10% black, on bar primary, white thumb).
class HySwitch extends StatefulWidget {
  const HySwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  State<HySwitch> createState() => _HySwitchState();
}

class _HySwitchState extends State<HySwitch> with SingleTickerProviderStateMixin {
  late final _s = SpringValue(this, value: widget.value ? 1 : 0, damping: 0.72, response: 0.3);

  @override
  void didUpdateWidget(HySwitch old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _s.to(widget.value ? 1 : 0);
  }

  @override
  void dispose() {
    _s.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return GestureDetector(
      onTap: () => widget.onChanged(!widget.value),
      child: AnimatedBuilder(
        animation: _s.c,
        builder: (_, _) {
          final t = _s.value;
          return Container(
            width: 49,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Color.lerp(dark ? const Color(0x33ffffff) : const Color(0x1f000000), HyperTheme.primaryOf(context), t.clamp(0.0, 1.0)),
            ),
            child: Align(
              alignment: Alignment(-1 + 2 * t, 0),
              child: Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The floating app bar of HyperOS apps: large title in the list, gradient-blur mask + small title once
/// content scrolls under it, round glass back button that only exists while floating.
class FloatingBar extends StatelessWidget {
  const FloatingBar({
    super.key,
    this.top,
    required this.title,
    required this.offset,
    this.dark,
    this.onBack,
    this.foreground,
    this.actions = const [],
    this.maskColor,
    this.maskBlur,
    this.bloom,
  });

  /// MIUIGallery's app bar (0xbce8a8): this colour under the same alpha stops, over a blur of 20, instead of
  /// the blend material. #f3f3f3 / #242424 there.
  final Color? maskColor;

  /// The blur under [maskColor]; plain by default.
  final BlendMaterial? maskBlur;
  final BloomStroke? bloom;
  final double offset;
  final String title;

  /// The status bar's height by default.
  final double? top;

  /// The theme's by default: a page over a dark picture says so here.
  final bool? dark;

  /// Null on a root page: no back button.
  final VoidCallback? onBack;
  final Color? foreground;
  final List<Widget> actions;

  // MIUIWeather gradientBlur mask: alpha stops (pp+0x2bc00) at positions (pp+0x2bc08), top to bottom.
  static const _maskAlpha = [1.0, 0.98, 0.8, 0.5, 0.0];
  static const _maskStops = [0.0, 0.52, 0.74, 0.85, 1.0];

  @override
  Widget build(BuildContext context) {
    final top = this.top ?? MediaQuery.paddingOf(context).top;
    final dark = this.dark ?? HyperTheme.isDark(context);
    final floating = offset > 0.5;
    final titleT = ((offset - 24) / 32).clamp(0.0, 1.0);
    final fg = foreground ?? Hy.text(dark);
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: top + Hy.barHeight + 28,
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: floating ? 1 : 0),
              duration: const Duration(milliseconds: 220),
              builder: (context, v, _) {
                if (v <= 0.001) return const SizedBox.shrink();
                final mask = maskColor;
                final blur = ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (r) => LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [for (final a in _maskAlpha) Colors.white.withValues(alpha: a)],
                    stops: _maskStops,
                  ).createShader(r),
                  child: HyperBlendBlur(
                    material: mask != null
                        ? (maskBlur ?? BlendMaterial(sigma: 20, layers: const [], fallback: mask))
                        : (dark ? BlendMaterial.appBarDark : BlendMaterial.appBarLight),
                    borderRadius: 0,
                    opacity: v,
                  ),
                );
                if (mask == null) return blur;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    blur,
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [for (final a in _maskAlpha) mask.withValues(alpha: a * v)],
                          stops: _maskStops,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        Positioned(
          top: top,
          left: 64,
          right: 64,
          height: Hy.barHeight,
          child: IgnorePointer(
            child: Center(
              child: Opacity(
                opacity: titleT,
                child: Text(
                  title,
                  style: TextStyle(color: fg, fontSize: Hy.title4, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
        if (onBack != null)
          Positioned(
            left: 12,
            top: top + 8,
            width: 40,
            height: 40,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: floating ? 1 : 0),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                builder: (context, v, child) => Stack(
                  fit: StackFit.expand,
                  children: [
                    if (v > 0.001)
                      Transform.scale(
                        scale: 0.8 + 0.2 * v,
                        child: FloatSurface(radius: 20, opacity: v, bloom: bloom),
                      ),
                    child!,
                  ],
                ),
                child: Center(child: Icon(Icons.arrow_back_ios_new, color: fg, size: 19)),
              ),
            ),
          ),
        Positioned(
          right: 12,
          top: top + 8,
          height: 40,
          child: Row(children: actions),
        ),
      ],
    );
  }
}

/// Paints [child] only inside [text]'s glyphs: the lock-screen clock's text-shaped glass.
class TextMasked extends SingleChildRenderObjectWidget {
  const TextMasked({super.key, required this.text, required this.style, required Widget super.child});
  final String text;
  final TextStyle style;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTextMasked(text, style);
  @override
  void updateRenderObject(BuildContext context, _RenderTextMasked ro) => ro
    ..text = text
    ..style = style
    ..markNeedsPaint();
}

class _RenderTextMasked extends RenderProxyBox {
  _RenderTextMasked(this.text, this.style);
  String text;
  TextStyle style;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final rect = offset & size;
    final c = context.canvas;
    c.saveLayer(rect, Paint());
    context.paintChild(child!, offset);
    // the child may have forced a new layer; always fetch the current canvas
    final canvas = context.canvas;
    canvas.saveLayer(rect, Paint()..blendMode = BlendMode.dstIn);
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset + Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
    tp.dispose();
    canvas.restore();
    canvas.restore();
  }
}

/// White-on-black image of a rounded rect: the mask texture the icon light samples.
ui.Image makeRoundMask(int size) {
  final rec = ui.PictureRecorder();
  final s = size.toDouble();
  ui.Canvas(rec)
    ..drawRect(Rect.fromLTWH(0, 0, s, s), Paint()..color = Colors.black)
    ..drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.27)), Paint()..color = Colors.white);
  final pic = rec.endRecording();
  final img = pic.toImageSync(size, size);
  pic.dispose();
  return img;
}
