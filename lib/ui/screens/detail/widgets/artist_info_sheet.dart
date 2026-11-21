import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../../../core/theme/artist_artwork_scheme.dart';
import '../../../../core/theme/flutify_tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/artist.dart';
import '../../../../models/artist_overview.dart';
import '../../../widgets/cover_image.dart';

/// 包裹触发艺人信息页的源控件（如头图左侧的 `i` 按钮）：
/// 弹层以非线性弹簧形变展开时隐去源按钮本身，收回尾段再恢复。
class ArtistInfoSource extends StatefulWidget {
  final Widget child;

  const ArtistInfoSource({super.key, required this.child});

  @override
  State<ArtistInfoSource> createState() => _ArtistInfoSourceState();
}

class _ArtistInfoSourceState extends State<ArtistInfoSource> {
  final ValueNotifier<double> _opacity = ValueNotifier<double>(1.0);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: _opacity,
    child: widget.child,
    builder: (context, opacity, child) =>
        Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
  );
}

/// 艺人信息页非线性弹簧动效模型（Apple 流体卡片展开 / 收回）。
class ArtistInfoMotion {
  ArtistInfoMotion._();

  /// 展开弹簧：略快响应（~0.46s），临界阻尼无闪烁过冲。
  static final SpringDescription presentSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: _stiffness(0.46),
        ratio: 1,
      );

  /// 收回弹簧：更紧凑（~0.38s），支持继承手势下滑速度。
  static final SpringDescription dismissSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: _stiffness(0.38),
        ratio: 1,
      );

  static double _stiffness(double response) =>
      math.pow(2 * math.pi / response, 2).toDouble();

  static Simulation simulation({
    required double from,
    required double to,
    double velocity = 0,
  }) {
    final opening = to >= from;
    return SpringSimulation(
      opening ? presentSpring : dismissSpring,
      from,
      to,
      velocity,
      snapToEnd: true,
      tolerance: opening
          ? const Tolerance(distance: 0.002, velocity: 0.04)
          : const Tolerance(distance: 0.0008, velocity: 0.02),
    );
  }
}

/// 艺人信息弹窗（复刻 Apple Music 7.0 `ArtistInfoFragment` / `la.C5418r1`）：
/// 承载月听众数、粉丝数、流派标签与完整艺人简介，并从源按钮做多通道非线性形变弹出。
class ArtistInfoSheet {
  ArtistInfoSheet._();

  static Future<void> show(
    BuildContext context, {
    required SpotifyArtist artist,
    required ArtistOverview overview,
    required String imageUrl,
    required ArtistArtworkScheme scheme,
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
        center: overlay.size.center(Offset.zero),
        width: 48,
        height: 48,
      );
    }
    return navigator.push(
      ArtistInfoRoute(
        anchor: anchor,
        artist: artist,
        overview: overview,
        imageUrl: imageUrl,
        scheme: scheme,
        reduceMotion: context.reduceMotion,
        sourceOpacity: context
            .findAncestorStateOfType<_ArtistInfoSourceState>()
            ?._opacity,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
      ),
    );
  }
}

class ArtistInfoRoute extends PopupRoute<void> {
  final Rect anchor;
  final SpotifyArtist artist;
  final ArtistOverview overview;
  final String imageUrl;
  final ArtistArtworkScheme scheme;
  final bool reduceMotion;
  final ValueNotifier<double>? sourceOpacity;
  final CapturedThemes capturedThemes;

  _ArtistInfoSheetViewState? _view;
  double _dismissVelocity = 0;

  ArtistInfoRoute({
    required this.anchor,
    required this.artist,
    required this.overview,
    required this.imageUrl,
    required this.scheme,
    required this.capturedThemes,
    this.reduceMotion = false,
    this.sourceOpacity,
  });

  @override
  Duration get transitionDuration => reduceMotion
      ? const Duration(milliseconds: 160)
      : const Duration(milliseconds: 520);

  @override
  Duration get reverseTransitionDuration => reduceMotion
      ? const Duration(milliseconds: 140)
      : const Duration(milliseconds: 420);

  @override
  Color? get barrierColor => null;

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
    final view = _view;
    source.value = view == null || !view.mounted
        ? 0
        : view._lookFor(animation!).source;
  }

  @override
  TickerFuture didPush() {
    if (reduceMotion) return super.didPush();
    super.didPush();
    return controller!.animateWith(
      ArtistInfoMotion.simulation(from: controller!.value, to: 1),
    );
  }

  @override
  bool didPop(void result) {
    if (reduceMotion) return super.didPop(result);
    final velocity = _dismissVelocity;
    _dismissVelocity = 0;
    final popped = super.didPop(result);
    if (popped && controller!.value > 0) {
      controller!.animateBackWith(
        ArtistInfoMotion.simulation(
          from: controller!.value,
          to: 0,
          velocity: velocity,
        ),
      );
    }
    return popped;
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
  ) => capturedThemes.wrap(_ArtistInfoSheetView(route: this));
}

/// 单帧各通道的非线性插值状态。
class _InfoLook {
  final double w;
  final double h;
  final double shell;
  final double scrim;
  final double content;
  final double blur;
  final double scale;
  final double source;

  const _InfoLook({
    required this.w,
    required this.h,
    required this.shell,
    required this.scrim,
    required this.content,
    required this.blur,
    required this.scale,
    required this.source,
  });

  static const closed = _InfoLook(
    w: 0,
    h: 0,
    shell: 0,
    scrim: 0,
    content: 0,
    blur: 1,
    scale: 0.92,
    source: 1,
  );

  static double _in(double v, double a, double b, [Curve c = Curves.linear]) =>
      c.transform(((v - a) / (b - a)).clamp(0.0, 1.0));

  /// 展开：源圆钮隐去 → 横向先一步舒展、纵向紧随展开 → 内容在形变中后段去模糊浮现。
  static _InfoLook open(double v) {
    final shell = _in(v, 0, 0.10, Curves.easeOut);
    return _InfoLook(
      w: _in(v, 0, 0.78, const Cubic(0.22, 1.0, 0.36, 1.0)),
      h: _in(v, 0.04, 0.94, const Cubic(0.18, 0.92, 0.28, 1.0)),
      shell: shell,
      scrim: _in(v, 0, 0.85, Curves.easeOutCubic),
      content: _in(v, 0.22, 0.76, Curves.easeOut),
      blur: 1 - _in(v, 0.18, 0.86, Curves.easeOut),
      scale: lerpDouble(0.92, 1.0, _in(v, 0.14, 0.92, Curves.easeOutCubic))!,
      source: 1 - shell,
    );
  }

  /// 收回：内容先一步虚化淡出，外壳收拢回源圆钮，末段恢复源按钮。
  static _InfoLook close(_InfoLook from, double t) {
    double to(double a, double b, double start, double end, [Curve? c]) =>
        lerpDouble(a, b, _in(t, start, end, c ?? Curves.easeInOut))!;
    const collapse = Cubic(0.42, 0.0, 0.22, 1.0);
    return _InfoLook(
      content: to(from.content, 0, 0, 0.40, Curves.easeOut),
      blur: to(from.blur, 0.75, 0, 0.46),
      scale: to(from.scale, 0.92, 0, 0.84, Curves.easeInOutCubic),
      h: to(from.h, 0, 0.04, 0.86, collapse),
      w: to(from.w, 0, 0.12, 0.92, collapse),
      scrim: to(from.scrim, 0, 0, 0.88, Curves.easeInOut),
      shell: to(from.shell, 0, 0.76, 1.0),
      source: to(from.source, 1, 0.80, 1.0),
    );
  }
}

class _ArtistInfoSheetView extends StatefulWidget {
  final ArtistInfoRoute route;

  const _ArtistInfoSheetView({required this.route});

  @override
  State<_ArtistInfoSheetView> createState() => _ArtistInfoSheetViewState();
}

class _ArtistInfoSheetViewState extends State<_ArtistInfoSheetView>
    with SingleTickerProviderStateMixin {
  /// Apple Music 7.0 `la.C5418r1` 宽屏卡片尺寸（520 × 572）。
  static const double _wideWidth = 520;
  static const double _wideMaxHeight = 572;
  static const double _wideMargin = 48;
  static const double _phoneHorizontalInset = 10;

  late final AnimationController _dragReset;
  final ScrollController _scrollController = ScrollController();

  double _dragOffset = 0;
  Rect? _closingStartRect;
  _InfoLook? _closingFrom;
  double _closingAt = 1;
  _InfoLook _look = _InfoLook.closed;

  @override
  void initState() {
    super.initState();
    _dragReset = AnimationController.unbounded(vsync: this)
      ..addListener(() => setState(() => _dragOffset = _dragReset.value));
    widget.route._view = this;
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
    if (widget.route._view == this) widget.route._view = null;
    _dragReset.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  _InfoLook _lookFor(Animation<double> animation) {
    final v = animation.value.clamp(0.0, 1.0);
    if (widget.route.reduceMotion) {
      return _InfoLook(
        w: 1,
        h: 1,
        shell: v,
        scrim: v,
        content: v,
        blur: 0,
        scale: 1,
        source: v >= 1 ? 0 : 1 - v,
      );
    }
    final from = _closingFrom;
    if (from != null) {
      return _InfoLook.close(from, (1 - v / _closingAt).clamp(0.0, 1.0));
    }
    return _InfoLook.open(v);
  }

  Rect _targetRect(Size screen, EdgeInsets safe, bool wide) {
    if (wide) {
      final w = math.min(_wideWidth, screen.width - _wideMargin * 2);
      final h = math.min(
        _wideMaxHeight,
        math.max(320.0, screen.height - _wideMargin * 2),
      );
      return Rect.fromCenter(
        center: Offset(screen.width / 2, screen.height / 2),
        width: w,
        height: h,
      );
    }
    final top = math.max(safe.top + 44.0, screen.height * 0.11);
    final bottom = math.max(safe.bottom + 8.0, 10.0);
    final width = math.max(260.0, screen.width - _phoneHorizontalInset * 2);
    final height = math.max(280.0, screen.height - top - bottom);
    return Rect.fromLTWH(_phoneHorizontalInset, top, width, height);
  }

  void _onHeaderDragStart(DragStartDetails _) {
    _dragReset.stop();
  }

  void _onHeaderDragUpdate(DragUpdateDetails details) {
    final dy = details.primaryDelta ?? 0;
    setState(() {
      final next = _dragOffset + dy;
      // 向上拉施加高阻尼橡皮筋，向下拉施加柔和非线性阻尼
      _dragOffset = next >= 0 ? next * 0.92 : next * 0.22;
    });
  }

  void _onHeaderDragEnd(DragEndDetails details, Rect currentCard) {
    final vy = details.velocity.pixelsPerSecond.dy;
    if (_dragOffset > 92 || vy > 680) {
      _closingStartRect = currentCard;
      final span = math.max(240.0, currentCard.height);
      widget.route._dismissVelocity = -(vy / span).clamp(0.0, 4.5);
      Navigator.of(context).maybePop();
      return;
    }
    if (widget.route.reduceMotion) {
      setState(() => _dragOffset = 0);
      return;
    }
    _dragReset.value = _dragOffset;
    _dragReset.animateWith(
      SpringSimulation(
        ArtistInfoMotion.presentSpring,
        _dragOffset,
        0,
        vy * 0.5,
        snapToEnd: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final route = widget.route;
    final scheme = route.scheme;
    final themed = scheme.toThemeData(Theme.of(context));

    return Theme(
      data: themed,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screen = constraints.biggest;
          final safe = MediaQuery.paddingOf(context);
          final wide = screen.width >= 600;
          final baseTarget = _targetRect(screen, safe, wide);

          return AnimatedBuilder(
            animation: route.animation!,
            builder: (context, _) {
              final look = _look = _lookFor(route.animation!);
              final anchor = route.anchor;
              final d = anchor.shortestSide.clamp(32.0, 56.0);
              final origin = Rect.fromCenter(
                center: anchor.center,
                width: d,
                height: d,
              );

              // 下滑手势叠加在目标卡片上；若从下滑位置直接松手关闭，则从松手处平滑收拢回源圆钮
              final dragProgress = (_dragOffset.clamp(0.0, 320.0) / 320.0);
              final dragScale = 1.0 - dragProgress * 0.05;
              final draggedTarget = _closingStartRect ??
                  MatrixUtils.transformRect(
                    Matrix4.identity()
                      ..translateByDouble(baseTarget.center.dx, baseTarget.center.dy, 0, 1)
                      ..scaleByDouble(dragScale, dragScale, 1, 1)
                      ..translateByDouble(
                        -baseTarget.center.dx,
                        -baseTarget.center.dy + _dragOffset,
                        0,
                        1,
                      ),
                    baseTarget,
                  );

              final shell = Rect.fromLTRB(
                lerpDouble(origin.left, draggedTarget.left, look.w)!,
                lerpDouble(origin.top, draggedTarget.top, look.h)!,
                lerpDouble(origin.right, draggedTarget.right, look.w)!,
                lerpDouble(origin.bottom, draggedTarget.bottom, look.h)!,
              );
              final targetRadius = wide ? 28.0 : 32.0;
              final radius = math.min(
                lerpDouble(d / 2, targetRadius, math.min(look.w, look.h))!,
                shell.shortestSide / 2,
              );

              final effectiveScrim =
                  (look.scrim * (1.0 - dragProgress * 0.45)).clamp(0.0, 1.0);
              final interactive =
                  _closingFrom == null && look.content > 0.85;

              final contentAlignment = Alignment(
                ((anchor.center.dx - baseTarget.center.dx) /
                        math.max(1.0, baseTarget.width / 2))
                    .clamp(-1.0, 1.0),
                ((anchor.center.dy - baseTarget.center.dy) /
                        math.max(1.0, baseTarget.height / 2))
                    .clamp(-1.0, 1.0),
              );

              Widget inner = SizedBox(
                width: baseTarget.width,
                height: baseTarget.height,
                child: _buildSheetContent(
                  context,
                  wide: wide,
                  onDragStart: _onHeaderDragStart,
                  onDragUpdate: _onHeaderDragUpdate,
                  onDragEnd: (d) => _onHeaderDragEnd(d, draggedTarget),
                ),
              );

              inner = Transform.scale(
                alignment: contentAlignment,
                scale: look.scale,
                child: inner,
              );

              final blurSigma = look.blur * 10.0;
              final blurEnabled = blurSigma > 0.35 && !route.reduceMotion;
              inner = ImageFiltered(
                enabled: blurEnabled,
                imageFilter: ImageFilter.blur(
                  sigmaX: blurEnabled ? blurSigma : 0,
                  sigmaY: blurEnabled ? blurSigma : 0,
                ),
                child: inner,
              );

              Widget card = ClipRRect(
                key: const Key('artist-info-sheet'),
                borderRadius: BorderRadius.circular(radius),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.backgroundColor,
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                      width: 0.8,
                    ),
                  ),
                  child: IgnorePointer(
                    ignoring: !interactive,
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Positioned(
                          left: (shell.width - baseTarget.width) / 2,
                          top: 0,
                          width: baseTarget.width,
                          height: baseTarget.height,
                          child: Opacity(
                            opacity: look.content.clamp(0.0, 1.0),
                            child: inner,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );

              card = Opacity(
                opacity: look.shell.clamp(0.0, 1.0),
                child: card,
              );

              final shadowFactor =
                  (math.min(look.w, look.h) * look.shell).clamp(0.0, 1.0);

              return Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: 0.54 * effectiveScrim,
                      ),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: shell,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        boxShadow: [
                          if (shadowFactor > 0)
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: 0.45 * shadowFactor,
                              ),
                              blurRadius: 44,
                              offset: const Offset(0, 18),
                            ),
                        ],
                      ),
                      child: card,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSheetContent(
    BuildContext context, {
    required bool wide,
    required GestureDragStartCallback onDragStart,
    required GestureDragUpdateCallback onDragUpdate,
    required GestureDragEndCallback onDragEnd,
  }) {
    final l10n = context.l10n;
    final route = widget.route;
    final artist = route.artist;
    final overview = route.overview;
    final scheme = route.scheme;
    final hasImage = route.imageUrl.isNotEmpty;
    final headerHeight = hasImage ? (wide ? 210.0 : 228.0) : 96.0;

    final monthlyText = overview.monthlyListeners == null
        ? null
        : l10n.artistMonthlyListeners(
            Formatters.formatCompactNumber(l10n, overview.monthlyListeners),
          );
    final followersText = artist.followers == null
        ? null
        : l10n.followerCount(
            Formatters.formatCompactNumber(l10n, artist.followers),
          );
    final genres = artist.genres.where((g) => g.trim().isNotEmpty).toList();
    final bio = overview.biography.trim();

    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: l10n.shellAboutArtist,
        child: Stack(
          fit: StackFit.expand,
          children: [
            NotificationListener<OverscrollNotification>(
              onNotification: (notification) {
                if (!wide && notification.overscroll < 0) {
                  setState(() {
                    _dragOffset = (_dragOffset - notification.overscroll * 0.75)
                        .clamp(0.0, 420.0);
                  });
                }
                return false;
              },
              child: Listener(
                onPointerUp: (_) {
                  if (_dragOffset > 0) {
                    _onHeaderDragEnd(
                      DragEndDetails(primaryVelocity: 0),
                      Rect.fromLTWH(0, 0, _wideWidth, _wideMaxHeight),
                    );
                  }
                },
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  slivers: [
                    SliverToBoxAdapter(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: wide ? null : onDragStart,
                        onVerticalDragUpdate: wide ? null : onDragUpdate,
                        onVerticalDragEnd: wide ? null : onDragEnd,
                        child: SizedBox(
                          height: headerHeight,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (hasImage) ...[
                                CoverImage(
                                  url: route.imageUrl,
                                  placeholderIcon: Icons.person_rounded,
                                ),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  height: headerHeight * 0.72,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: scheme.heroGradientColors,
                                        stops: ArtistArtworkScheme
                                            .heroGradientStops,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              Positioned(
                                left: 20,
                                right: 64,
                                bottom: 12,
                                child: Text(
                                  artist.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: scheme.labelColor,
                                    fontSize: wide ? 30 : 28,
                                    fontWeight: FontWeight.w700,
                                    height: 1.14,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                      sliver: SliverList.list(
                        children: [
                          if (monthlyText != null || followersText != null) ...[
                            _StatsRow(
                              key: const Key('artist-info-stats'),
                              monthlyText: monthlyText,
                              followersText: followersText,
                              scheme: scheme,
                            ),
                            const SizedBox(height: 18),
                          ],
                          if (genres.isNotEmpty) ...[
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final genre in genres)
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: scheme.quaternaryFillColor,
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: scheme.spotlightBorderColor,
                                        width: 0.75,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      child: Text(
                                        genre,
                                        style: TextStyle(
                                          color: scheme.secondaryLabelColor,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 22),
                          ],
                          if (bio.isNotEmpty) ...[
                            Text(
                              l10n.artistAbout,
                              style: TextStyle(
                                color: scheme.labelColor,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              bio,
                              style: TextStyle(
                                color: scheme.labelColor.withValues(
                                  alpha: 0.90,
                                ),
                                fontSize: 15.5,
                                height: 1.58,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!wide)
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 38,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.34),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 14,
              right: 14,
              child: _CloseCircleButton(
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final String? monthlyText;
  final String? followersText;
  final ArtistArtworkScheme scheme;

  const _StatsRow({
    super.key,
    required this.monthlyText,
    required this.followersText,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      if (monthlyText != null)
        _StatCard(
          icon: Icons.headphones_rounded,
          text: monthlyText!,
          scheme: scheme,
        ),
      if (followersText != null)
        _StatCard(
          icon: Icons.people_alt_rounded,
          text: followersText!,
          scheme: scheme,
        ),
    ];
    if (cards.length == 1) return cards.single;
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 340) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [cards[0], const SizedBox(height: 10), cards[1]],
          );
        }
        return Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 12),
            Expanded(child: cards[1]),
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String text;
  final ArtistArtworkScheme scheme;

  const _StatCard({
    required this.icon,
    required this.text,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.spotlightCardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.spotlightBorderColor, width: 0.75),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.secondaryLabelColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.labelColor,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseCircleButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _CloseCircleButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.commonClose,
      child: Material(
        color: Colors.black.withValues(alpha: 0.36),
        shape: CircleBorder(
          side: BorderSide(
            color: Colors.white.withValues(alpha: 0.16),
            width: 0.8,
          ),
        ),
        child: InkWell(
          key: const Key('artist-info-close-button'),
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const SizedBox.square(
            dimension: 36,
            child: Icon(Icons.close_rounded, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
