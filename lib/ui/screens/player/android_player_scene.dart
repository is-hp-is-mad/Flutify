import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../widgets/liquid_glass.dart';
import 'player_lyrics_layout.dart';
import 'player_lyrics_motion.dart';

/// Android-only composition. Each slot keeps its identity as its bounds move;
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

  bool get _cardMode => widget.lyricsMode || widget.queueMode;

  @override
  void initState() {
    super.initState();
    _motion = PlayerLyricsController(vsync: this);
    _queueMounted = widget.queueMode;
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_releasePointer);
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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
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
    onPointerSignal: (_) => _motion.activity(),
    child: MouseRegion(
      onHover: (_) => _motion.activity(),
      child: AnimatedBuilder(
        animation: _motion,
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
          return Stack(
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
              SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth:
                          MediaQuery.orientationOf(context) ==
                              Orientation.landscape
                          ? 960
                          : 480,
                    ),
                    child: ClipRect(
                      child: CustomMultiChildLayout(
                        delegate: PlayerLyricsLayout(
                          progress: progress,
                          chrome: _motion.chrome.value,
                          geometry: _geometry,
                          lyricsProgress: lyricsProgress,
                          queueProgress: queueProgress,
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
                              offstage: !widget.queueMode && queueProgress == 0,
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
                                    key: const ValueKey('lyrics-control-card'),
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
                                widget.titleBuilder?.call(context, progress) ??
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
                            _cardHitRegion(
                              widget.footerBuilder?.call(context, progress) ??
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
                                  onTap: _cardMode ? widget.onArtworkTap : null,
                                  onVerticalDragUpdate: _cardMode
                                      ? (_) {}
                                      : null,
                                  child: IgnorePointer(
                                    ignoring:
                                        widget.lyricsMode || widget.queueMode,
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
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
