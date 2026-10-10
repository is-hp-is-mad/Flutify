import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/theme/md3e_colors.dart';
import '../../../core/theme/system_bars.dart';
import '../../../l10n/l10n.dart';
import '../../../models/track.dart';
import '../../../providers/connect_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/playback_provider.dart';
import '../../../services/storage_service.dart';
import '../../navigation/app_routes.dart';
import '../../shell/desktop/desktop_window.dart';
import '../../shell/desktop/window_caption_buttons.dart';
import '../../widgets/connect/now_playing_source.dart';
import '../../widgets/connect/playback_shortcuts.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/liquid_glass.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/menu/desktop_menu.dart';
import '../../widgets/toast/app_toast.dart';
import '../../widgets/track_menu.dart';
import 'lyrics/lyrics_backdrop.dart';
import 'lyrics/lyrics_glass_controls.dart';
import 'lyrics/lyrics_view.dart';
import 'lyrics/lyrics_translation_controls.dart';
import 'queue_list.dart';

/// 右侧面板显示的内容：歌词、播放队列，或都不显示（封面与控制区居中）。
enum _Panel { lyrics, queue, none }

/// Apple 风格的非线性曲线：起步干脆、收尾极其柔和（iOS 面板 / 布局过渡同款）。
const Curve _appleCurve = Cubic(0.32, 0.72, 0, 1);

/// 布局切换（面板开合时封面列移动、缩放）的时长。
const Duration _layoutDuration = Duration(milliseconds: 640);

/// 桌面沉浸式歌词（Apple Music macOS 全屏歌词风格）。
///
/// - 两种铺满方式（左上角按钮或 F11 切换，记住上次选择）：默认只铺满窗口（保留窗口按钮，顶部可拖动窗口），
///   或进入系统全屏铺满整个屏幕；关闭时恢复；Esc / 左上角关闭按钮退出；
/// - 左上角玻璃胶囊：关闭 + 切换铺满方式 + 译文（macOS 窗口模式避开交通灯）；音量条在控制台玻璃内、播放按钮下方（Apple 锁屏样式）；
/// - 歌名右侧：喜欢、更多操作；右下角：歌词 / 播放队列切换；
///   两个面板都关闭时封面、歌名与控制台移到正中，所有切换都用 Apple 风格的非线性动画；
/// - 遥控远程设备时展示远程曲目，歌词按远程进度滚动，控制台、音量与快捷键作用于远程设备；
/// - 宽屏：左侧大封面 + 歌名 + 玻璃控制台，右侧歌词 / 队列；
///   窄窗口：顶部小封面与歌名，中间歌词 / 队列 / 大封面，底部玻璃控制台；
/// - 鼠标静止 3 秒后隐藏光标与浮动按钮，移动即恢复；
/// - 空格播放 / 暂停，Ctrl+← / →（macOS 为 ⌘+← / →）切歌。
class ImmersiveLyricsScreen extends StatefulWidget {
  const ImmersiveLyricsScreen({super.key});

  /// 以淡入方式推入根导航（盖住三栏框架与播放栏）。
  /// 已经打开着（入口有 F11、⌘⇧F 菜单、播放栏按钮）：重复触发不再叠一层。
  static bool _open = false;

  static Future<void> open(BuildContext context) async {
    if (_open) return;
    _open = true;
    try {
      await _push(context);
    } finally {
      _open = false;
    }
  }

  static Future<void> _push(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: AppRoutes.immersiveLyricsRouteName),
        opaque: true,
        transitionDuration: context.motion(const Duration(milliseconds: 380)),
        reverseTransitionDuration: context.motion(
          const Duration(milliseconds: 260),
        ),
        pageBuilder: (_, _, _) => const ImmersiveLyricsScreen(),
        transitionsBuilder: (_, animation, _, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween(begin: 1.03, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  State<ImmersiveLyricsScreen> createState() => _ImmersiveLyricsScreenState();
}

class _ImmersiveLyricsScreenState extends State<ImmersiveLyricsScreen> {
  static const Duration _idleDelay = Duration(seconds: 3);

  /// 宽屏双栏布局的最小宽度。
  static const double _wideBreakpoint = 900;

  /// 只铺满窗口时，顶部留给窗口按钮与拖动区的高度（与 WindowCaptionButtons 默认高度一致）。
  static const double _captionInset = 40;

  /// 顶部按钮保持足够大的触控区域。
  static const double _barHeight = 48;

  /// macOS 只铺满窗口：胶囊距窗口顶端的距离（比交通灯略低，不贴顶）。
  static const double _macBarTop = 8;

  /// macOS 只铺满窗口：胶囊左端到窗口左缘的距离（与交通灯之间留出呼吸感）。
  static const double _macBarLeft = DesktopWindow.macTrafficLightsInset + 8;

  Timer? _idleTimer;
  bool _idle = false;
  _Panel _panel = _Panel.lyrics;

  /// true：系统全屏（铺满整个屏幕）；false：只铺满窗口（保留窗口外框与窗口按钮）。
  late bool _screen;
  StorageService? _storage;

  @override
  void initState() {
    super.initState();
    _storage = context.read<StorageService?>();
    _screen = _storage?.immersiveScreenFullscreen ?? false;
    _applyMode();
    DesktopWindow.fullScreen.addListener(_onSystemFullScreen);
    _restartIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    DesktopWindow.fullScreen.removeListener(_onSystemFullScreen);
    // dispose 跑在帧收尾阶段，此时同步改 ValueNotifier 会让外层（WindowFrame、
    // LiquidGlass）在 widget 树被锁定时 setState；且路由刚移除的这一帧还没提交。
    // 推迟到本帧提交之后再恢复窗口外框 / 退出全屏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DesktopWindow.immersiveWindow.value = false;
      DesktopWindow.setFullScreen(false);
    });
    super.dispose();
  }

  /// 系统直接切换了全屏（macOS 绿色按钮 / 菜单 / ⌃⌘F）：铺满方式跟着变，并记住这次选择。
  /// 自己经 [_applyMode] 切换时两边本就一致，这里不会重复处理。
  void _onSystemFullScreen() {
    final full = DesktopWindow.fullScreen.value;
    if (!mounted || full == _screen) return;
    setState(() => _screen = full);
    DesktopWindow.immersiveWindow.value = !_screen;
    _storage?.setImmersiveScreenFullscreen(_screen);
  }

  void _applyMode() {
    // 先切外框标记再切系统全屏，避免中间一帧露出窄窗口标题条
    DesktopWindow.immersiveWindow.value = !_screen;
    DesktopWindow.setFullScreen(_screen);
  }

  /// 在「铺满窗口」与「铺满整个屏幕」之间切换，并记住选择。
  void _toggleMode() {
    setState(() => _screen = !_screen);
    _applyMode();
    _storage?.setImmersiveScreenFullscreen(_screen);
  }

  /// 歌词 / 队列按钮：再点一次当前面板即关闭，封面与控制台回到正中。
  void _togglePanel(_Panel panel) =>
      setState(() => _panel = _panel == panel ? _Panel.none : panel);

  /// 鼠标移动：显示光标与浮动按钮，并重新计时。
  void _restartIdleTimer() {
    _idleTimer?.cancel();
    if (_idle) setState(() => _idle = false);
    _idleTimer = Timer(_idleDelay, () {
      if (mounted) setState(() => _idle = true);
    });
  }

  bool _closing = false;

  /// 退出：先让玻璃去掉 BackdropFilter 并等其落地，再弹出路由。
  /// 路由淡出（Opacity 图层里套 BackdropFilter）与随后的退出全屏重排，
  /// 是 Windows 引擎合成器闪退的触发点，见 [DesktopWindow.fullscreenTransition]。
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await DesktopWindow.dropGlassForExit();
    if (!mounted) return;
    final popped = await Navigator.of(context).maybePop();
    if (!popped && mounted) _closing = false;
  }

  @override
  Widget build(BuildContext context) {
    // 遥控远程设备时展示远程曲目，快捷键也发给远程设备
    final remote = NowPlayingSource.isRemote(context);
    final track = NowPlayingSource.track(context);
    // 只铺满窗口时顶部让出窗口按钮那一行
    final topInset = _screen || !DesktopWindow.enabled ? 0.0 : _captionInset;
    // macOS 只铺满窗口：原生交通灯浮在左上角，胶囊排在其右侧、略低于交通灯
    final macWindow = DesktopWindow.macNativeWindow && !_screen;
    // Windows / Linux 只铺满窗口：拖动区避开右上角自绘窗口按钮。
    final captionRight = topInset > 0 && !DesktopWindow.macNativeWindow
        ? WindowCaptionButtons.width
        : 0.0;
    final barTop = macWindow
        ? _macBarTop
        : topInset > 0
        ? 8.0
        : 20.0;
    final l10n = context.l10n;
    final fade = context.motion(const Duration(milliseconds: 300));

    Widget idleFade(Widget child) => AnimatedOpacity(
      opacity: _idle ? 0 : 1,
      duration: fade,
      child: IgnorePointer(ignoring: _idle, child: child),
    );

    return LyricsTranslationScope(
      child: GlassMenuScope(
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemBarsStyle(Brightness.dark),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _close,
              const SingleActivator(LogicalKeyboardKey.f11): _toggleMode,
              // 播放类按键与主窗口相同，远程模式下控制其他设备
              ...PlaybackShortcuts.bindings(context),
            },
            child: Focus(
              autofocus: true,
              onKeyEvent: (_, event) =>
                  PlaybackShortcuts.onSpaceKey(context, event),
              child: MouseRegion(
                cursor: _idle ? SystemMouseCursors.none : MouseCursor.defer,
                onHover: (_) => _restartIdleTimer(),
                child: Material(
                  color: Colors.black,
                  child: BackdropGroup(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        LyricsBackdrop(imageUrl: track?.coverUrl ?? ''),
                        if (track == null)
                          Center(
                            child: EmptyState(
                              icon: Icons.music_off_rounded,
                              title: context.l10n.playerNothingPlayingTitle,
                              message: context.l10n.lyricsNothingPlayingMessage,
                              onDark: true,
                            ),
                          )
                        else
                          LayoutBuilder(
                            builder: (context, box) =>
                                box.maxWidth >= _wideBreakpoint
                                ? _WideLayout(
                                    track: track,
                                    size: box.biggest,
                                    remote: remote,
                                    panel: _panel,
                                  )
                                : _NarrowLayout(
                                    track: track,
                                    size: box.biggest,
                                    remote: remote,
                                    panel: _panel,
                                    topInset:
                                        (barTop + _barHeight).clamp(
                                          topInset,
                                          double.infinity,
                                        ) +
                                        8,
                                  ),
                          ),
                        // 只铺满窗口时：顶部一条透明拖动区（避开右上角窗口按钮），可照常移动窗口
                        if (topInset > 0)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: captionRight,
                            height: topInset,
                            child: const WindowDragArea(
                              child: SizedBox.expand(),
                            ),
                          ),
                        Positioned(
                          top: barTop,
                          left: macWindow ? _macBarLeft : 18,
                          child: idleFade(
                            _GlassCapsule(
                              height: _barHeight,
                              children: [
                                _CapsuleIcon(
                                  icon: Icons.close_rounded,
                                  tooltip: l10n.lyricsExitImmersive,
                                  onPressed: _close,
                                ),
                                if (DesktopWindow.enabled)
                                  _CapsuleIcon(
                                    icon: _screen
                                        ? Icons.fullscreen_exit_rounded
                                        : Icons.fullscreen_rounded,
                                    tooltip: _screen
                                        ? l10n.lyricsFillWindow
                                        : l10n.lyricsFillScreen,
                                    onPressed: _toggleMode,
                                  ),
                                if (track != null && _panel == _Panel.lyrics)
                                  const LyricsTranslationButton(
                                    size: _barHeight,
                                    glass: false,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (track != null) ...[
                          Positioned(
                            right: 20,
                            bottom: 20,
                            child: idleFade(
                              _PanelButtons(
                                panel: _panel,
                                onToggle: _togglePanel,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽屏：左封面信息列 + 右侧歌词 / 队列面板；面板关闭时封面列平滑移到正中并略微放大。
class _WideLayout extends StatelessWidget {
  final SpotifyTrack track;
  final Size size;
  final bool remote;
  final _Panel panel;

  const _WideLayout({
    required this.track,
    required this.size,
    required this.remote,
    required this.panel,
  });

  @override
  Widget build(BuildContext context) {
    // 左栏占 5/11，右侧面板占其余
    final leftWidth = size.width * 5 / 11;
    // 为上下留白、标题、播放控制（含内置音量条）保留高度；大字体仍可滚动。
    final maxArtHeight = (size.height - 350).clamp(0.0, 480.0);
    // 封面随窗口缩放：既不压过歌词，也不在 4K 全屏下显得局促；居中时放大一些
    final artBase = (size.height * 0.46)
        .clamp(220.0, 480.0)
        .clamp(0.0, size.width * 0.32)
        .clamp(0.0, maxArtHeight);
    final artCentered = (artBase * 1.12).clamp(0.0, maxArtHeight);
    final lyricSize = (size.height / 22).clamp(32.0, 48.0);
    final open = panel != _Panel.none;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 面板在下、封面列在上：面板淡出时不会盖住正移向中间的封面
        Positioned(
          left: leftWidth,
          right: 56,
          top: 0,
          bottom: 0,
          child: _PanelSwitcher(
            panel: panel,
            lyrics: () => LyricsView(
              appleMusicStyle: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
              key: ValueKey((track.id, remote)),
              track: track,
              remote: remote,
              topInset: 80,
              bottomInset: 80,
              fontSize: lyricSize,
              horizontalPadding: 16,
              lineCursor: MouseCursor.defer,
            ),
            queue: () => const Padding(
              padding: EdgeInsets.only(top: 64, bottom: 72),
              child: _ImmersiveQueue(),
            ),
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween(end: open ? 1.0 : 0.0),
          duration: context.motion(_layoutDuration),
          curve: _appleCurve,
          builder: (context, t, _) {
            final artSize = lerpDouble(artCentered, artBase, t)!;
            final centerX = lerpDouble(size.width / 2, leftWidth / 2 + 16, t)!;
            // 五个播放按钮与内边距至少需要 280px，不随封面继续缩窄。
            final contentWidth = artSize.clamp(280.0, double.infinity);
            final columnWidth = contentWidth + 96;
            return Positioned(
              left: centerX - columnWidth / 2,
              width: columnWidth,
              top: 0,
              bottom: 0,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 56,
                  ),
                  child: SizedBox(
                    width: contentWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: _Artwork(track: track, size: artSize),
                        ),
                        const SizedBox(height: 26),
                        _TitleRow(track: track),
                        const SizedBox(height: 18),
                        // 左栏与右侧歌词面板不重叠，下方只有流动背景
                        LyricsGlassControls(
                          full: true,
                          backdrop: false,
                          maxWidth: contentWidth,
                          bottom: _VolumeRow(remote: remote),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 窄窗口：顶部小封面与歌名，中间歌词 / 队列（都关闭时为大封面），底部玻璃控制台。
class _NarrowLayout extends StatelessWidget {
  final SpotifyTrack track;
  final Size size;
  final bool remote;
  final _Panel panel;

  /// 顶部让给窗口按钮与玻璃胶囊的高度。
  final double topInset;

  const _NarrowLayout({
    required this.track,
    required this.size,
    required this.remote,
    required this.panel,
    this.topInset = 0,
  });

  static const double _headerHeight = 88;
  static const double _controlsHeight = 200;

  @override
  Widget build(BuildContext context) {
    final artSize =
        (size.height - topInset - _headerHeight - _controlsHeight - 120).clamp(
          0.0,
          size.width - 96,
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        _PanelSwitcher(
          panel: panel,
          // 歌词从顶部歌名之下开始（裁在其下方淡出），对焦行偏上时上一句不会压到歌名
          lyrics: () => Padding(
            padding: EdgeInsets.only(top: _headerHeight + topInset - 8),
            child: LyricsView(
              appleMusicStyle: !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
              key: ValueKey((track.id, remote)),
              track: track,
              remote: remote,
              bottomInset: _controlsHeight + 56,
              fontSize: 34,
              horizontalPadding: 36,
              lineCursor: MouseCursor.defer,
            ),
          ),
          queue: () => Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              _headerHeight + topInset,
              12,
              _controlsHeight + 56,
            ),
            child: const _ImmersiveQueue(),
          ),
          none: () => Padding(
            padding: EdgeInsets.only(
              top: _headerHeight + topInset,
              bottom: _controlsHeight + 40,
            ),
            child: Center(
              child: _Artwork(track: track, size: artSize),
            ),
          ),
        ),
        Positioned(
          top: 12 + topInset,
          left: 32,
          right: 32,
          child: Row(
            children: [
              _Artwork(track: track, size: 56),
              const SizedBox(width: 14),
              Expanded(child: _TitleRow(track: track, large: false)),
            ],
          ),
        ),
        // 底部右侧留给歌词 / 队列切换按钮
        Positioned(
          left: 32,
          right: 32,
          bottom: 72,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LyricsGlassControls(
                full: true,
                maxWidth: 560,
                bottom: _VolumeRow(remote: remote),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 右侧面板：歌词 / 队列 / 无，切换时淡入淡出并轻微位移、缩放。
class _PanelSwitcher extends StatelessWidget {
  final _Panel panel;
  final Widget Function() lyrics;
  final Widget Function() queue;
  final Widget Function()? none;

  const _PanelSwitcher({
    required this.panel,
    required this.lyrics,
    required this.queue,
    this.none,
  });

  @override
  Widget build(BuildContext context) {
    final child = switch (panel) {
      _Panel.lyrics => lyrics(),
      _Panel.queue => queue(),
      _Panel.none => none?.call() ?? const SizedBox.expand(),
    };
    return AnimatedSwitcher(
      duration: context.motion(const Duration(milliseconds: 520)),
      reverseDuration: context.motion(const Duration(milliseconds: 260)),
      switchInCurve: _appleCurve,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0.03, 0),
            end: Offset.zero,
          ).animate(animation),
          child: ScaleTransition(
            scale: Tween(begin: 0.97, end: 1.0).animate(animation),
            child: child,
          ),
        ),
      ),
      child: KeyedSubtree(key: ValueKey(panel), child: child),
    );
  }
}

/// 沉浸式里的播放队列：深色主题下复用 [QueueList]（拖拽排序、左滑移除、点击跳播）。
class _ImmersiveQueue extends StatelessWidget {
  const _ImmersiveQueue();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: base.colorScheme.primary,
          brightness: Brightness.dark,
        ).copyWith(
          primary: Colors.white,
          onSurface: Colors.white,
          onSurfaceVariant: Colors.white60,
          surface: Colors.transparent,
        );
    return Theme(
      data: base.copyWith(
        colorScheme: scheme,
        textTheme: base.textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        listTileTheme: const ListTileThemeData(
          textColor: Colors.white,
          subtitleTextStyle: TextStyle(color: Colors.white60),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF6B6B)),
        ),
      ),
      child: ShaderMask(
        // 上下边缘柔和淡出，与歌词面板一致
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: [0.0, 0.04, 0.92, 1.0],
        ).createShader(rect),
        child: const QueueList(horizontalPadding: 16),
      ),
    );
  }
}

/// 封面：切歌时交叉淡入，底部柔和投影。
class _Artwork extends StatelessWidget {
  final SpotifyTrack track;
  final double size;

  const _Artwork({required this.track, required this.size});

  @override
  Widget build(BuildContext context) {
    final radius = context.tokens.radius(size >= 200 ? 16 : 10);
    return AnimatedSwitcher(
      duration: context.motion(const Duration(milliseconds: 420)),
      child: DecoratedBox(
        key: ValueKey(track.id),
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: size * 0.12,
              offset: Offset(0, size * 0.04),
            ),
          ],
        ),
        child: CoverImage(
          url: track.coverUrl,
          size: size,
          borderRadius: radius,
        ),
      ),
    );
  }
}

/// 歌名 + 「艺人 — 专辑」，右侧喜欢与更多操作。
class _TitleRow extends StatelessWidget {
  final SpotifyTrack track;
  final bool large;

  const _TitleRow({required this.track, this.large = true});

  @override
  Widget build(BuildContext context) {
    final album = track.album?.name ?? '';
    final subtitle = album.isEmpty
        ? track.artistNames
        : '${track.artistNames} — $album';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              MarqueeText(
                key: ValueKey(track.id),
                text: track.name,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: large ? 21 : 17,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontWeight: FontWeight.w500,
                  fontSize: large ? 16 : 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _GlassLikeButton(track: track),
        const SizedBox(width: 10),
        Builder(
          // 独立 context：菜单锚定在按钮下方
          builder: (buttonContext) => _GlassCircleButton(
            icon: Icons.more_horiz_rounded,
            tooltip: context.l10n.commonMoreOptions,
            onPressed: () => TrackMenu.show(buttonContext, track),
          ),
        ),
      ],
    );
  }
}

/// 圆形玻璃小按钮（歌名右侧的喜欢 / 更多）。
class _GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? iconColor;
  static const double size = 34;

  const _GlassCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    // 歌名行只出现在宽屏左栏与窄屏顶部标题区，歌词不会滑到下方
    return LiquidGlass(
      backdrop: false,
      borderRadius: BorderRadius.circular(size / 2),
      child: _ToggleDisc(
        active: false,
        size: size,
        child: IconButton(
          icon: Icon(icon, size: size * 0.5),
          color: iconColor ?? Colors.white,
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// 开关底盘：开启时淡入一层亮白圆底。
class _ToggleDisc extends StatelessWidget {
  final bool active;
  final double size;
  final Widget child;

  const _ToggleDisc({
    required this.active,
    required this.size,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: context.motion(const Duration(milliseconds: 360)),
      curve: _appleCurve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: active ? 0.88 : 0.0),
      ),
      child: child,
    );
  }
}

/// 喜欢（订阅曲库中这一首的状态）。
class _GlassLikeButton extends StatelessWidget {
  final SpotifyTrack track;

  const _GlassLikeButton({required this.track});

  @override
  Widget build(BuildContext context) {
    final liked = context.select<LibraryProvider, bool>(
      (l) => l.isLiked(track.id),
    );
    return _GlassCircleButton(
      icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      // 已喜欢：Spotify 绿（不随主题强调色变化）
      iconColor: liked ? MD3EColors.spotifyGreen : Colors.white,
      tooltip: liked ? context.l10n.likeRemove : context.l10n.likeAdd,
      onPressed: () => context.read<LibraryProvider>().toggleLike(track),
    );
  }
}

/// 顶部玻璃胶囊容器。
class _GlassCapsule extends StatelessWidget {
  final double height;
  final List<Widget> children;

  const _GlassCapsule({required this.height, required this.children});

  @override
  Widget build(BuildContext context) {
    // 胶囊在歌词区上方的顶栏留白内（窄屏歌词从胶囊下方开始，宽屏位于左栏顶部）
    return LiquidGlass(
      backdrop: false,
      borderRadius: BorderRadius.circular(height / 2),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: height,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _CapsuleIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _CapsuleIcon({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 24),
      color: Colors.white,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      onPressed: onPressed,
    );
  }
}

/// 控制台玻璃内、播放按钮下方的音量条（Apple 锁屏样式）：
/// 左端小喇叭（点击静音 / 恢复），右端大音量喇叭，中间白色滑杆。
/// 滑杆与上方进度条同宽对齐：两端图标占的位置正好是进度条两端的时间标签。
/// 遥控远程设备时调节远程设备音量。
class _VolumeRow extends StatelessWidget {
  final bool remote;

  const _VolumeRow({required this.remote});

  @override
  Widget build(BuildContext context) {
    late final double volume;
    ValueChanged<double>? onChanged;
    ValueChanged<double>? onChangeEnd;
    late final VoidCallback onMute;
    if (remote) {
      final connect = context.read<ConnectProvider>();
      volume = context.select<ConnectProvider, double>((c) => c.volume);
      // 远程设备不支持调音量：滑杆置灰，点喇叭说明原因（与键盘音量快捷键一致）
      final supported = context.select<ConnectProvider, bool>(
        (c) => c.activeDevice?.supportsVolume ?? false,
      );
      if (supported) {
        onChanged = connect.setVolume;
        onMute = () => connect.setVolume(volume > 0 ? 0 : 0.5);
      } else {
        onMute = () => AppToast.show(
          context,
          context.l10n.connectVolumeUnsupported(
            connect.activeDevice?.name ?? '',
          ),
          icon: Icons.volume_off_rounded,
          tone: ToastTone.warning,
        );
      }
    } else {
      final playback = context.read<PlaybackProvider>();
      volume = context.select<PlaybackProvider, double>((p) => p.volume);
      onChanged = playback.setVolume;
      onChangeEnd = (v) => playback.setVolume(v, persist: true);
      onMute = playback.toggleMute;
    }
    final muted = volume == 0;
    // 与进度条（本机）两端「40 宽标签 + 8 间距」一致；远程进度条没有间距
    final gap = SizedBox(width: remote ? 0 : 8);

    return Row(
      children: [
        SizedBox(
          width: 40,
          child: IconButton(
            icon: Icon(
              muted ? Icons.volume_off_rounded : Icons.volume_mute_rounded,
              size: 18,
            ),
            color: Colors.white60,
            tooltip: muted
                ? context.l10n.playerUnmute
                : context.l10n.playerMute,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 40, height: 28),
            onPressed: onMute,
          ),
        ),
        gap,
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              // 与进度条相同的滑块 / 触控半径，两条轨道才能严格对齐
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              trackShape: const RoundedRectSliderTrackShape(),
            ),
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
        gap,
        const SizedBox(
          width: 40,
          height: 28,
          child: Icon(Icons.volume_up_rounded, size: 18, color: Colors.white60),
        ),
      ],
    );
  }
}

/// 右下角：歌词 / 播放队列切换胶囊。
class _PanelButtons extends StatelessWidget {
  final _Panel panel;
  final ValueChanged<_Panel> onToggle;

  const _PanelButtons({required this.panel, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const size = 34.0;

    Widget toggle(_Panel target, IconData icon, String tooltip) => _ToggleDisc(
      active: panel == target,
      size: size,
      child: IconButton(
        icon: Icon(icon, size: 18),
        color: panel == target ? const Color(0xFF1C1C1E) : Colors.white,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: () => onToggle(target),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LiquidGlass(
          borderRadius: BorderRadius.circular(size / 2 + 3),
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              toggle(_Panel.lyrics, Icons.lyrics_outlined, l10n.lyricsTitle),
              const SizedBox(width: 4),
              toggle(
                _Panel.queue,
                Icons.format_list_bulleted_rounded,
                l10n.queueTitle,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
