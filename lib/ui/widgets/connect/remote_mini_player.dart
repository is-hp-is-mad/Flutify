import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/utils/artwork_palette.dart';
import '../../../l10n/l10n.dart';
import '../../../providers/connect_provider.dart';
import '../../screens/player/device_picker_sheet.dart';
import '../../screens/player/full_player_sheet.dart';
import '../../screens/player/player_expansion.dart';
import '../cover_image.dart';
import '../marquee_text.dart';
import '../mini_player_frame.dart';
import 'connect_actions.dart';
import 'connect_device_icon.dart';
import 'remote_progress.dart';

/// 移动端迷你播放器的远程模式：外观与本机胶囊一致，内容与按钮作用于远程设备。
///
/// - 第二行改为强调色「正在 {设备} 上播放」（与官方移动端一致）；
/// - 点按打开全屏播放器（远程曲目、远程进度、远程控制台与本机模式一致）；设备键打开设备面板；左右滑动切歌；
/// - 底部细进度线按服务端快照推算。
class RemoteMiniPlayer extends StatelessWidget {
  const RemoteMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final connect = context.watch<ConnectProvider>();
    final player = connect.player;
    final track = connect.remoteTrack;
    final imageUrl = track?.coverUrl ?? player.imageUrl;

    final tokens = context.tokens;
    final ShapeBorder shape = tokens.squareCorners
        ? RoundedRectangleBorder(borderRadius: tokens.radius(16))
        : const StadiumBorder();

    return ArtworkColorBuilder(
      imageUrl: imageUrl,
      fallback: const Color(0xFF3A3A42),
      builder: (context, artColor) {
        final background = Color.lerp(artColor, Colors.black, 0.35)!;
        return MiniPlayerBounds(
          child: PlayerExpansionSource(
            key: const ValueKey('mini-player-expansion-source'),
            color: background,
            translucent: tokens.hyperMaterial,
            borderRadius: tokens.squareCorners
                ? tokens.radius(16)
                : BorderRadius.circular(32),
            compactChild: _RemoteMiniRow(
              imageUrl: imageUrl,
              title: track?.name ?? player.title,
              trackKey: player.trackUri,
              showArtwork: false,
            ),
            child: MiniPlayerSurface(
              background: background,
              shape: shape,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  customBorder: shape,
                  mouseCursor: SystemMouseCursors.click,
                  onTap: () => FullPlayerSheet.show(context),
                  child: MiniPlayerSwipe(
                    onSwipe: (next) => ConnectActions.run(
                      context,
                      next ? connect.skipNext : connect.skipPrevious,
                    ),
                    child: Stack(
                      children: [
                        _RemoteMiniRow(
                          imageUrl: imageUrl,
                          title: track?.name ?? player.title,
                          trackKey: player.trackUri,
                        ),
                        // 细进度线：左右内缩到胶囊直线段内
                        Positioned(
                          left: 28,
                          right: 28,
                          bottom: 3,
                          child: MiniPlayerFoldAway(
                            fold: MiniPlayerDock.maybeOf(context),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(1),
                              child: RemoteProgressBuilder(
                                builder: (context, positionMs, durationMs) =>
                                    LinearProgressIndicator(
                                      value: durationMs <= 0
                                          ? 0
                                          : (positionMs / durationMs).clamp(
                                              0.0,
                                              1.0,
                                            ),
                                      minHeight: 2,
                                      backgroundColor:
                                          MiniPlayerStyle.foreground(
                                            context,
                                          ).withAlpha(40),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        MiniPlayerStyle.foreground(context),
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
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RemoteMiniRow extends StatelessWidget {
  final String imageUrl;
  final String title;
  final String trackKey;
  final bool showArtwork;

  const _RemoteMiniRow({
    required this.imageUrl,
    required this.title,
    required this.trackKey,
    this.showArtwork = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final connect = context.watch<ConnectProvider>();
    final device = connect.activeDevice;
    final playing = connect.player.isAudible;

    final artwork = MiniPlayerStyle.artworkSize(context);
    final foreground = MiniPlayerStyle.foreground(
      context,
      onSurface: showArtwork,
    );

    return Padding(
      padding: MiniPlayerStyle.rowPadding(context),
      child: Row(
        children: [
          if (showArtwork)
            PlayerArtworkHero(
              imageUrl: imageUrl,
              child: CoverImage(url: imageUrl, size: artwork, circular: true),
            )
          else
            SizedBox(width: artwork, height: artwork),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Column(
                key: ValueKey(trackKey),
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  MarqueeText(
                    key: PlayerExpansionSource.titleKey(context, trackKey),
                    text: title,
                    edgeFadeInset: 4,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        device == null
                            ? Icons.devices_rounded
                            : connectDeviceIcon(device.type),
                        size: 13,
                        color: tokens.accent,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          context.l10n.connectPlayingOn(device?.name ?? ''),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.accent,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Android 悬浮栏收起后让出宽度给歌名
          MiniPlayerFoldAway(
            fold: MiniPlayerDock.maybeOf(context),
            collapse: true,
            child: IconButton(
              tooltip: context.l10n.deviceConnectTitle,
              icon: Icon(Icons.devices_rounded, color: tokens.accent, size: 20),
              onPressed: () => DevicePickerSheet.show(context),
            ),
          ),
          SizedBox.square(
            dimension: 40,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: context.l10n.shortcutPlayPause,
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 26,
                color: foreground,
              ),
              onPressed: () =>
                  ConnectActions.run(context, connect.togglePlayPause),
            ),
          ),
        ],
      ),
    );
  }
}
