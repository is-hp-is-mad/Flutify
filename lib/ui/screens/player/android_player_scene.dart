import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../widgets/liquid_glass.dart';
import 'player_lyrics_layout.dart';
import 'player_lyrics_motion.dart';

/// Shared player composition for every platform. Each slot keeps its identity as its bounds move;
/// playback and translation remain owned by the existing player widgets.
class AndroidPlayerScene extends StatefulWidget {
  const AndroidPlayerScene({
    super.key,
    required this.lyricsMode,
    required this.queueMode,
    required this.background,
    required this.lyricsBackground,
    required this.topBar,
    this.title,
    this.titleBuilder,
    this.controls,
    this.controlsBuilder,
    this.footer,
    this.footerBuilder,
    this.controlsHeightReduction = 0,
    this.footerHeightReduction = 0,
    required this.artworkBuilder,
    required this.lyrics,
    required this.translation,
    required this.queue,
    this.onArtworkTap,
    this.interactionSuspended = false,
    this.maxLandscapeWidth = 960,
    this.controlsOnLeft = false,
    this.activity,
    this.onControlsVisibleChanged,
    this.hideFooterWhenIdle = false,
    this.expandControlsOnArtworkTap = false,
    this.idleMini,
    this.expandOut,
    this.pinned = false,
    this.initiallyExpanded = false,
  }) : assert((title == null) != (titleBuilder == null)),
       assert((controls == null) != (controlsBuilder == null)),
       assert((footer == null) != (footerBuilder == null));

  final bool lyricsMode;
  final bool queueMode;
  final Widget background;
  final Widget lyricsBackground;
  final Widget topBar;

  final Widget? title;

  /// Alternative to [title], using the artwork's already-eased progress (0–1).
  final Widget Function(BuildContext context, double progress)? titleBuilder;
  final Widget? controls;
  final Widget Function(BuildContext context, double progress)? controlsBuilder;
  final Widget? footer;
  final Widget Function(BuildContext context, double progress)? footerBuilder;

  /// Expanded minus compact height, keeping flight endpoints fixed while
  /// controls reflow. Builders must interpolate their heights with progress.
  final double controlsHeightReduction;
  final double footerHeightReduction;
  final Widget Function(BuildContext context, double size, double progress)
  artworkBuilder;
  final Widget lyrics;
  final Widget translation;
  final Widget queue;
  final VoidCallback? onArtworkTap;
  final bool interactionSuspended;

  /// Content width cap when the scene is laid out in landscape.
  final double maxLandscapeWidth;

  /// Landscape only: controls card on the left, lyrics / artwork / queue on the right.
  final bool controlsOnLeft;

  /// External pointer activity (e.g. hovering a button the host draws above the
  /// scene) that keeps the controls awake without tapping into this scene.
  final Listenable? activity;

  /// Reports whether the auto-hiding chrome is currently shown, so a host can
  /// hide its own floating buttons together with the scene's controls.
  final ValueChanged<bool>? onControlsVisibleChanged;

  /// Also hide the footer (device / lyrics / queue buttons) while idle.
  final bool hideFooterWhenIdle;

  /// Landscape + [controlsOnLeft]: tapping the card's cover enlarges / restores
  /// the controls card instead of returning to the artwork view.
  final bool expandControlsOnArtworkTap;

  /// Compact bar (cover, title, a few buttons) shown in the footer while the
  /// controls card is folded away by inactivity; replaces the hidden footer.
  final Widget? idleMini;

  /// Mirrors the controls-card expansion (0–1) so the host can scale text.
  final ValueNotifier<double>? expandOut;

  /// 固定控制区：不自动收起成底部迷你栏。
  final bool pinned;

  /// 横屏 + [controlsOnLeft] 时，一进来就是放大的控制卡片（大封面）。
  final bool initiallyExpanded;
  @override
  State<AndroidPlayerScene> createState() => _AndroidPlayerSceneState();
}

class _AndroidPlayerSceneState extends State<AndroidPlayerScene>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final PlayerLyricsController _motion;
  final PlayerLyricsGeometry _geometry = PlayerLyricsGeometry();
  bool _tickerEnabled = true;
  bool _appActive = true;
  bool _queueMounted = false;
  bool? _reportedVisible;
  Offset? _lastHover;
  final GlobalKey _miniKey = GlobalKey();
  late final AnimationController _expand;
  bool _expanded = false;
  bool _initialExpandDone = false;
  bool get _cardMode => widget.lyricsMode || widget.queueMode;

  @override
  void initState() {
    super.initState();
    _motion = PlayerLyricsController(vsync: this);
    _expand = AnimationController(vsync: this);
    _expand.addListener(_publishExpand);
    _queueMounted = widget.queueMode;
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_releasePointer);
    widget.activity?.addListener(_externalActivity);
    _motion.addListener(_reportChrome);
    _motion.setPinned(widget.pinned);
  }

  void _toggleExpand() {
    _expanded = !_expanded;
    _motion.activity();
    _expand.animateTo(
      _expanded ? 1 : 0,
      duration: context.motion(PlayerLyricsMotion.foldDuration),
      curve: PlayerLyricsMotion.foldCurve,
    );
  }

  void _externalActivity() => _motion.activity();

  void _publishExpand() => widget.expandOut?.value = _expand.value;

  // The controller notifies from inside build (setView); defer the host callback.
  void _reportChrome() {
    final visible = _motion.controlsVisible;
    if (visible == (_reportedVisible ?? true)) return;
    _reportedVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onControlsVisibleChanged?.call(visible);
    });
  }

  // Hover events can be re-sent while the content under a still cursor moves
  // (auto-scrolling lyrics); only real pointer movement counts as activity.
  void _hover(PointerHoverEvent event) {
    if (event.position == _lastHover) return;
    _lastHover = event.position;
    // A still-folded mini bar stays folded while the pointer is on it, so its
    // buttons can be clicked without the card unfolding underneath the cursor.
    if (widget.idleMini != null && !_motion.controlsVisible) {
      final box = _miniKey.currentContext?.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        final local = box.globalToLocal(event.position);
        if ((Offset.zero & box.size).contains(local)) return;
      }
    }
    _motion.passiveActivity();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion.configure(
      reduceMotion: context.reduceMotion,
      accessibleNavigation: MediaQuery.accessibleNavigationOf(context),
    );
    _motion.setView(lyrics: widget.lyricsMode, queue: widget.queueMode);
    _motion.setInteractionSuspended(widget.interactionSuspended);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _motion.setActive(_appActive && _tickerEnabled);
  }

  @override
  void didUpdateWidget(AndroidPlayerScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    _queueMounted = _queueMounted || widget.queueMode;
    _motion.setView(lyrics: widget.lyricsMode, queue: widget.queueMode);
    _motion.setInteractionSuspended(widget.interactionSuspended);
    _motion.setPinned(widget.pinned);
    if (!_cardMode && _expanded) {
      _expanded = false;
      _expand.animateTo(
        0,
        duration: PlayerLyricsMotion.foldDuration,
        curve: PlayerLyricsMotion.foldCurve,
      );
    }
    if (oldWidget.activity != widget.activity) {
      oldWidget.activity?.removeListener(_externalActivity);
      widget.activity?.addListener(_externalActivity);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop: an unfocused window reports `inactive` while still on screen,
    // and the controls must keep auto-hiding there. On mobile `inactive` is a
    // real interruption (call, system sheet) and still pauses the timer.
    final desktop = const {
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);
    _appActive =
        state == AppLifecycleState.resumed ||
        (desktop && state == AppLifecycleState.inactive);
    _motion.setActive(_appActive && _tickerEnabled);
  }

  void _releasePointer(PointerEvent event) {
    // A reveal, modal, or route transition may change the original hit tree.
    // Complete only pointers this scene enrolled, even if local up is lost.
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _motion.pointerUp(event.pointer);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.activity?.removeListener(_externalActivity);
    _motion.removeListener(_reportChrome);
    _expand.dispose();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_releasePointer);
    _motion.dispose();
    super.dispose();
  }

  Widget _chrome(Widget child, {double factor = 1}) => ExcludeFocus(
    excluding: !_motion.controlsVisible || factor == 0,
    child: ExcludeSemantics(
      excluding: !_motion.controlsVisible || factor == 0,
      child: IgnorePointer(
        ignoring: !_motion.controlsVisible || factor == 0,
        child: Opacity(opacity: _motion.chrome.value * factor, child: child),
      ),
    ),
  );

  Widget _cardHitRegion(Widget child) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: _cardMode ? _motion.activity : null,
    onVerticalDragUpdate: _cardMode ? (_) {} : null,
    child: child,
  );

  Widget _body(PlayerSceneSlot slot, Widget child) => ExcludeFocus(
    excluding: !_motion.controlsVisible,
    child: ExcludeSemantics(
      excluding: !_motion.controlsVisible,
      child: IgnorePointer(
        ignoring: !_motion.controlsVisible,
        child: ClipRect(
          clipper: PlayerCardBodyClipper(geometry: _geometry, slot: slot),
          child: child,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) => _motion.pointerDown(event.pointer),
    onPointerMove: (event) => _motion.pointerMove(event.pointer, event.delta),
    onPointerUp: (event) => _motion.pointerUp(event.pointer),
    onPointerCancel: (event) => _motion.pointerUp(event.pointer),
    onPointerSignal: (_) => _motion.passiveActivity(),
    child: MouseRegion(
      onHover: _hover,
      child: AnimatedBuilder(
        animation: Listenable.merge([_motion, _expand]),
        builder: (context, _) {
          final progress = _motion.transition.value;
          final lyricsProgress = _motion.lyricsProgress;
          final queueProgress = _motion.queueTransition.value;
          final hasLyrics = widget.lyricsMode || lyricsProgress > 0;
          // Neither pane owns gestures/accessibility during the crossfade:
          // a tap on an outgoing row must not play or seek the incoming pane.
          final lyricsInteractive = widget.lyricsMode && lyricsProgress == 1;
          final queueInteractive = widget.queueMode && queueProgress == 1;
          Widget slot(PlayerSceneSlot id, Widget child) =>
              LayoutId(id: id, child: child);
          final background = Stack(
            fit: StackFit.expand,
            children: [
              widget.background,
              if (hasLyrics)
                IgnorePointer(
                  child: Opacity(
                    key: const ValueKey('lyrics-background-blend'),
                    opacity: lyricsProgress,
                    child: widget.lyricsBackground,
                  ),
                ),
            ],
          );
          return _withBackground(
            context,
            background,
            SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  // 与 PlayerLyricsLayout 的横屏判定一致：封顶后的宽度 >= 600 且大于高度，
                  // 否则按竖屏限宽（不再依赖整窗的 MediaQuery 方向，避免宽窗口走了竖屏布局却不限宽）
                  final capped = math.min(
                    box.maxWidth,
                    widget.maxLandscapeWidth,
                  );
                  final landscape = capped >= 600 && capped > box.maxHeight;
                  // 收起后的迷你栏只用于横屏；竖屏直接整体收起
                  final idleMini = landscape && widget.controlsOnLeft
                      ? widget.idleMini
                      : null;
                  if (widget.initiallyExpanded &&
                      !_initialExpandDone &&
                      landscape &&
                      widget.controlsOnLeft &&
                      _cardMode) {
                    _initialExpandDone = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || _expanded) return;
                      _expanded = true;
                      _expand.value = 1;
                    });
                  }
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: landscape ? widget.maxLandscapeWidth : 480,
                      ),
                      child: ClipRect(
                        child: CustomMultiChildLayout(
                          delegate: PlayerLyricsLayout(
                            progress: progress,
                            chrome: _motion.chrome.value,
                            geometry: _geometry,
                            lyricsProgress: lyricsProgress,
                            queueProgress: queueProgress,
                            controlsOnLeft: widget.controlsOnLeft,
                            expand: _expand.value * _motion.chrome.value,
                            controlsHeightReduction:
                                widget.controlsHeightReduction,
                            footerHeightReduction: widget.footerHeightReduction,
                          ),
                          children: [
                            if (hasLyrics)
                              slot(
                                PlayerSceneSlot.lyrics,
                                ExcludeFocus(
                                  excluding: !lyricsInteractive,
                                  child: ExcludeSemantics(
                                    excluding: !lyricsInteractive,
                                    child: IgnorePointer(
                                      ignoring: !lyricsInteractive,
                                      child: Opacity(
                                        opacity: lyricsProgress,
                                        child: widget.lyrics,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            slot(
                              PlayerSceneSlot.queue,
                              Offstage(
                                offstage:
                                    !widget.queueMode && queueProgress == 0,
                                child: TickerMode(
                                  enabled: widget.queueMode,
                                  child: ExcludeFocus(
                                    excluding: !queueInteractive,
                                    child: ExcludeSemantics(
                                      excluding: !queueInteractive,
                                      child: IgnorePointer(
                                        ignoring: !queueInteractive,
                                        child: Opacity(
                                          key: const ValueKey(
                                            'player-queue-opacity',
                                          ),
                                          opacity: queueProgress,
                                          child: _queueMounted
                                              ? widget.queue
                                              : const SizedBox.expand(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            slot(
                              PlayerSceneSlot.surface,
                              IgnorePointer(
                                ignoring: progress == 0,
                                child: Opacity(
                                  opacity: progress,
                                  child: _cardHitRegion(
                                    LiquidGlass(
                                      key: const ValueKey(
                                        'lyrics-control-card',
                                      ),
                                      borderRadius: context.tokens.radius(28),
                                      child: const ColoredBox(
                                        color: Color(0x59101216),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            slot(
                              PlayerSceneSlot.title,
                              _body(
                                PlayerSceneSlot.title,
                                _cardHitRegion(
                                  widget.titleBuilder?.call(
                                        context,
                                        progress,
                                      ) ??
                                      widget.title!,
                                ),
                              ),
                            ),
                            slot(
                              PlayerSceneSlot.controls,
                              _body(
                                PlayerSceneSlot.controls,
                                _cardHitRegion(
                                  widget.controlsBuilder?.call(
                                        context,
                                        progress,
                                      ) ??
                                      widget.controls!,
                                ),
                              ),
                            ),
                            slot(
                              PlayerSceneSlot.footer,
                              idleMini != null
                                  ? Stack(
                                      children: [
                                        _chrome(
                                          _cardHitRegion(
                                            widget.footerBuilder?.call(
                                                  context,
                                                  progress,
                                                ) ??
                                                widget.footer!,
                                          ),
                                        ),
                                        // 控制区完全显示时不挂载迷你栏，避免重复的歌名文字
                                        if (!_motion.controlsVisible ||
                                            _motion.chrome.value < 1)
                                          Positioned.fill(
                                            child: ExcludeFocus(
                                              excluding:
                                                  _motion.controlsVisible,
                                              child: ExcludeSemantics(
                                                excluding:
                                                    _motion.controlsVisible,
                                                child: IgnorePointer(
                                                  ignoring:
                                                      _motion.controlsVisible,
                                                  child: Opacity(
                                                    key: _miniKey,
                                                    opacity:
                                                        (1 -
                                                            _motion
                                                                .chrome
                                                                .value) *
                                                        progress,
                                                    // The folded pill is exactly the footer rect.
                                                    child: Center(
                                                      child: idleMini,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    )
                                  : widget.hideFooterWhenIdle
                                  ? _chrome(
                                      _cardHitRegion(
                                        widget.footerBuilder?.call(
                                              context,
                                              progress,
                                            ) ??
                                            widget.footer!,
                                      ),
                                    )
                                  : _cardHitRegion(
                                      widget.footerBuilder?.call(
                                            context,
                                            progress,
                                          ) ??
                                          widget.footer!,
                                    ),
                            ),
                            slot(
                              PlayerSceneSlot.artwork,
                              _body(
                                PlayerSceneSlot.artwork,
                                Semantics(
                                  label: _cardMode
                                      ? MaterialLocalizations.of(
                                          context,
                                        ).backButtonTooltip
                                      : null,
                                  button:
                                      _cardMode && widget.onArtworkTap != null,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _cardMode
                                        ? (widget.expandControlsOnArtworkTap &&
                                                  landscape &&
                                                  widget.controlsOnLeft
                                              ? _toggleExpand
                                              : widget.onArtworkTap)
                                        : null,
                                    onVerticalDragUpdate: _cardMode
                                        ? (_) {}
                                        : null,
                                    child: IgnorePointer(
                                      ignoring:
                                          (widget.lyricsMode ||
                                              widget.queueMode) &&
                                          !(widget.controlsOnLeft && landscape),
                                      child: ExcludeSemantics(
                                        excluding: _cardMode,
                                        child: LayoutBuilder(
                                          builder: (context, box) =>
                                              widget.artworkBuilder(
                                                context,
                                                box.maxWidth,
                                                progress,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            slot(
                              PlayerSceneSlot.toolbar,
                              ExcludeFocus(
                                excluding: !lyricsInteractive,
                                child: ExcludeSemantics(
                                  excluding: !lyricsInteractive,
                                  child: IgnorePointer(
                                    ignoring: !lyricsInteractive,
                                    child: _chrome(
                                      widget.translation,
                                      factor: lyricsProgress,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            slot(PlayerSceneSlot.top, widget.topBar),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    ),
  );

  /// 材质为「柔光玻璃」时把整个背景（封面流动背景 + 歌词背景）作为 [HyperGlassScene]
  /// 的采样源，其上的 LiquidGlass 控件就会画成真正的柔光玻璃；省电模式不建场景。
  Widget _withBackground(
    BuildContext context,
    Widget background,
    Widget foreground,
  ) {
    final tokens = context.tokens;
    if (tokens.hyperMaterial && !tokens.powerSaving) {
      // 背景是已做 σ70 大模糊的流动封面，没有细节：按 1/4 分辨率截取（像素量 1/16），
      // 玻璃折射看起来一样，每帧的截图与采样开销大幅下降
      return HyperGlassScene(
        background: background,
        captureScale: 0.25,
        child: foreground,
      );
    }
    return Stack(fit: StackFit.expand, children: [background, foreground]);
  }
}
