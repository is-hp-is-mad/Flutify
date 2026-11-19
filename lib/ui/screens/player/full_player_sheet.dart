import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/theme/md3e_theme.dart';
import '../../../core/theme/system_bars.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playback_context.dart';
import '../../../models/track.dart';
import '../../../providers/appearance_provider.dart';
import '../../../providers/playback_provider.dart';
import '../../../providers/connect_provider.dart';
import '../../../services/storage/preferences_store.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/connect/connect_actions.dart';
import 'player_modal.dart';
import 'player_expansion.dart';
import 'player_scene_view.dart';
import 'widgets/swipeable_artwork.dart';

/// 全屏播放器（移动端底部全屏面板 / 桌面端居中对话框）。
///
/// - 中间区域在「封面 / 歌词 / 播放队列」之间切换（底部两个按钮，再点一次回到封面），
///   标题、进度条与播放控件始终保留在下方；
/// - 封面可左右拖动切歌（[SwipeableArtwork]）；
/// - 背景为封面主色 → 近黑的渐变；切到歌词视图时交叉淡入为流动封面，控件收进液态玻璃；
/// - 深浅色主题下都按用户外观设置的深色主题绘制（白色系控件）；
/// - **远程模式**（Connect 遥控其他设备）：显示远程曲目，进度与控制发给远程设备。
///
/// 本组件只在切歌或播放上下文变化时重建；进度条、播放按钮、随机/循环、
/// 点赞按钮均为独立订阅的子组件。
class FullPlayerSheet extends StatefulWidget {
  const FullPlayerSheet({
    super.key,
    this.fullscreen = false,
    this.expansionAnimation,
  });

  /// Presentation is selected when opening the route; resizing does not change it.
  final bool fullscreen;
  final Animation<double>? expansionAnimation;

  /// 根据窗口宽度选择以底部面板或对话框形式打开。
  static Future<void> show(BuildContext context) =>
      _show(context, interactive: false);

  /// 宽屏走居中对话框，不参与迷你条展开（也就没有上滑打开）。
  static bool _isDesktop(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return screen.width >= 800 && screen.height >= 600;
  }

  static Future<void> _show(
    BuildContext context, {
    required bool interactive,
  }) => PlayerModal.show(context, (captureRoute) {
    // 宽但矮的窗口（手机横屏、压扁的桌面窗口）放不下 420×720 的对话框，
    // 改走全屏路由，由场景自己切到横屏布局。
    if (_isDesktop(context)) {
      return showDialog(
        context: context,
        builder: (dialogContext) {
          captureRoute(dialogContext);
          return const Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.all(24),
            child: SizedBox(width: 420, height: 720, child: FullPlayerSheet()),
          );
        },
      );
    }
    // 窄窗口（手机、Windows 竖屏窄窗）在所有平台上共用同一套从迷你播放器展开的全屏路由。
    final navigator = Navigator.of(context, rootNavigator: true);
    final origin = PlayerExpansionSource.capture(context);
    final reduceMotion = context.reduceMotion;
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    late final _PlayerPageRoute route;
    route = _PlayerPageRoute(
      navigatorState: navigator,
      origin: origin,
      reduceMotion: reduceMotion,
      interactiveOpen: interactive && !reduceMotion,
      settings: const RouteSettings(name: AppRoutes.fullPlayerRouteName),
      opaque: false,
      fullscreenDialog: true,
      barrierColor: Colors.black26,
      transitionDuration: reduceMotion
          ? Duration.zero
          : PlayerExpansionMotion.duration,
      reverseTransitionDuration: reduceMotion
          ? Duration.zero
          : PlayerExpansionMotion.reverseDuration,
      pageBuilder: (sheetContext, animation, secondaryAnimation) {
        captureRoute(sheetContext);
        final media = MediaQuery.of(sheetContext);
        return themes.wrap(
          MediaQuery(
            data: media.copyWith(
              padding: media.viewPadding,
              disableAnimations: reduceMotion,
            ),
            child: FullPlayerSheet(
              fullscreen: true,
              expansionAnimation: animation,
            ),
          ),
        );
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          Material(
            type: MaterialType.transparency,
            child: PlayerExpansionTransition(
              animation: animation,
              origin: origin,
              onDragStart: route.dragStart,
              onDragUpdate: route.dragUpdate,
              onDragEnd: route.dragEnd,
              child: child,
            ),
          ),
    );
    return navigator.push<void>(route);
  });

  /// 迷你条上滑：从迷你条开始跟手打开播放页（收回途中再上滑则重新抓住它）。
  static void beginOpenDrag(BuildContext context) {
    if (_isDesktop(context)) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (_PlayerPageRoute._active[navigator] == null) {
      _show(context, interactive: true);
    }
    _PlayerPageRoute._active[navigator]?.dragStart();
  }

  static void updateOpenDrag(BuildContext context, double dy) =>
      _PlayerPageRoute._active[Navigator.of(context, rootNavigator: true)]
          ?.dragUpdate(dy);

  static void endOpenDrag(BuildContext context, double velocity) =>
      _PlayerPageRoute._active[Navigator.of(context, rootNavigator: true)]
          ?.dragEnd(velocity);

  @override
  State<FullPlayerSheet> createState() => _FullPlayerSheetState();
}

/// 迷你条外层的上滑手势：向上拖动时把手指交给 [FullPlayerSheet] 的路由。
class PlayerOpenDrag extends StatefulWidget {
  const PlayerOpenDrag({super.key, required this.child});

  final Widget child;

  @override
  State<PlayerOpenDrag> createState() => _PlayerOpenDragState();
}

class _PlayerOpenDragState extends State<PlayerOpenDrag> {
  bool _driving = false;

  void _end(double velocity) {
    if (!_driving) return;
    _driving = false;
    FullPlayerSheet.endOpenDrag(context, velocity);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onVerticalDragUpdate: (d) {
      if (!_driving) {
        // 向下拖迷你条什么也不做：只有向上才开始打开
        if (d.delta.dy >= 0) return;
        _driving = true;
        FullPlayerSheet.beginOpenDrag(context);
      }
      FullPlayerSheet.updateOpenDrag(context, d.delta.dy);
    },
    onVerticalDragEnd: (d) => _end(d.primaryVelocity ?? 0),
    onVerticalDragCancel: () => _end(0),
    child: widget.child,
  );
}

/// 全屏播放页路由：唯一拥有进度 P（= controller.value）。
///
/// - 打开 / 收回 / 释放都用 [PlayerExpansionMotion] 的弹簧（[createSimulation]），速度连续；
/// - 关闭（按钮、系统返回、Esc、下拉）不立即出栈：先在路由仍在时把 P 弹回 0，
///   落到迷你条后才真正 pop。期间外壳仍可被重新抓住、反向展开；
/// - 拖动随时可以接管（展开中、收回中、完全展开时），从当前 P 继续，不跳回 0 或 1。
class _PlayerPageRoute extends PageRouteBuilder<void> {
  _PlayerPageRoute({
    required this.navigatorState,
    required this.origin,
    required this.reduceMotion,
    required this.interactiveOpen,
    required super.settings,
    required super.pageBuilder,
    required super.transitionsBuilder,
    super.opaque,
    super.fullscreenDialog,
    super.barrierColor,
    super.transitionDuration,
    super.reverseTransitionDuration,
  }) {
    _active[navigatorState] = this;
  }

  static final _active = Expando<_PlayerPageRoute>();

  final NavigatorState navigatorState;
  final PlayerExpansionOrigin? origin;
  final bool reduceMotion;

  /// 由迷你条上滑打开：P 停在 0 等手指，而不是自动弹开。
  bool interactiveOpen;

  bool _dragging = false;
  bool _dismissing = false;

  /// 这次拖动从哪一端开始：从迷你条（P 近 0）往上拉，还是从播放页往下拉。
  bool _dragOpening = false;
  bool _finishing = false;

  /// 外壳上沿从迷你条走到屏幕顶的距离：拖动 1 像素 = 1/行程 的 P。
  double get _travel {
    final top = origin?.bounds.top;
    if (top != null && top > 1) return top;
    final box = navigatorState.context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : 800;
  }

  void _syncPresentation() =>
      PlayerExpansionMotion.presentation.value = animation?.value ?? 0;

  /// 在路由真正退场出栈前同步恢复迷你条真身可见性与跑马灯 TickerMode，
  /// 避免路由 OverlayEntry 在当帧卸下、而 [dispose] 等到 finalizeTree 才触发，
  /// 导致底栏或封面在落定那一帧闪烁透明 1 帧。
  void _restoreOrigin() {
    if (_active[navigatorState] != null && _active[navigatorState] != this) {
      return;
    }
    PlayerExpansionMotion.presentation.value = 0;
    origin?.setArtworkHidden?.call(false);
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        !interactiveOpen &&
        !_dragging &&
        (!isCurrent || _finishing)) {
      _restoreOrigin();
    }
  }

  @override
  void install() {
    super.install();
    animation!.addListener(_syncPresentation);
    animation!.addStatusListener(_handleRouteAnimationStatus);
    origin?.setArtworkHidden?.call(true);
  }

  @override
  Simulation? createSimulation({required bool forward}) {
    if (reduceMotion) return null;
    if (!forward) {
      // 用户关闭（[dismiss]）已经把 P 弹回 0：出栈瞬间结束。
      if (_finishing) return null;
      // 代码出栈（popUntil、前往专辑等）：从当前位置就地掉头弹回迷你条。
      return PlayerExpansionMotion.simulation(from: controller!.value, to: 0);
    }
    if (interactiveOpen) return _HoldSimulation(0);
    return PlayerExpansionMotion.simulation(from: controller!.value, to: 1);
  }

  /// 用户关闭（关闭按钮、系统返回、Esc）：路由仍在时先把 P 弹回 0，期间可被重新抓住；
  /// 落到迷你条后才真正出栈。代码里的 pop / popUntil 不经过这里，照常立即出栈。
  void dismiss() {
    final c = controller;
    if (c == null || _finishing || _dismissing || !isActive) return;
    if (reduceMotion) {
      _finishing = true;
      _restoreOrigin();
      navigator?.pop();
      return;
    }
    _dragging = false;
    // 展开途中被关闭：像 UIViewPropertyAnimator.isReversed 那样就地掉头。
    _dismiss(0);
  }

  void _dismiss(double velocity) {
    final c = controller!;
    _dismissing = true;
    c
        .animateBackWith(
          PlayerExpansionMotion.simulation(
            from: c.value,
            to: 0,
            velocity: velocity,
          ),
        )
        .then((_) {
          if (_dismissing && c.isDismissed) _finish();
        });
  }

  void _finish() {
    if (_finishing || !isActive) return;
    _finishing = true;
    _restoreOrigin();
    final nav = navigator;
    if (nav == null) return;
    if (isCurrent) {
      nav.pop();
    } else {
      nav.removeRoute(this);
    }
  }

  /// 已经出栈（任何方式）：拖动不再接管。
  bool get _popped =>
      !isActive ||
      (animation!.status == AnimationStatus.reverse && !_dismissing);

  /// 关闭动效时不跟手：只累计位移，松手够远/够快就直接关闭。
  double _reducedDrag = 0;

  void dragStart() {
    final c = controller;
    if (c == null || _finishing || _popped) return;
    _dragging = true;
    _reducedDrag = 0;
    if (reduceMotion) return;
    _dragOpening = c.value < 0.5;
    _dismissing = false;
    interactiveOpen = false;
    c.stop();
  }

  void dragUpdate(double dy) {
    final c = controller;
    if (!_dragging || c == null) return;
    if (reduceMotion) {
      _reducedDrag += dy;
      return;
    }
    c.value = (c.value - dy / _travel).clamp(0.0, 1.0);
  }

  void dragEnd(double velocity) {
    final c = controller;
    if (!_dragging || c == null) return;
    _dragging = false;
    if (reduceMotion) {
      if (_reducedDrag > 100 || velocity > 600) dismiss();
      return;
    }
    // 像素/秒（向下为正）→ P/秒（向上为正）
    final v = (-velocity / _travel).clamp(-30.0, 30.0);
    if (PlayerExpansionMotion.shouldExpand(c.value, v, opening: _dragOpening)) {
      c.animateWith(
        PlayerExpansionMotion.simulation(from: c.value, to: 1, velocity: v),
      );
    } else {
      _dismiss(v);
    }
  }

  @override
  void dispose() {
    animation?.removeListener(_syncPresentation);
    animation?.removeStatusListener(_handleRouteAnimationStatus);
    _restoreOrigin();
    if (_active[navigatorState] == this) _active[navigatorState] = null;
    super.dispose();
  }
}

/// 上滑打开时的占位：P 停在原地，直到手指接管。
class _HoldSimulation extends Simulation {
  _HoldSimulation(this.value);

  final double value;

  @override
  double x(double time) => value;

  @override
  double dx(double time) => 0;

  @override
  bool isDone(double time) => false;
}

class _FullPlayerSheetState extends State<FullPlayerSheet> {
  late bool _pinned;
  PreferencesStore? _storage;

  @override
  void initState() {
    super.initState();
    _storage = context.read<PreferencesStore?>();
    _pinned = _storage?.immersivePinned ?? false;
  }

  void _setPinned(bool value) {
    setState(() => _pinned = value);
    _storage?.setImmersivePinned(value);
  }

  @override
  Widget build(BuildContext context) {
    // 始终按用户外观设置的「深色」主题绘制（强调色、圆角、玻璃强度同步生效）
    final theme =
        context.watch<AppearanceProvider?>()?.theme(Brightness.dark) ??
        MD3ETheme.dark;
    return Theme(
      data: theme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBarsStyle(Brightness.dark),
        child: Builder(builder: _buildContent),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    // 远程模式：显示远程曲目、标题行标出设备名（控制权规则与播放栏一致）
    final remote = ConnectActions.showRemote(context);
    final track = remote
        ? context.select<ConnectProvider?, SpotifyTrack?>(
            (c) => c?.displayTrack,
          )
        : context.select<PlaybackProvider, SpotifyTrack?>(
            (p) => p.currentTrack,
          );
    final deviceName = remote
        ? context.select<ConnectProvider?, String?>(
            (c) => c?.activeDevice?.name,
          )
        : null;
    final playbackContext = remote
        ? PlaybackContext(type: 'device', name: deviceName ?? '')
        : context.select<PlaybackProvider, PlaybackContext>(
            (p) => p.playbackContext,
          );
    final colorScheme = Theme.of(context).colorScheme;
    final fullscreen = widget.fullscreen;
    final radius = fullscreen
        ? BorderRadius.zero
        : BorderRadius.circular(context.tokens.corner(32));
    if (track == null) {
      return _closeOnEscape(
        context,
        _NothingPlaying(
          color: colorScheme.surfaceContainerLowest,
          borderRadius: radius,
        ),
      );
    }

    final content = ClipRRect(
      borderRadius: radius,
      clipBehavior: radius == BorderRadius.zero ? Clip.none : Clip.antiAlias,
      // 控制卡片与歌词页的玻璃按钮共用同一次背景采样（沉浸式歌词页已是这样），
      // 否则每个 LiquidGlass 各复制一次下方画面。
      child: BackdropGroup(
        child: PlayerSceneView(
          track: track,
          playbackContext: playbackContext,
          remote: remote,
          expansionAnimation: widget.expansionAnimation,
          pinned: _pinned,
          onPinnedChanged: _setPinned,
        ),
      ),
    );
    // 全屏时的下拉收回由外壳（PlayerExpansionTransition）接管：
    // 它在路由的 IgnorePointer 之外，收回途中也能重新抓住。
    return _closeOnEscape(context, _deferPop(context, content));
  }

  /// 关闭按钮 / 系统返回 / Esc 都经 maybePop 到这里：交给路由做可中断的收回。
  Widget _deferPop(BuildContext context, Widget child) {
    final route = ModalRoute.of(context);
    if (route is! _PlayerPageRoute) return child;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) route.dismiss();
      },
      child: child,
    );
  }

  /// Esc 关闭播放器（桌面键盘）。放在最外层：焦点在内部任意按钮上时按键同样冒泡到这里，
  /// 目的地菜单、设备选择等上层路由有自己的焦点域，会先处理 Esc。
  Widget _closeOnEscape(BuildContext context, Widget child) =>
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: Focus(autofocus: true, skipTraversal: true, child: child),
      );
}

/// 没有当前曲目时的占位（例如队列被清空后面板仍打开）。
class _NothingPlaying extends StatelessWidget {
  final Color color;
  final BorderRadius borderRadius;

  const _NothingPlaying({required this.color, required this.borderRadius});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: color, borderRadius: borderRadius),
      child: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
                tooltip: context.l10n.commonClose,
                onPressed: () => Navigator.maybePop(context),
              ),
            ),
            Center(
              child: EmptyState(
                icon: Icons.music_note_rounded,
                title: context.l10n.playerNothingPlayingTitle,
                message: context.l10n.playerNothingPlayingMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
