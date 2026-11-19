import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/theme/md3e_shapes.dart';
import '../../widgets/cover_image.dart';

/// 迷你条 ↔ 播放页的运动模型（Apple Music 参考，见
/// docs/apple-music-player-and-more-motion-analysis-and-plan.md §3、§7.2–7.4）。
///
/// 全部通道只读一个进度 `P∈[0,1]`（= 路由控制器的 value，0 = 迷你条，1 = 播放页），
/// 不再有 CurvedAnimation / Hero 各自的时间线：
///
/// - 外壳就是迷你条本身：P=0 时与迷你条同位置、同圆角、同材质，之后向四周长大，
///   而不是从屏幕底部另升起一张面板；
/// - 上沿随 P 线性地从迷你条上沿走到屏幕顶（拖动时手指 1:1）；
/// - 两侧、下沿、圆角先在 `[0, morphEnd]` 内长成一张四角圆角、四周留边的悬浮卡片
///   （AM 展开逐帧图：卡片一路保持留边与圆角），再在 `[settleStart, 1]` 内贴满屏幕；
/// - 播放页内容钉在卡片上沿、随卡片宽度等比缩放，被卡片下沿裁切，而不是原地淡入；
/// - P 本身由弹簧驱动（展开/收回各一组），释放时继承手指速度；
///   其余通道都是 P 的非线性函数，透明度通道不会过冲。
///
/// 标记：除 MarqueeView/sheet 结构外，这里的数值都是 **[E] 工程候选**，
/// 由 `light-expand/collapse` 逐帧图对照得到，不是 Apple 私有参数原值。
/// AM 的收回是「全宽下滑、到底才收成胶囊」，与展开不对称；这里收回沿展开的原路返回，
/// 这样拖动与中途掉头时外形不跳变。
class PlayerExpansionMotion {
  PlayerExpansionMotion._();

  /// 只在关闭动效时作为路由时长使用（弹簧接管后路由不看它）。
  static const duration = Duration(milliseconds: 600);
  static const reverseDuration = Duration(milliseconds: 480);

  /// 迷你条出现/消失（AnimatedSize）仍用这条无过冲曲线。
  static const curve = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 形变段：P 从 0 到它，迷你条长成悬浮卡片（两侧、下沿、圆角）。[E]
  static const double morphEnd = 0.5;

  /// 贴边段：P 从它到 1，卡片的留边与圆角收到 0，贴满屏幕。[E]
  static const double settleStart = 0.6;

  /// 悬浮卡片与屏幕两侧、底边的留边（迷你条本来更贴边时取迷你条的）。[E]
  static const double cardInset = 8;

  /// 悬浮卡片的圆角（接近 iPhone 屏幕圆角）；完全展开时回到 0。[E]
  static const double sheetRadius = 36;

  /// 卡片悬浮时投在底层页面上的阴影（最浓时的不透明度）。[E]
  static const double cardShadow = 0.3;

  /// 展开弹簧：临界阻尼、response≈0.46 s（逐帧图：约 0.2 s 走完大部分行程）。[E]
  static final SpringDescription presentSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: _stiffness(0.46),
        ratio: 1,
      );

  /// 收回弹簧：response≈0.36 s，临界阻尼（透明度通道不能过冲，且在 0.59s 内平稳落入亚像素容差）。[E]
  static final SpringDescription dismissSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: _stiffness(0.36),
        ratio: 1,
      );

  static double _stiffness(double response) =>
      math.pow(2 * math.pi / response, 2).toDouble();

  /// 从 [from] 弹到 [to]，[velocity] 单位为 P/秒。终点精确吸附，避免停在 0.9996。
  ///
  /// - 展开到 1 时：[morph]=1、[float] 在终点斜率为 0，保持 `distance: 0.002` 让页面在 ~0.62s 及时解锁交互；
  /// - 收回到 0 时：P=1 对应 ~700dp 行程，收紧容差到 `0.0004`（< 0.3dp）配合 [morph] 软着陆脚趾段，
  ///   消除胶囊末帧从 +2.6dp（~8px）突然坍缩到静止高度的顿挫抖动，同时总时长仍保持在 ~0.59s。
  static Simulation simulation({
    required double from,
    required double to,
    double velocity = 0,
  }) {
    final expanding = to >= from;
    return SpringSimulation(
      expanding ? presentSpring : dismissSpring,
      from,
      to,
      velocity,
      snapToEnd: true,
      tolerance: expanding
          ? const Tolerance(distance: 0.002, velocity: 0.05)
          : const Tolerance(distance: 0.0004, velocity: 0.015),
    );
  }

  /// 松手后去展开还是收回：按速度投影 0.18 s 后的位置判断，快甩直接决定方向。
  /// [velocity] 单位为 P/秒（向上展开为正）。[E] 可替换的释放规则。
  ///
  /// [opening] 为 true 时是从迷你条往上拉：越过 1/4 就展开；否则是从播放页往下拉：
  /// 拉下 1/4 就收回。两侧都只需要一小段行程，和 sheet 的手感一致。
  static bool shouldExpand(
    double progress,
    double velocity, {
    bool opening = false,
  }) {
    if (velocity > 1.2) return true;
    if (velocity < -1.2) return false;
    final projected = progress + velocity * 0.18;
    return opening ? projected >= 0.25 : projected >= 0.75;
  }

  /// 形变段进度 s∈[0,1]：P≥[morphEnd] 时为 1。起步快，且在贴近 P=0 的最后几像素做零斜率软着陆，
  /// 避免 [Curves.easeOutCubic] 在 P=0 处的 6× 斜率把残余尾段放大成底栏高度与宽度的末帧急刹。
  static double morph(double p) {
    final u = (p / morphEnd).clamp(0.0, 1.0);
    const toeK = 0.015;
    final toe = (u / (u + toeK)) * (1 + toeK);
    return Curves.easeOutCubic.transform(u) * toe;
  }

  /// 悬浮程度 f∈[0,1]：P≤[settleStart] 时为 1（留边、圆角俱全），P=1 时为 0（贴满屏幕）。
  static double float(double p) =>
      1 -
      Curves.easeInOut.transform(
        ((p - settleStart) / (1 - settleStart)).clamp(0.0, 1.0),
      );

  /// 外壳几何：上沿线性；两侧、下沿、圆角先长成悬浮卡片，再贴满屏幕。
  ///
  /// 对任意 [source]（展开的宽迷你条、折叠后停在两个圆钮之间的窄迷你条）都从它的 rect 出发，
  /// 四条边各自单调，P=0 时正好是迷你条，P=1 时正好是整屏。
  static ({Rect bounds, double radius, double morph, double float}) geometry(
    double p,
    Rect source,
    Size size,
    double sourceRadius,
  ) {
    final s = morph(p);
    final f = float(p);
    // 每条边到屏幕边的留边：迷你条的 → 卡片的 → 0
    double inset(double from) =>
        lerpDouble(from, math.min(from, cardInset), s)! * f;
    final bounds = Rect.fromLTRB(
      inset(source.left),
      lerpDouble(source.top, 0, p)!,
      size.width - inset(size.width - source.right),
      size.height - inset(size.height - source.bottom),
    );
    final radius = lerpDouble(sourceRadius, sheetRadius, s)! * f;
    return (bounds: bounds, radius: radius, morph: s, float: f);
  }

  /// 卡片阴影的浓度：离开迷你条时渐显，贴满屏幕时渐隐。
  static double shadow(double p) => cardShadow * morph(p) * float(p);

  /// 迷你条那一行（歌名/按钮）的不透明度。
  ///
  /// 收回时外壳走到一半（P≈0.5）就开始在上沿出现，P≤[compactSettled] 时完全显出，
  /// 外壳落回迷你条时文字正好在迷你条上；展开时同样在前半程退场。[E]
  static double compactOpacity(double p) =>
      1 -
      Curves.easeInOut.transform(
        ((p - compactSettled) / (compactFadeEnd - compactSettled)).clamp(
          0.0,
          1.0,
        ),
      );

  /// 迷你条那一行从这里开始退场（展开）/ 开始出现（收回）。
  static const double compactFadeEnd = 0.5;

  /// 迷你条那一行在这里以下完全不透明。
  static const double compactSettled = 0.14;

  /// 播放页各块内容的显现：外壳过半后才出现，和迷你条那一行错开，[start] 越大越晚。
  static double reveal(double p, [double start = 0]) {
    final from = (0.42 + start * 0.4).clamp(0.0, 0.95);
    return Curves.easeOut.transform(((p - from) / (1 - from)).clamp(0.0, 1.0));
  }

  /// 播放页背景（封面色）的显现：几乎占满整个行程，迷你条颜色与播放页颜色平滑渐变。[E]
  static double backdrop(double p) =>
      Curves.easeInOut.transform((p / 0.75).clamp(0.0, 1.0));

  /// 封面飞行进度：整个行程都在走，迷你条封面一路飞到播放页封面的位置，
  /// 而不是在底部先放大再被外壳带上去。[E]
  static double artwork(double p) => _artworkCurve.transform(p);

  static const Curve _artworkCurve = Cubic(0.3, 0.1, 0.25, 1);

  /// 柔光玻璃迷你条：封面色在 P∈[0, 此值] 内从透明渐变到不透明，
  /// 外壳从玻璃一路渐变成封面色（收回时反过来露出玻璃）。[E]
  static const double dissolveEnd = 0.34;

  /// 当前播放页的呈现进度（底层页面缩放、变暗读这个）。没有播放页时为 0。
  static final ValueNotifier<double> presentation = ValueNotifier(0);
}

/// What the pill looks like: its surface colour and the compact row that fades
/// back in while the full-screen player collapses into it.
typedef PlayerExpansionLook = ({Color color, Widget compactChild});

/// 迷你条自己的材质（柔光玻璃）：[surface] 在任意大小的盒子里画出同一种材质，
/// [row] 是静止时迷你条上的那一行（不含封面，文字颜色与迷你条上的一致）。
///
/// 有了它，外壳在 P=0 时就是迷你条本身，真正的迷你条在播放页存在期间整个隐藏；
/// 外壳长大的同时材质渐变成封面色，那一行渐变成封面色上的白字。
typedef PlayerPillMaterial = ({
  Widget Function(BuildContext context, BorderRadius radius) surface,
  Widget row,
});

class PlayerExpansionOrigin {
  const PlayerExpansionOrigin({
    required this.bounds,
    required this.color,
    required this.borderRadius,
    required this.compactChild,
    this.restartTitles,
    this.currentBounds,
    this.currentBorderRadius,
    this.currentLook,
    this.currentMaterial,
    this.artworkRect,
    this.setArtworkHidden,
    this.translucent = false,
  });

  final Rect bounds;

  /// The pill's colour and compact row at the moment the player opened.
  final Color color;
  final BorderRadius borderRadius;
  final Widget compactChild;
  final VoidCallback? restartTitles;

  /// 迷你条此刻的实时位置与圆角（悬浮底栏下沉弹簧等仍在运动时不再落回打开瞬间的旧快照）。
  final Rect? Function()? currentBounds;
  final BorderRadius? Function()? currentBorderRadius;

  /// Reads what the pill looks like right now. The track can change while the
  /// full-screen player covers the pill, so the collapse must land on the
  /// current track rather than the snapshot taken when the route was pushed.
  final PlayerExpansionLook Function()? currentLook;

  /// 迷你条此刻的材质；不透明的迷你条、或迷你条不在时为 null。
  final PlayerPillMaterial? Function()? currentMaterial;

  /// 迷你条封面此刻的位置（Navigator 坐标）与地址；迷你条不在时为 null。
  final ({Rect rect, String imageUrl})? Function()? artworkRect;

  /// 播放页在上面时隐藏迷你条里的封面：飞行中的封面就是它本身。
  /// 迷你条给了 [PlayerPillMaterial] 时整条一起隐藏：外壳就是它本身。
  final ValueChanged<bool>? setArtworkHidden;

  /// The pill is see-through glass: the artwork colour must dissolve in over it near the pill instead of
  /// landing as a solid bar that turns to glass when the route ends.
  final bool translucent;

  Rect get liveBounds => currentBounds?.call() ?? bounds;

  BorderRadius get liveBorderRadius =>
      currentBorderRadius?.call() ?? borderRadius;

  PlayerExpansionLook get look =>
      currentLook?.call() ?? (color: color, compactChild: compactChild);

  PlayerPillMaterial? get material => currentMaterial?.call();
}

class PlayerExpansionSource extends StatefulWidget {
  const PlayerExpansionSource({
    super.key,
    required this.color,
    required this.borderRadius,
    required this.compactChild,
    required this.child,
    this.translucent = false,
    this.material,
  });

  final Color color;
  final BorderRadius borderRadius;
  final Widget compactChild;
  final Widget child;

  /// See [PlayerExpansionOrigin.translucent].
  final bool translucent;

  /// See [PlayerPillMaterial].
  final PlayerPillMaterial? material;

  static final _sources = Expando<_PlayerExpansionSourceState>();
  static final _artworkHidden = Expando<ValueNotifier<bool>>();

  static ValueNotifier<bool> _hiddenFor(NavigatorState navigator) =>
      _artworkHidden[navigator] ??= ValueNotifier(false);

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
    final navigatorBox = navigator.context.findRenderObject();
    final bounds =
        box.localToGlobal(Offset.zero, ancestor: navigatorBox) & box.size;
    final color = source.widget.color;
    final compactChild = source.widget.compactChild;
    return PlayerExpansionOrigin(
      bounds: bounds,
      color: color,
      borderRadius: source.widget.borderRadius,
      compactChild: compactChild,
      restartTitles: () => _sources[navigator]?._restartTitles(),
      translucent: source.widget.translucent,
      setArtworkHidden: (hidden) => _hiddenFor(navigator).value = hidden,
      currentBounds: () {
        final live = _sources[navigator];
        if (live == null || !live._active || !navigator.mounted) return null;
        final liveBox = live.context.findRenderObject();
        final navBox = navigator.context.findRenderObject();
        if (liveBox is! RenderBox ||
            !liveBox.attached ||
            !liveBox.hasSize ||
            navBox is! RenderBox ||
            !navBox.attached) {
          return null;
        }
        return MatrixUtils.transformRect(
          liveBox.getTransformTo(navBox),
          Offset.zero & liveBox.size,
        );
      },
      currentBorderRadius: () {
        final live = _sources[navigator];
        return live == null || !live._active ? null : live.widget.borderRadius;
      },
      artworkRect: () {
        final art = _sources[navigator]?._artwork;
        if (art == null || !art._active || !navigator.mounted) return null;
        final artBox = art.context.findRenderObject();
        final navBox = navigator.context.findRenderObject();
        if (artBox is! RenderBox ||
            !artBox.attached ||
            !artBox.hasSize ||
            navBox is! RenderBox) {
          return null;
        }
        return (
          rect: MatrixUtils.transformRect(
            artBox.getTransformTo(navBox),
            Offset.zero & artBox.size,
          ),
          imageUrl: art.widget.imageUrl,
        );
      },
      currentMaterial: () {
        final live = _sources[navigator];
        return live == null || !live._active ? null : live.widget.material;
      },
      currentLook: () {
        // Look the source up again: it is rebuilt with the new track, and may
        // even be replaced (local <-> remote mini player) while the route is up.
        final live = _sources[navigator];
        if (live == null || !live._active) {
          return (color: color, compactChild: compactChild);
        }
        return (
          color: live.widget.color,
          compactChild: live.widget.compactChild,
        );
      },
    );
  }

  @override
  State<PlayerExpansionSource> createState() => _PlayerExpansionSourceState();
}

class _PlayerExpansionSourceState extends State<PlayerExpansionSource> {
  bool _active = true;
  NavigatorState? _navigator;
  int _titleRevision = 0;
  _PlayerArtworkHeroState? _artwork;

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
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _active = false;
    if (_navigator != null &&
        PlayerExpansionSource._sources[_navigator!] == this) {
      PlayerExpansionSource._sources[_navigator!] = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放页在上方时暂停迷你条内部的 Ticker（如歌名跑马灯），并在有玻璃材质时将真身隐藏
    // （外壳在 P=0 时画的就是这条迷你条；真身仍占位、仍接手势）。
    final child = ValueListenableBuilder<bool>(
      valueListenable: PlayerExpansionSource._hiddenFor(_navigator!),
      child: widget.child,
      builder: (context, hidden, child) => TickerMode(
        enabled: !hidden,
        child: widget.material != null
            ? Opacity(opacity: hidden ? 0 : 1, child: child)
            : child!,
      ),
    );
    return _MiniPlayerTitleScope(
      source: this,
      revision: _titleRevision,
      child: child,
    );
  }
}

class _MiniPlayerTitleScope extends InheritedWidget {
  const _MiniPlayerTitleScope({
    required this.source,
    required this.revision,
    required super.child,
  });

  final _PlayerExpansionSourceState source;
  final int revision;

  @override
  bool updateShouldNotify(_MiniPlayerTitleScope oldWidget) =>
      revision != oldWidget.revision;
}

/// 播放页一侧：把飞行状态传给页面里的 [PlayerArtworkHero]。
class _PlayerExpansionScope extends InheritedWidget {
  const _PlayerExpansionScope({
    required this.transition,
    required this.artworkHidden,
    required super.child,
  });

  final _PlayerExpansionTransitionState transition;
  final bool artworkHidden;

  @override
  bool updateShouldNotify(_PlayerExpansionScope oldWidget) =>
      artworkHidden != oldWidget.artworkHidden;
}

/// 播放页外壳：迷你条 rect → 全屏，圆角、裁切、封面、两层内容都从同一个 P 计算。
///
/// 可选的拖动回调挂在外壳本身（路由 IgnorePointer 之外），因此收回途中也能重新抓住。
class PlayerExpansionTransition extends StatefulWidget {
  const PlayerExpansionTransition({
    super.key,
    required this.animation,
    required this.origin,
    required this.child,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final Animation<double> animation;
  final PlayerExpansionOrigin? origin;
  final Widget child;

  final VoidCallback? onDragStart;

  /// 纵向位移（像素，向下为正）。
  final ValueChanged<double>? onDragUpdate;

  /// 松手速度（像素/秒，向下为正）。
  final ValueChanged<double>? onDragEnd;

  @override
  State<PlayerExpansionTransition> createState() =>
      _PlayerExpansionTransitionState();
}

class _PlayerExpansionTransitionState extends State<PlayerExpansionTransition> {
  final _contentKey = GlobalKey();
  _PlayerArtworkHeroState? _target;

  void _handleAnimationStatus(AnimationStatus status) {
    // 标题跑马灯在落回迷你条之后才重新开始，不在收回刚开始时不确定地重启。
    if (status == AnimationStatus.dismissed) {
      widget.origin?.restartTitles?.call();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_handleAnimationStatus);
  }

  @override
  void didUpdateWidget(PlayerExpansionTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_handleAnimationStatus);
      widget.animation.addStatusListener(_handleAnimationStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleAnimationStatus);
    super.dispose();
  }

  /// 播放页封面在内容自身坐标系里的位置（不含外壳平移）。上一帧的布局；静止时稳定。
  ({Rect rect, String imageUrl})? _targetArtwork() {
    final target = _target;
    final content = _contentKey.currentContext?.findRenderObject();
    if (target == null || !target._active || content is! RenderBox) {
      return null;
    }
    final box = target.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return (
      rect: MatrixUtils.transformRect(
        box.getTransformTo(content),
        Offset.zero & box.size,
      ),
      imageUrl: target.widget.imageUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    final targetCorner = context.tokens.corner(MD3EShapes.radiusExtraLarge);
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: widget.animation,
        child: widget.child,
        builder: (context, child) =>
            _frame(constraints.biggest, child!, reduceMotion, targetCorner),
      ),
    );
  }

  Widget _frame(
    Size size,
    Widget child,
    bool reduceMotion,
    double targetCorner,
  ) {
    final origin = widget.origin;
    final p = widget.animation.value.clamp(0.0, 1.0);
    // 读每一帧：收回要落在此刻正在播放的曲目与实时胶囊位置上，而不是打开时的快照。
    final look = origin?.look;
    final material = origin?.material;
    final sourceBounds = origin?.liveBounds;
    final sourceRadius = origin?.liveBorderRadius;

    late final Rect bounds;
    late final double radius;
    if (origin == null || sourceBounds == null || sourceRadius == null) {
      // 迷你条不在（远程切换、已卸载）：不伪造一个固定胶囊，整页从底部升起。
      bounds = Offset(0, size.height * (1 - p)) & size;
      radius = PlayerExpansionMotion.sheetRadius * (1 - p);
    } else {
      final g = PlayerExpansionMotion.geometry(
        p,
        sourceBounds,
        size,
        sourceRadius.topLeft.x,
      );
      bounds = g.bounds;
      radius = g.radius;
    }
    // 播放页按整屏布局，钉在卡片左上角、随卡片宽度等比缩放：卡片留边时内容不被两侧裁掉。
    final scale = size.width <= 0 ? 1.0 : bounds.width / size.width;

    // 封面飞行：迷你条封面 → 播放页封面（随外壳平移、缩放后的位置），走完整个行程。
    // 通过排在 [surface] 之后的 [LayoutBuilder] 在当帧布局回调中读取 [_targetArtwork]，
    // 确保打开第 0 帧（包括上滑跟手第 0 帧）即拿到真实目标矩形，无 1 帧滞后与缩略图跳变。
    final from = origin?.artworkRect?.call();
    final flying = !reduceMotion && from != null && p < 0.999;
    Widget? flight;
    if (flying) {
      final a = PlayerExpansionMotion.artwork(p);
      final maxTargetCorner = targetCorner * scale;
      flight = LayoutBuilder(
        builder: (context, _) {
          final to = _targetArtwork();
          final end = to == null
              ? null
              : Rect.fromLTWH(
                  bounds.left + to.rect.left * scale,
                  bounds.top + to.rect.top * scale,
                  to.rect.width * scale,
                  to.rect.height * scale,
                );
          final rect = end == null ? from.rect : Rect.lerp(from.rect, end, a)!;
          final endRadius = end == null
              ? from.rect.shortestSide / 2
              : math.min(maxTargetCorner, end.shortestSide / 2);
          final cornerRadius = lerpDouble(
            from.rect.shortestSide / 2,
            endRadius,
            a,
          )!;
          final url = to?.imageUrl ?? from.imageUrl;
          return CustomSingleChildLayout(
            delegate: _ArtworkFlightDelegate(rect),
            child: IgnorePointer(
              child: Opacity(
                opacity: end == null ? 1 - a : 1,
                child: ClipRRect(
                  key: const ValueKey('player-artwork-flight'),
                  borderRadius: BorderRadius.circular(cornerRadius),
                  child: CoverImage(
                    url: url,
                    size: math.max(rect.width, 1),
                    cacheSize: 400,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    // 玻璃迷你条：外壳起点是玻璃，封面色在 [0, dissolveEnd] 内盖上去。
    final translucent = origin?.translucent == true;
    final tint = translucent
        ? Curves.easeInOut.transform(
            (p / PlayerExpansionMotion.dissolveEnd).clamp(0.0, 1.0),
          )
        : 1.0;
    Widget color = ColoredBox(color: look?.color ?? const Color(0xFF3A3A42));
    if (translucent) {
      color = Opacity(
        key: const ValueKey('player-expansion-dissolve'),
        opacity: tint,
        child: color,
      );
    }

    final compactOpacity = origin == null
        ? 0.0
        : PlayerExpansionMotion.compactOpacity(p);
    Widget? row;
    if (look != null && compactOpacity > 0) {
      // 有玻璃材质时那一行从迷你条上的样子渐变成封面色上的白字；
      // 没有时真正的迷你条还在底下，这一行跟着封面色一起显出，避免两行字叠在一起。
      row = material == null
          ? look.compactChild
          : Stack(
              fit: StackFit.expand,
              children: [
                if (tint < 1)
                  Opacity(
                    key: const ValueKey('player-expansion-resting-row'),
                    opacity: 1 - tint,
                    child: material.row,
                  ),
                Opacity(
                  key: const ValueKey('player-expansion-tinted-row'),
                  opacity: tint,
                  child: look.compactChild,
                ),
              ],
            );
    }
    // 完全展开贴满整屏且圆角归零时，旁路 ClipPath 抗锯齿路径裁剪；同时不用 RepaintBoundary
    // 包裹含 BackdropGroup 的整屏播放页，避免高分屏非整数逻辑像素下离屏光栅化导致封面与文字发虚。
    final settled = bounds == (Offset.zero & size) && radius <= 0.001;
    final surface = ClipPath(
      key: const ValueKey('player-expansion-surface'),
      clipBehavior: settled ? Clip.none : Clip.antiAlias,
      clipper: _PlayerSurfaceClipper(bounds, BorderRadius.circular(radius)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          color,
          Transform.translate(
            offset: bounds.topLeft,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox.expand(
                key: _contentKey,
                child: _PlayerExpansionScope(
                  transition: this,
                  artworkHidden: flying,
                  child: child,
                ),
              ),
            ),
          ),
          if (row != null && sourceBounds != null)
            Positioned(
              // 横向固定在迷你条的位置：落下时文字正好对上迷你条
              left: sourceBounds.left,
              top: bounds.top - 12 * (1 - compactOpacity),
              width: sourceBounds.width,
              height: sourceBounds.height,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Opacity(
                    key: const ValueKey('player-expansion-compact'),
                    opacity: material == null
                        ? compactOpacity * tint
                        : compactOpacity,
                    child: row,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // 玻璃材质自身已带 ViewShadow，卡片阴影随封面色溶解进度渐入，避免在 P→0 附近双层阴影叠加跳变。
    final shadow = origin == null
        ? 0.0
        : PlayerExpansionMotion.shadow(p) * (material != null ? tint : 1.0);
    final shell = Stack(
      fit: StackFit.expand,
      children: [
        if (shadow > 0)
          IgnorePointer(
            key: const ValueKey('player-expansion-shadow'),
            child: CustomPaint(
              painter: _CardShadowPainter(bounds, radius, shadow),
            ),
          ),
        if (material != null && tint < 1)
          Positioned.fromRect(
            key: const ValueKey('player-expansion-material'),
            rect: bounds,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: material.surface(context, BorderRadius.circular(radius)),
              ),
            ),
          ),
        surface,
        ?flight,
      ],
    );
    if (widget.onDragUpdate == null) return shell;
    return GestureDetector(
      key: const ValueKey('player-expansion-drag'),
      behavior: HitTestBehavior.deferToChild,
      onVerticalDragStart: (_) => widget.onDragStart?.call(),
      onVerticalDragUpdate: (d) => widget.onDragUpdate?.call(d.delta.dy),
      onVerticalDragEnd: (d) => widget.onDragEnd?.call(d.primaryVelocity ?? 0),
      onVerticalDragCancel: () => widget.onDragEnd?.call(0),
      child: shell,
    );
  }
}

class _ArtworkFlightDelegate extends SingleChildLayoutDelegate {
  const _ArtworkFlightDelegate(this.rect);

  final Rect rect;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tight(rect.size);

  @override
  Offset getPositionForChild(Size size, Size childSize) => rect.topLeft;

  @override
  bool shouldRelayout(_ArtworkFlightDelegate oldDelegate) =>
      rect != oldDelegate.rect;
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

/// 悬浮卡片投在底层页面上的阴影。只画卡片之外的部分：卡片本身可能还是半透明的玻璃。
class _CardShadowPainter extends CustomPainter {
  const _CardShadowPainter(this.bounds, this.radius, this.opacity);

  final Rect bounds;
  final double radius;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final card = RRect.fromRectAndRadius(bounds, Radius.circular(radius));
    canvas
      ..save()
      ..clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addRRect(card),
      )
      ..drawRRect(
        card.shift(const Offset(0, 8)),
        Paint()
          ..color = Colors.black.withValues(alpha: opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_CardShadowPainter oldDelegate) =>
      bounds != oldDelegate.bounds ||
      radius != oldDelegate.radius ||
      opacity != oldDelegate.opacity;
}

/// 播放页里随形变段显现的一块内容。内容本身已随外壳平移、缩放，这里只补一点错位上浮与淡入。
class PlayerExpansionReveal extends StatelessWidget {
  const PlayerExpansionReveal({
    super.key,
    required this.animation,
    required this.child,
    this.start = 0.14,
    this.rise = 0.85,
    this.opacityKey,
    this.progress,
  });

  final Animation<double>? animation;
  final Widget child;
  final double start;
  final double rise;
  final Key? opacityKey;

  /// 自定义显现进度（默认 [PlayerExpansionMotion.reveal]），例如背景用
  /// [PlayerExpansionMotion.backdrop] 做整段颜色渐变。
  final double Function(double p)? progress;

  @override
  Widget build(BuildContext context) {
    final animation = this.animation;
    if (animation == null) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final p = animation.value.clamp(0.0, 1.0);
        final progress =
            this.progress?.call(p) ?? PlayerExpansionMotion.reveal(p, start);
        return IgnorePointer(
          ignoring: p < 1,
          child: Opacity(
            key: opacityKey,
            opacity: progress,
            child: FractionalTranslation(
              translation: Offset(0, rise * 0.3 * (1 - progress)),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 迷你条与播放页中的封面。飞行由 [PlayerExpansionTransition] 按同一个 P 绘制；
/// 这个组件只负责登记自己的位置，并在飞行时把真身藏起来，避免出现两张封面。
class PlayerArtworkHero extends StatefulWidget {
  const PlayerArtworkHero({
    super.key,
    required this.imageUrl,
    required this.child,
  });

  final String imageUrl;
  final Widget child;

  @override
  State<PlayerArtworkHero> createState() => _PlayerArtworkHeroState();
}

class _PlayerArtworkHeroState extends State<PlayerArtworkHero> {
  /// 元素在树里（deactivate 后、重新挂上前不能读它的 RenderObject）。
  bool _active = true;
  _PlayerExpansionTransitionState? _transition;
  _PlayerExpansionSourceState? _source;
  ValueNotifier<bool>? _sourceHidden;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _unregister();
    final scope = context
        .dependOnInheritedWidgetOfExactType<_PlayerExpansionScope>();
    if (scope != null) {
      _transition = scope.transition.._target = this;
      return;
    }
    final source = context
        .getInheritedWidgetOfExactType<_MiniPlayerTitleScope>()
        ?.source;
    if (source != null) {
      _source = source.._artwork = this;
      _sourceHidden = PlayerExpansionSource._hiddenFor(
        Navigator.of(context, rootNavigator: true),
      );
    }
  }

  void _unregister() {
    if (_transition?._target == this) _transition!._target = null;
    if (_source?._artwork == this) _source!._artwork = null;
    _transition = null;
    _source = null;
    _sourceHidden = null;
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _active = false;
    _unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_transition != null) {
      final hidden =
          context
              .dependOnInheritedWidgetOfExactType<_PlayerExpansionScope>()
              ?.artworkHidden ??
          false;
      return Opacity(opacity: hidden ? 0 : 1, child: widget.child);
    }
    final sourceHidden = _sourceHidden;
    if (sourceHidden == null) return widget.child;
    return ValueListenableBuilder<bool>(
      valueListenable: sourceHidden,
      child: widget.child,
      builder: (context, hidden, child) =>
          Opacity(opacity: hidden ? 0 : 1, child: child),
    );
  }
}
