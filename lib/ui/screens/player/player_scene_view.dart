import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playback_context.dart';
import '../../../models/track.dart';
import '../../../providers/connect_provider.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/lyrics_keep_awake.dart';
import '../../widgets/menu/desktop_menu.dart';
import '../../widgets/playback_scrubber.dart';
import 'android_player_scene.dart';
import 'immersive_lyrics_screen.dart';
import 'lyrics/glass_icon_button.dart';
import 'lyrics/lyrics_backdrop.dart';
import 'lyrics/lyrics_translation_controls.dart';
import 'lyrics/lyrics_view.dart';
import 'player_destinations_sheet.dart';
import 'player_expansion.dart';
import 'player_scene_chrome.dart';
import 'queue_list.dart';
import 'widgets/canvas_artwork.dart';
import 'widgets/swipeable_artwork.dart';

export 'player_scene_chrome.dart' show PlayerView;

/// 全端共用的播放器场景：封面 / 歌词 / 播放队列在同一套布局与动画里切换。
///
/// 竖屏（窄窗）与横屏（宽窗）由 [AndroidPlayerScene] 按尺寸选择布局，
/// 全屏播放器路由、桌面对话框与桌面沉浸式歌词页都使用它，只在外壳（顶栏、音量等）上有差异。
class PlayerSceneView extends StatefulWidget {
  const PlayerSceneView({
    super.key,
    required this.track,
    this.playbackContext,
    required this.remote,
    this.expansionAnimation,
    this.initialView = PlayerView.artwork,
    this.topBar,
    this.controlsFooter,
    this.maxLandscapeWidth = 960,
    this.immersiveEntry = true,
    this.fullBackdrop = false,
    this.lyricsLineCursor,
    this.controlsOnLeft = false,
    this.titleTrailing,
    this.activity,
    this.onControlsVisibleChanged,
    this.hideFooterWhenIdle = false,
    this.expandControlsOnArtworkTap = false,
    this.miniWhenIdle = false,
    this.devicesOpen,
    this.pinned = false,
    this.onPinnedChanged,
    this.initiallyExpanded = false,
  }) : assert(topBar != null || playbackContext != null);

  final SpotifyTrack track;

  /// 默认顶栏显示的播放来源；提供自定义 [topBar] 时可省略。
  final PlaybackContext? playbackContext;
  final bool remote;
  final Animation<double>? expansionAnimation;
  final PlayerView initialView;

  /// 替换默认顶栏（关闭、播放来源、更多）。它的高度决定场景顶部留白。
  final Widget? topBar;

  /// 播放按钮下方的附加行（例如桌面音量条），与进度条同宽对齐。
  final Widget? controlsFooter;

  /// 横屏时场景内容的最大宽度。
  final double maxLandscapeWidth;

  /// 是否在歌词工具栏提供「沉浸式歌词」入口（沉浸式页面自身不需要）。
  final bool immersiveEntry;

  /// 任何视图下都保持流动背景的完整效果（沉浸式页面始终展示歌词）。
  final bool fullBackdrop;

  /// 歌词行的鼠标光标；沉浸式页面传 [MouseCursor.defer] 以保留闲置隐藏光标。
  final MouseCursor? lyricsLineCursor;

  /// 横屏时控制卡片在左、歌词 / 封面 / 队列在右。
  final bool controlsOnLeft;

  /// 贴在歌名行红心按钮旁的额外操作，随控制区一起显示 / 隐藏；默认是「畅联」设备按钮（就地展开设备列表）。
  final Widget? titleTrailing;

  /// 宿主在场景之外绘制的按钮被悬停时触发，让控制区保持显示。
  final Listenable? activity;

  /// 控制区显示 / 隐藏状态变化时回调，宿主据此同步隐藏自己的浮动按钮。
  final ValueChanged<bool>? onControlsVisibleChanged;

  /// 静止时连底栏（设备 / 歌词 / 队列按钮）一起隐藏。
  final bool hideFooterWhenIdle;

  /// 横屏时点击卡片里的封面：放大 / 恢复控制区（而不是回到封面视图）。竖屏仍回到封面。
  final bool expandControlsOnArtworkTap;

  /// 控制区因静止收起时，在底部留一条迷你栏（封面、歌名、常用按钮，类似手机端）。
  final bool miniWhenIdle;

  /// 设备列表（畅联）的展开状态；宿主（例如顶部「⋯」菜单里的「畅联」）可借此控制它。省略则场景自管。
  final ValueNotifier<bool>? devicesOpen;

  /// 固定控制区：不再因静止而收成底部迷你栏。
  final bool pinned;

  /// 非空时在底栏提供「固定」按钮（横竖屏卡片视图均支持固定不收起），点击时回调新状态。
  final ValueChanged<bool>? onPinnedChanged;

  /// 横屏 + [controlsOnLeft] 时，一进来就是放大的控制卡片（大封面）。
  final bool initiallyExpanded;

  /// 展开 / 收起设备列表（同时刷新设备）。
  static void toggleDevices(BuildContext context, ValueNotifier<bool> open) {
    context.read<ConnectProvider?>()?.refresh();
    open.value = !open.value;
  }

  @override
  State<PlayerSceneView> createState() => _PlayerSceneViewState();
}

class _PlayerSceneViewState extends State<PlayerSceneView> {
  late PlayerView _view = widget.initialView;
  bool _destinationsOpen = false;
  bool _canvasPlaying = false;
  bool _hoveringArtwork = false;

  /// 控制卡片放大进度（0–1）：放大后卡片里的文字一起加大。
  final ValueNotifier<double> _expandN = ValueNotifier<double>(0);

  /// 设备列表（畅联）是否嵌在控制卡片底部展开，横竖屏都用它代替浮层。
  final ValueNotifier<bool> _ownDevicesOpen = ValueNotifier<bool>(false);
  ValueNotifier<bool> get _devicesOpen => widget.devicesOpen ?? _ownDevicesOpen;

  /// 迷你栏上的操作用它唤醒被收起的控制区。
  final ValueNotifier<int> _wake = ValueNotifier<int>(0);
  late final Listenable _sceneActivity = Listenable.merge([
    ?widget.activity,
    _wake,
  ]);

  @override
  void dispose() {
    _expandN.dispose();
    _ownDevicesOpen.dispose();
    _wake.dispose();
    super.dispose();
  }

  Object? _lyricsInputs;
  Widget? _lyricsView;

  /// 同一首歌、同一组参数时复用同一个歌词组件实例：固定按钮、切视图等让本组件重建时，
  /// Flutter 见到同一实例就跳过整首歌词的重建。
  Widget _lyrics() {
    final inputs = (widget.track, widget.remote, widget.lyricsLineCursor);
    if (_lyricsView != null && _lyricsInputs == inputs) return _lyricsView!;
    _lyricsInputs = inputs;
    return _lyricsView = LyricsKeepAwake(
      child: LyricsView(
        appleMusicStyle: true,
        key: ValueKey((widget.track.id, widget.remote)),
        track: widget.track,
        remote: widget.remote,
        bottomInset: 24,
        lineCursor: widget.lyricsLineCursor ?? SystemMouseCursors.click,
      ),
    );
  }

  Widget _scaled(Widget child, {double gain = 0.14}) =>
      PlayerSceneExpandScale(scale: _expandN, gain: gain, child: child);

  void _toggle(PlayerView view) =>
      setState(() => _view = _view == view ? PlayerView.artwork : view);

  Future<void> _showDestinations(BuildContext context) async {
    if (_destinationsOpen) return;
    setState(() => _destinationsOpen = true);
    try {
      await PlayerDestinationsSheet.show(context, widget.track);
    } finally {
      if (mounted) setState(() => _destinationsOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final remote = widget.remote;
    final expansion = widget.expansionAnimation;
    return GlassMenuScope(
      child: LyricsTranslationScope(
        child: AndroidPlayerScene(
        lyricsMode: _view == PlayerView.lyrics,
        queueMode: _view == PlayerView.queue,
        maxLandscapeWidth: widget.maxLandscapeWidth,
        controlsOnLeft: widget.controlsOnLeft,
        activity: _sceneActivity,
        onControlsVisibleChanged: (visible) {
          // 控制区收起时设备列表一并收起，迷你栏才不会被撑高
          if (!visible) _devicesOpen.value = false;
          widget.onControlsVisibleChanged?.call(visible);
        },
        hideFooterWhenIdle: widget.hideFooterWhenIdle,
        expandControlsOnArtworkTap: widget.expandControlsOnArtworkTap,
        expandOut: _expandN,
        pinned: widget.pinned,
        initiallyExpanded: widget.initiallyExpanded,
        idleMini: widget.miniWhenIdle
            ? PlayerSceneMiniBar(
                track: track,
                remote: remote,
                onDevices: () {
                  _devicesOpen.value = true;
                  _wake.value++;
                },
              )
            : null,
        onArtworkTap: () => setState(() => _view = PlayerView.artwork),
        interactionSuspended: _destinationsOpen,
        background: PlayerExpansionReveal(
          animation: expansion,
          rise: 0,
          // 迷你条颜色 → 播放页封面色：几乎整段行程都在渐变
          progress: PlayerExpansionMotion.backdrop,
          child: LyricsBackdrop(
            imageUrl: track.coverUrl,
            reducedEffects: !widget.fullBackdrop && _view != PlayerView.lyrics,
          ),
        ),
        // The same native texture keeps flowing across artwork/lyrics/queue.
        lyricsBackground: const SizedBox.expand(),
        topBar:
            widget.topBar ??
            PlayerExpansionReveal(
              animation: expansion,
              start: 0.04,
              rise: 0.25,
              child: PlayerSceneTopBar(
                track: track,
                playbackContext: widget.playbackContext!,
                onConnect: () =>
                    PlayerSceneView.toggleDevices(context, _devicesOpen),
                pin: !widget.controlsOnLeft &&
                        widget.onPinnedChanged != null &&
                        _view != PlayerView.artwork
                    ? PlayerScenePinButton(
                        pinned: widget.pinned,
                        onChanged: widget.onPinnedChanged!,
                      )
                    : null,
              ),
            ),
        titleBuilder: (context, progress) => PlayerExpansionReveal(
          animation: expansion,
          // 只放大歌名 / 歌手文字；按钮的说明文字（tooltip）保持正常大小
          child: PlayerSceneTitleRow(
            track: track,
            compact: true,
            lyricsProgress: progress,
            trailing: widget.titleTrailing,
            textScale: _expandN,
            textScaleGain: 0.6,
            onTap: _view != PlayerView.artwork
                ? () => _showDestinations(context)
                : null,
          ),
        ),
        controlsHeightReduction: remote
            ? 0
            : PlaybackScrubber.expandedLabelHeight(context) + 8,
        footerHeightReduction: 12,
        controlsBuilder: (context, progress) => PlayerExpansionReveal(
          animation: expansion,
          opacityKey: const ValueKey('player-expansion-controls'),
          child: _scaled(
            PlayerSceneControlsGroup(
              track: track,
              glass: false,
              remote: remote,
              showTitle: false,
              lyricsProgress: progress,
              footer: widget.controlsFooter,
            ),
          ),
        ),
        footerBuilder: (context, progress) => PlayerExpansionReveal(
          animation: expansion,
          child: PlayerSceneBottomBar(
            view: _view,
            onToggle: _toggle,
            lyricsProgress: progress,
            devicesOpen: _devicesOpen,
            pin: widget.controlsOnLeft && widget.onPinnedChanged != null
                ? PlayerScenePinButton(
                    pinned: widget.pinned,
                    onChanged: widget.onPinnedChanged!,
                  )
                : null,
            // 控制卡片在左时，翻译开关收进底栏（仅歌词视图），不再浮在歌词旁
            translation: widget.controlsOnLeft && _view == PlayerView.lyrics
                ? const LyricsTranslationToggle()
                : null,
          ),
        ),
        artworkBuilder: (context, size, progress) => PlayerArtworkHero(
          imageUrl: track.coverUrl,
          child: ValueListenableBuilder<double>(
            valueListenable: _expandN,
            builder: (context, expandVal, _) {
              // 无论是展开卡片内的大封面，还是取消歌词/队列后回到封面视图，
              // 都不自动播放 Canvas，而是在放大封面的右下角提供鼠标悬浮才显示的播放/停止 Canvas 按钮
              final isEnlarged = (progress == 0 && _view == PlayerView.artwork) ||
                  (widget.controlsOnLeft && expandVal > 0.5);
              final canvasActive = _canvasPlaying;
              return MouseRegion(
                onEnter: (_) {
                  if (!_hoveringArtwork) {
                    setState(() => _hoveringArtwork = true);
                  }
                },
                onExit: (_) {
                  if (_hoveringArtwork) {
                    setState(() => _hoveringArtwork = false);
                  }
                },
                child: ClipRRect(
                  borderRadius: context.tokens.radius(28 - 18 * progress),
                  child: SizedBox.square(
                    dimension: size,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        SwipeableArtwork(
                          url: track.coverUrl,
                          size: size,
                          child: canvasActive
                              ? TickerMode(
                                  // 只用于暂停/恢复 Canvas 视频（CanvasArtwork
                                  // 读它决定 active）；绝不能包在
                                  // SwipeableArtwork 外层，否则会冻结
                                  // 滑动回弹和换封面淡入动画
                                  enabled: isEnlarged,
                                  child: CanvasArtwork(
                                    track: track,
                                    size: size,
                                    remote: remote,
                                    borderRadius: BorderRadius.zero,
                                  ),
                                )
                              : CoverImage(
                                  url: track.coverUrl,
                                  size: size,
                                  cacheSize: 400,
                                  filterQuality: progress == 0
                                      ? FilterQuality.high
                                      : FilterQuality.medium,
                                  borderRadius: BorderRadius.zero,
                                ),
                        ),
                        if (isEnlarged)
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: AnimatedOpacity(
                              opacity: _hoveringArtwork ? 1.0 : 0.0,
                              duration: context.motion(
                                const Duration(milliseconds: 180),
                              ),
                              child: IgnorePointer(
                                ignoring: !_hoveringArtwork,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {},
                                  child: GlassIconButton(
                                    icon: _canvasPlaying
                                        ? Icons.motion_photos_pause_rounded
                                        : Icons.motion_photos_on_rounded,
                                    size: 38,
                                    selected: _canvasPlaying,
                                    tooltip: _canvasPlaying
                                        ? context.l10n.playerCanvasStop
                                        : context.l10n.playerCanvasPlay,
                                    onPressed: () => setState(
                                      () => _canvasPlaying = !_canvasPlaying,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        lyrics: _lyrics(),
        translation: widget.controlsOnLeft
            ? const SizedBox.shrink()
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LyricsTranslationButton(),
                  // 桌面对话框里额外提供沉浸式全屏歌词入口。
                  if (widget.immersiveEntry &&
                      MediaQuery.sizeOf(context).width >= 800) ...[
                    const SizedBox(width: 8),
                    GlassIconButton(
                      icon: Icons.open_in_full_rounded,
                      size: 36,
                      tooltip: context.l10n.lyricsImmersive,
                      onPressed: () => ImmersiveLyricsScreen.open(context),
                    ),
                  ],
                ],
              ),
        queue: const QueueList(horizontalPadding: 16),
      ),
      ),
    );
  }
}

