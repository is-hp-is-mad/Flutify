import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../l10n/model_labels.dart';
import '../../../models/playback_context.dart';
import '../../../models/track.dart';
import '../../../providers/connect_provider.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/connect/remote_progress.dart';
import '../../widgets/connect/remote_transport_controls.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/liquid_glass.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/playback_scrubber.dart';
import '../../widgets/player_controls.dart';
import '../../widgets/text_metrics.dart';
import '../../widgets/track_menu.dart';
import 'device_picker_sheet.dart';
import 'android_player_scene.dart';
import 'immersive_lyrics_screen.dart';
import 'lyrics/glass_icon_button.dart';
import 'lyrics/lyrics_backdrop.dart';
import 'lyrics/lyrics_view.dart';
import 'lyrics/lyrics_translation_controls.dart';
import 'queue_list.dart';
import 'player_destinations_sheet.dart';
import 'player_expansion.dart';
import 'player_lyrics_motion.dart';
import 'widgets/swipeable_artwork.dart';
import 'widgets/canvas_artwork.dart';

/// 中间区域显示的内容。
enum PlayerView { artwork, lyrics, queue }

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

  Widget _scaled(Widget child, {double gain = 0.14}) =>
      _ExpandScale(scale: _expandN, gain: gain, child: child);

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
    return LyricsTranslationScope(
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
            ? _MiniBar(
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
          start: 0,
          rise: 0,
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
              child: _TopBar(
                track: track,
                playbackContext: widget.playbackContext!,
                onConnect: () =>
                    PlayerSceneView.toggleDevices(context, _devicesOpen),
                pin: !widget.controlsOnLeft &&
                        widget.onPinnedChanged != null &&
                        _view != PlayerView.artwork
                    ? _PinButton(
                        pinned: widget.pinned,
                        onChanged: widget.onPinnedChanged!,
                      )
                    : null,
              ),
            ),
        titleBuilder: (context, progress) => PlayerExpansionReveal(
          animation: expansion,
          // 只放大歌名 / 歌手文字；按钮的说明文字（tooltip）保持正常大小
          child: _TitleRow(
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
            _ControlsGroup(
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
          child: _BottomBar(
            view: _view,
            onToggle: _toggle,
            lyricsProgress: progress,
            devicesOpen: _devicesOpen,
            pin: widget.controlsOnLeft && widget.onPinnedChanged != null
                ? _PinButton(
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
                        TickerMode(
                          enabled: canvasActive,
                          child: FittedBox(
                            child: SwipeableArtwork(
                              url: track.coverUrl,
                              size: 400,
                              child: canvasActive
                                  ? CanvasArtwork(
                                      track: track,
                                      size: 400,
                                      remote: remote,
                                      borderRadius: BorderRadius.zero,
                                    )
                                  : CoverImage(
                                      url: track.coverUrl,
                                      size: 400,
                                      borderRadius: BorderRadius.zero,
                                    ),
                            ),
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
                                        ? '停止 Canvas'
                                        : '播放 Canvas',
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
        lyrics: LyricsView(
          appleMusicStyle: true,
          key: ValueKey((track.id, remote)),
          track: track,
          remote: remote,
          bottomInset: 24,
          lineCursor: widget.lyricsLineCursor ?? SystemMouseCursors.click,
        ),
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
    );
  }
}

/// 歌名 + 进度条 + 播放控件；歌词视图下收进一块液态玻璃，歌词可从其上方滚过时仍清晰可读。
class _ControlsGroup extends StatelessWidget {
  final SpotifyTrack track;
  final bool glass;
  final bool remote;
  final bool showTitle;
  final double? lyricsProgress;
  final Widget? footer;

  const _ControlsGroup({
    required this.track,
    required this.glass,
    required this.remote,
    this.showTitle = true,
    this.lyricsProgress,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final compactness = lyricsProgress ?? 0.0;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle) _TitleRow(track: track),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: lerpDouble(16, 4, compactness)!,
          ),
          child: remote
              ? RemoteScrubber(
                  compact: false,
                  compactProgress: lyricsProgress,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  labelColor: Colors.white60,
                )
              : PlaybackScrubber(
                  compactProgress: lyricsProgress,
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  labelColor: Colors.white60,
                ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: lerpDouble(20, 8, compactness)!,
          ),
          child: remote
              ? const RemoteTransportControls(
                  showModes: true,
                  style: RemoteControlsStyle.glassFull,
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const ShuffleButton(),
                    const SkipButton(next: false),
                    PlayPauseButton(
                      size: lerpDouble(60, 52, compactness)!,
                      iconSize: lerpDouble(34, 44, compactness)!,
                      background: Colors.white.withValues(
                        alpha: 1 - compactness,
                      ),
                      foreground: Color.lerp(
                        Colors.black,
                        Colors.white,
                        compactness,
                      )!,
                      backgroundAnimationDuration: lyricsProgress == null
                          ? kThemeChangeDuration
                          : Duration.zero,
                    ),
                    const SkipButton(next: true),
                    const RepeatButton(),
                  ],
                ),
        ),
        if (footer != null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: lerpDouble(16, 4, compactness)!,
            ),
            child: footer,
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
    if (!glass) return content;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: LiquidGlass(
        borderRadius: context.tokens.radius(28),
        child: content,
      ),
    );
  }
}

/// 在系统 / 用户的文字缩放之上再叠加展开放大（而不是覆盖它）。
class _ExpandScale extends StatelessWidget {
  final ValueListenable<double> scale;
  final double gain;
  final Widget child;

  const _ExpandScale({
    required this.scale,
    required this.gain,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: scale,
    child: child,
    builder: (context, v, child) {
      final media = MediaQuery.of(context);
      final base = media.textScaler.scale(100) / 100;
      return MediaQuery(
        data: media.copyWith(
          textScaler: TextScaler.linear(base * (1 + gain * v)),
        ),
        child: child!,
      );
    },
  );
}

class _TopBar extends StatelessWidget {
  final SpotifyTrack track;
  final PlaybackContext playbackContext;
  final VoidCallback onConnect;
  final Widget? pin;

  const _TopBar({
    required this.track,
    required this.playbackContext,
    required this.onConnect,
    this.pin,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
            color: Colors.white,
            tooltip: context.l10n.commonClose,
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  context.l10n.playingFrom(playbackContext),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: Colors.white.withAlpha(180),
                  ),
                ),
                if (!playbackContext.isNone) ...[
                  const SizedBox(height: 2),
                  Text(
                    playbackContext.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          ?pin,
          Builder(
            // 独立 context：桌面对话框中菜单锚定在按钮下方
            builder: (buttonContext) => IconButton(
              icon: const Icon(Icons.more_vert_rounded, size: 22),
              color: Colors.white,
              tooltip: context.l10n.commonMoreOptions,
              onPressed: () =>
                  TrackMenu.show(buttonContext, track, onConnect: onConnect),
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  final SpotifyTrack track;
  final bool compact;
  final double lyricsProgress;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// 展开放大进度：只放大歌名 / 歌手文字，不影响按钮 tooltip。
  final ValueListenable<double>? textScale;
  final double textScaleGain;

  const _TitleRow({
    required this.track,
    this.compact = false,
    this.lyricsProgress = 0,
    this.onTap,
    this.trailing,
    this.textScale,
    this.textScaleGain = 0.14,
  });

  @override
  Widget build(BuildContext context) {
    Widget buildTitle(BuildContext context) {
      final theme = Theme.of(context);
      final titleStyle =
          theme.textTheme.titleLarge ?? const TextStyle(fontSize: 22);
      final baseSize = titleStyle.fontSize ?? 22;
      final titleSize = baseSize * (1 - 0.35 * lyricsProgress);
      final artist = Text(
        track.artistNames,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.white70,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reserve the unscaled line's measured height. Static text and the
          // marquee can use different line boxes, especially with large text.
          SizedBox(
            height: compact
                ? TextMetrics.lineHeight(
                    context,
                    titleStyle.copyWith(fontWeight: FontWeight.w800),
                  )
                : null,
            child: Align(
              alignment: Alignment.centerLeft,
              heightFactor: 1,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: compact
                    ? PlayerLyricsMotion.curve
                    : Curves.linear,
                switchOutCurve: compact
                    ? PlayerLyricsMotion.curve
                    : Curves.linear,
                child: MarqueeText(
                  text: track.name,
                  key: ValueKey(track.id),
                  style: titleStyle.copyWith(
                    fontSize: compact ? titleSize : null,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          MouseRegion(
            cursor: onTap == null && track.artists.isNotEmpty
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            child: GestureDetector(
              onTap: onTap != null || track.artists.isEmpty
                  ? null
                  : () => AppRoutes.openArtist(context, track.artists.first),
              child: artist,
            ),
          ),
        ],
      );
    }

    final title = textScale == null
        ? Builder(builder: buildTitle)
        : _ExpandScale(
            scale: textScale!,
            gain: textScaleGain,
            child: Builder(builder: buildTitle),
          );
    return Padding(
      padding: compact
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(24, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: compact
                ? Semantics(
                    button: onTap != null,
                    child: InkWell(
                      key: const ValueKey('player-card-title'),
                      onTap: onTap,
                      canRequestFocus: onTap != null,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          heightFactor: 1,
                          child: title,
                        ),
                      ),
                    ),
                  )
                : title,
          ),
          LikeButton(track: track, size: 28),
          ?trailing,
        ],
      ),
    );
  }
}

/// 底栏：Connect 设备 + 歌词 / 队列视图切换（当前视图高亮并带小圆点）。
class _BottomBar extends StatelessWidget {
  final PlayerView view;
  final ValueChanged<PlayerView> onToggle;
  final double? lyricsProgress;
  final Widget? translation;
  final Widget? pin;
  /// 非空时设备入口在卡片底部就地展开设备列表，而不是弹出浮层。
  final ValueNotifier<bool>? devicesOpen;

  const _BottomBar({
    required this.view,
    required this.onToggle,
    this.lyricsProgress,
    this.translation,
    this.pin,
    this.devicesOpen,
  });

  @override
  Widget build(BuildContext context) {
    final deviceName = context.select<ConnectProvider?, String?>(
      (c) => (c?.hasRemoteSession ?? false) ? c?.activeDevice?.name : null,
    );
    final primary = Theme.of(context).colorScheme.primary;
    final deviceColor = deviceName != null ? primary : Colors.white70;

    Widget toggle(PlayerView target, IconData icon, String tooltip) {
      final active = view == target;
      return IconButton(
        tooltip: tooltip,
        isSelected: active,
        onPressed: () => onToggle(target),
        icon: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Icon(icon, color: active ? primary : Colors.white70, size: 22),
            if (active)
              Positioned(
                bottom: -7,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    final bar = Padding(
      padding: EdgeInsets.lerp(
        const EdgeInsets.fromLTRB(20, 4, 12, 8),
        const EdgeInsets.symmetric(horizontal: 8),
        lyricsProgress ?? 0,
      )!,
      child: Row(
        children: [
          Expanded(
            // Only the icon/label is a device action. The remaining footer
            // space belongs to the scene's card-reveal gesture.
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              // 设备入口做成小胶囊按钮，文字缩小以便在窄卡片里放下
              child: InkWell(
                borderRadius: context.tokens.pill,
                mouseCursor: SystemMouseCursors.click,
                onTap: devicesOpen == null
                    ? () => DevicePickerSheet.show(context)
                    : () {
                        context.read<ConnectProvider?>()?.refresh();
                        devicesOpen!.value = !devicesOpen!.value;
                      },
                child: ConstrainedBox(
                  // 点击区域保持 48 高，视觉上只是个小胶囊
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        borderRadius: context.tokens.pill,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6.0,
                          horizontal: 10.0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.devices_rounded,
                              size: 14,
                              color: deviceColor,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                deviceName ?? context.l10n.playerThisDevice,
                                style: TextStyle(
                                  color: deviceColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 10,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
          ?pin,
          ?translation,
          toggle(
            PlayerView.lyrics,
            Icons.lyrics_outlined,
            context.l10n.lyricsTitle,
          ),
          toggle(
            PlayerView.queue,
            Icons.queue_music_rounded,
            context.l10n.queueTitle,
          ),
        ],
      ),
    );
    final open = devicesOpen;
    if (open == null) return bar;
    return ValueListenableBuilder<bool>(
      valueListenable: open,
      child: bar,
      builder: (context, isOpen, bar) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bar!,
          // 设备列表放在底栏下面，正好对应左下角的「正在本设备收听」按钮
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: isOpen
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: InlineDevicePanel(onClose: () => open.value = false),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// 底栏里的「固定控制区」开关：固定后控制卡片不再因静止收起成底部迷你栏。
class _PinButton extends StatelessWidget {
  final bool pinned;
  final ValueChanged<bool> onChanged;

  const _PinButton({required this.pinned, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: pinned
          ? context.l10n.lyricsUnpinControls
          : context.l10n.lyricsPinControls,
      isSelected: pinned,
      onPressed: () => onChanged(!pinned),
      icon: Icon(
        pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        color: pinned ? primary : Colors.white70,
        size: 22,
      ),
    );
  }
}

/// 控制区收起后留在底部的迷你栏（仅横屏）：封面、歌名 / 歌手、喜欢、设备（畅联）、播放暂停、下一首。
class _MiniBar extends StatelessWidget {
  final SpotifyTrack track;
  final bool remote;
  final VoidCallback onDevices;

  const _MiniBar({
    required this.track,
    required this.remote,
    required this.onDevices,
  });

  static const _remoteStyle = RemoteControlsStyle(
    foreground: Colors.white,
    muted: Colors.white60,
    playBackground: Colors.white,
    playForeground: Colors.black,
    skipSize: 24,
    playSize: 34,
    playIconSize: 20,
    gap: 0,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceActive = context.select<ConnectProvider?, bool>(
      (c) => c?.hasRemoteSession ?? false,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          CoverImage(
            url: track.coverUrl,
            size: 34,
            borderRadius: BorderRadius.circular(7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  track.artistNames,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          LikeButton(track: track, size: 20),
          IconButton(
            tooltip: context.l10n.deviceConnectShort,
            visualDensity: VisualDensity.compact,
            onPressed: onDevices,
            icon: Icon(
              Icons.devices_rounded,
              size: 19,
              color: deviceActive ? theme.colorScheme.primary : Colors.white70,
            ),
          ),
          if (remote)
            const RemoteTransportControls(showModes: false, style: _remoteStyle)
          else ...[
            const PlayPauseButton(size: 34, iconSize: 20),
            const SkipButton(
              next: true,
              size: 24,
              constraints: BoxConstraints.tightFor(width: 32, height: 32),
            ),
          ],
        ],
      ),
    );
  }
}
