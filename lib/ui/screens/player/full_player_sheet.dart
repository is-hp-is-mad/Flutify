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
  static Future<void> show(BuildContext context) => PlayerModal.show(context, (
    captureRoute,
  ) {
    // 宽但矮的窗口（手机横屏、压扁的桌面窗口）放不下 420×720 的对话框，
    // 改走全屏路由，由场景自己切到横屏布局。
    final screen = MediaQuery.sizeOf(context);
    final isDesktop = screen.width >= 800 && screen.height >= 600;
    if (isDesktop) {
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
    final origin = PlayerExpansionSource.capture(context);
    final reduceMotion = context.reduceMotion;
    final themes = InheritedTheme.capture(
      from: context,
      to: Navigator.of(context, rootNavigator: true).context,
    );
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: AppRoutes.fullPlayerRouteName),
        opaque: false,
        fullscreenDialog: true,
        barrierColor: Colors.black26,
        transitionDuration: context.motion(PlayerExpansionMotion.duration),
        reverseTransitionDuration: context.motion(
          PlayerExpansionMotion.reverseDuration,
        ),
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
                child: child,
              ),
            ),
      ),
    );
  });

  @override
  State<FullPlayerSheet> createState() => _FullPlayerSheetState();
}

class _FullPlayerSheetState extends State<FullPlayerSheet> {
  double _dismissDragDistance = 0;

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
      // 控制卡片与歌词页的玻璃按钮共用同一次背景采样（沉浸式歌词页已是这样），
      // 否则每个 LiquidGlass 各复制一次下方画面。
      child: BackdropGroup(
        child: PlayerSceneView(
          track: track,
          playbackContext: playbackContext,
          remote: remote,
          expansionAnimation: widget.expansionAnimation,
        ),
      ),
    );
    return _closeOnEscape(
      context,
      fullscreen
          ? GestureDetector(
              onVerticalDragStart: (_) => _dismissDragDistance = 0,
              onVerticalDragUpdate: (details) =>
                  _dismissDragDistance += details.delta.dy,
              onVerticalDragCancel: () => _dismissDragDistance = 0,
              onVerticalDragEnd: (details) {
                if (_dismissDragDistance > 100 ||
                    (details.primaryVelocity ?? 0) > 600) {
                  Navigator.maybePop(context);
                }
                _dismissDragDistance = 0;
              },
              child: content,
            )
          : content,
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
                onPressed: () => Navigator.pop(context),
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
