import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/theme/md3e_shapes.dart';
import '../../widgets/cover_image.dart';

class PlayerExpansionMotion {
  static const duration = Duration(milliseconds: 600);
  static const reverseDuration = Duration(milliseconds: 480);
  static const curve = Cubic(0.22, 1.0, 0.36, 1.0);
  static const bottomCurve = Cubic(0.32, 0.0, 0.2, 1.0);

  static CurvedAnimation animate(Animation<double> parent, Curve curve) =>
      CurvedAnimation(
        parent: parent,
        curve: curve,
        reverseCurve: curve.flipped,
      );
}

class PlayerExpansionOrigin {
  const PlayerExpansionOrigin({
    required this.bounds,
    required this.color,
    required this.borderRadius,
    required this.compactChild,
    this.restartTitles,
  });

  final Rect bounds;
  final Color color;
  final BorderRadius borderRadius;
  final Widget compactChild;
  final VoidCallback? restartTitles;
}

class PlayerExpansionSource extends StatefulWidget {
  const PlayerExpansionSource({
    super.key,
    required this.color,
    required this.borderRadius,
    required this.compactChild,
    required this.child,
  });

  final Color color;
  final BorderRadius borderRadius;
  final Widget compactChild;
  final Widget child;

  static final _sources = Expando<_PlayerExpansionSourceState>();

  static Key titleKey(BuildContext context, Object trackKey) => ValueKey((
    trackKey,
    context
            .dependOnInheritedWidgetOfExactType<_MiniPlayerTitleScope>()
            ?.revision ??
        0,
  ));

  static PlayerExpansionOrigin? capture(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final source = _sources[navigator];
    if (source == null || !source.mounted) return null;
    final box = source.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final navigatorBox = Navigator.of(
      context,
      rootNavigator: true,
    ).context.findRenderObject();
    final bounds =
        box.localToGlobal(Offset.zero, ancestor: navigatorBox) & box.size;
    return PlayerExpansionOrigin(
      bounds: bounds,
      color: source.widget.color,
      borderRadius: source.widget.borderRadius,
      compactChild: source.widget.compactChild,
      restartTitles: () => _sources[navigator]?._restartTitles(),
    );
  }

  @override
  State<PlayerExpansionSource> createState() => _PlayerExpansionSourceState();
}

class _PlayerExpansionSourceState extends State<PlayerExpansionSource> {
  NavigatorState? _navigator;
  int _titleRevision = 0;

  void _restartTitles() {
    if (mounted) setState(() => _titleRevision++);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context, rootNavigator: true);
    PlayerExpansionSource._sources[_navigator!] = this;
  }

  @override
  void dispose() {
    if (_navigator != null &&
        PlayerExpansionSource._sources[_navigator!] == this) {
      PlayerExpansionSource._sources[_navigator!] = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _MiniPlayerTitleScope(revision: _titleRevision, child: widget.child);
}

class _MiniPlayerTitleScope extends InheritedWidget {
  const _MiniPlayerTitleScope({required this.revision, required super.child});

  final int revision;

  @override
  bool updateShouldNotify(_MiniPlayerTitleScope oldWidget) =>
      revision != oldWidget.revision;
}

class PlayerExpansionTransition extends StatefulWidget {
  const PlayerExpansionTransition({
    super.key,
    required this.animation,
    required this.origin,
    required this.child,
  });

  final Animation<double> animation;
  final PlayerExpansionOrigin? origin;
  final Widget child;

  @override
  State<PlayerExpansionTransition> createState() =>
      _PlayerExpansionTransitionState();
}

class _PlayerExpansionTransitionState extends State<PlayerExpansionTransition> {
  late CurvedAnimation _surface;
  late CurvedAnimation _bottom;
  late CurvedAnimation _compact;

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed) {
      widget.origin?.restartTitles?.call();
    }
  }

  void _createAnimations() {
    _surface = PlayerExpansionMotion.animate(
      widget.animation,
      PlayerExpansionMotion.curve,
    );
    _bottom = PlayerExpansionMotion.animate(
      widget.animation,
      PlayerExpansionMotion.bottomCurve,
    );
    _compact = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, 0.32, curve: Curves.easeInOutCubic),
      // Keep the opening fade, but return with the artwork/surface curve instead
      // of waiting until the final 32% of the route's closing animation.
      reverseCurve: PlayerExpansionMotion.curve.flipped,
    );
    widget.animation.addStatusListener(_handleAnimationStatus);
  }

  @override
  void initState() {
    super.initState();
    _createAnimations();
  }

  @override
  void didUpdateWidget(PlayerExpansionTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_handleAnimationStatus);
      _surface.dispose();
      _bottom.dispose();
      _compact.dispose();
      _createAnimations();
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleAnimationStatus);
    _surface.dispose();
    _bottom.dispose();
    _compact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AnimatedBuilder(
      animation: widget.animation,
      child: widget.child,
      builder: (context, child) {
        final size = constraints.biggest;
        final origin = widget.origin;
        final source =
            origin?.bounds ??
            Rect.fromLTWH(10, size.height - 120, size.width - 20, 60);
        final progress = _surface.value;
        final bottomProgress = _bottom.value;
        final bounds = Rect.fromLTRB(
          lerpDouble(source.left, 0, progress)!,
          lerpDouble(source.top, 0, progress)!,
          lerpDouble(source.right, size.width, progress)!,
          lerpDouble(source.bottom, size.height, bottomProgress)!,
        );
        final radius = BorderRadius.lerp(
          origin?.borderRadius ?? BorderRadius.circular(30),
          BorderRadius.zero,
          progress,
        )!;
        final compactOpacity = 1 - _compact.value;
        return ClipPath(
          key: const ValueKey('player-expansion-surface'),
          clipper: _PlayerSurfaceClipper(bounds, radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: origin?.color ?? const Color(0xFF3A3A42)),
              child!,
              if (origin != null && compactOpacity > 0)
                Positioned(
                  left: bounds.left,
                  top: bounds.top - 16 * (1 - compactOpacity),
                  width: source.width,
                  height: source.height,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: Opacity(
                        key: const ValueKey('player-expansion-compact'),
                        opacity: compactOpacity,
                        child: origin.compactChild,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

class _PlayerSurfaceClipper extends CustomClipper<Path> {
  const _PlayerSurfaceClipper(this.bounds, this.radius);

  final Rect bounds;
  final BorderRadius radius;

  @override
  Path getClip(Size size) => Path()..addRRect(radius.toRRect(bounds));

  @override
  bool shouldReclip(_PlayerSurfaceClipper oldClipper) =>
      bounds != oldClipper.bounds || radius != oldClipper.radius;
}

class PlayerExpansionReveal extends StatefulWidget {
  const PlayerExpansionReveal({
    super.key,
    required this.animation,
    required this.child,
    this.start = 0.14,
    this.rise = 0.85,
    this.opacityKey,
  });

  final Animation<double>? animation;
  final Widget child;
  final double start;
  final double rise;
  final Key? opacityKey;

  @override
  State<PlayerExpansionReveal> createState() => _PlayerExpansionRevealState();
}

class _PlayerExpansionRevealState extends State<PlayerExpansionReveal> {
  CurvedAnimation? _progress;

  void _createAnimation() {
    final animation = widget.animation;
    _progress = animation == null
        ? null
        : PlayerExpansionMotion.animate(
            animation,
            Interval(widget.start, 1, curve: PlayerExpansionMotion.curve),
          );
  }

  @override
  void initState() {
    super.initState();
    _createAnimation();
  }

  @override
  void didUpdateWidget(PlayerExpansionReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.start != widget.start) {
      _progress?.dispose();
      _createAnimation();
    }
  }

  @override
  void dispose() {
    _progress?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = widget.animation;
    if (animation == null) return widget.child;
    return AnimatedBuilder(
      animation: animation,
      child: widget.child,
      builder: (context, child) {
        final progress = _progress!.value;
        return IgnorePointer(
          ignoring: animation.status != AnimationStatus.completed,
          child: Opacity(
            key: widget.opacityKey,
            opacity: progress,
            child: FractionalTranslation(
              translation: Offset(0, widget.rise * (1 - progress)),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class PlayerArtworkHero extends StatelessWidget {
  const PlayerArtworkHero({
    super.key,
    required this.imageUrl,
    required this.child,
  });

  final String imageUrl;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        context.reduceMotion) {
      return child;
    }
    return Hero(
      tag: 'player-artwork',
      curve: PlayerExpansionMotion.curve,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      flightShuttleBuilder: (context, animation, direction, from, to) {
        final expanded = direction == HeroFlightDirection.push ? to : from;
        final box = expanded.findRenderObject()! as RenderBox;
        final cornerFraction = MD3EShapes.radiusExtraLarge / box.size.width;
        final image = Theme(
          data: Theme.of(from),
          child: CoverImage(url: imageUrl, size: box.size.width),
        );
        return AnimatedBuilder(
          animation: animation,
          child: image,
          builder: (context, child) => LayoutBuilder(
            builder: (context, constraints) => ClipRRect(
              key: const ValueKey('player-artwork-flight'),
              borderRadius: BorderRadius.circular(
                constraints.maxWidth *
                    lerpDouble(0.5, cornerFraction, animation.value)!,
              ),
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }
}
