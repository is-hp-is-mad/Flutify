import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/flutify_tokens.dart';
import '../../core/utils/artwork_palette.dart';
import '../../l10n/l10n.dart';
import '../../models/track.dart';
import '../../providers/connect_provider.dart';
import '../../providers/playback_provider.dart';
import '../screens/player/device_picker_sheet.dart';
import '../screens/player/full_player_sheet.dart';
import '../screens/player/player_expansion.dart';
import 'connect/connect_actions.dart';
import 'connect/remote_mini_player.dart';
import 'cover_image.dart';
import 'marquee_text.dart';
import 'mini_player_frame.dart';
import 'playback_scrubber.dart';
import 'player_controls.dart';

/// 移动端悬浮胶囊迷你播放器（位于毛玻璃底部导航上方）。
///
/// - 胶囊形、背景色取自专辑封面并压暗（与 Spotify 一致），切歌时平滑过渡；
/// - 底部内缩的 2px 细进度线；
/// - 左右滑动切换上一首 / 下一首，点击展开全屏播放器；
/// - 只在切歌时重建；进度线与播放按钮各自局部订阅。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // 正在遥控其他设备时换成远程胶囊
    if (ConnectActions.showRemote(context)) return const RemoteMiniPlayer();
    final track = context.select<PlaybackProvider, SpotifyTrack?>(
      (p) => p.currentTrack,
    );
    if (track == null) return const SizedBox.shrink();

    // 方正风格下胶囊换成 16px 圆角矩形，其余风格保持胶囊
    final tokens = context.tokens;
    final ShapeBorder shape = tokens.squareCorners
        ? RoundedRectangleBorder(borderRadius: tokens.radius(16))
        : const StadiumBorder();

    return ArtworkColorBuilder(
      imageUrl: track.coverUrl,
      // 前景固定为白色，取色前 / 无封面时用深石墨色兜底（inverseSurface 在深色主题下是浅色）
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
            compactChild: _MiniPlayerRow(track: track, showArtwork: false),
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
                    onSwipe: (next) {
                      final playback = context.read<PlaybackProvider>();
                      next ? playback.nextTrack() : playback.previousTrack();
                    },
                    child: Stack(
                      children: [
                        _MiniPlayerRow(track: track),
                        // 细进度线：左右内缩到胶囊直线段内，避开两端圆弧
                        Positioned(
                          left: 28,
                          right: 28,
                          bottom: 3,
                          child: MiniPlayerFoldAway(
                            fold: MiniPlayerDock.maybeOf(context),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(1),
                              child: PlaybackProgressLine(
                                height: 2,
                                color: MiniPlayerStyle.foreground(context),
                                backgroundColor: MiniPlayerStyle.foreground(
                                  context,
                                ).withAlpha(40),
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

class _MiniPlayerRow extends StatelessWidget {
  final SpotifyTrack track;
  final bool showArtwork;

  const _MiniPlayerRow({required this.track, this.showArtwork = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 有远程会话（已暂停）时设备键高亮，提示可以转回去
    final activeDeviceName = context.select<ConnectProvider?, String?>(
      (c) => (c?.hasRemoteSession ?? false) ? c?.activeDevice?.name : null,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Android 悬浮栏：与导航同宽、不放设备键；心形随下沉收起，不看此刻的宽度
        final dock = MiniPlayerDock.maybeOf(context);
        final showDevice = dock == null && width >= 340;
        final showLike = dock != null || width >= 260;
        final artwork = MiniPlayerStyle.artworkSize(context);
        final foreground = MiniPlayerStyle.foreground(
          context,
          onSurface: showArtwork,
        );
        final secondary = MiniPlayerStyle.secondary(
          context,
          onSurface: showArtwork,
        );

        return Padding(
          padding: MiniPlayerStyle.rowPadding(context),
          child: Row(
            children: [
              if (showArtwork)
                PlayerArtworkHero(
                  imageUrl: track.coverUrl,
                  child: CoverImage(
                    url: track.coverUrl,
                    size: artwork,
                    circular: true,
                  ),
                )
              else
                SizedBox(width: artwork, height: artwork),
              const SizedBox(width: 12),

              // 歌名 / 艺人（或当前 Connect 设备）
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Column(
                    key: ValueKey(track.id),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MarqueeText(
                        key: PlayerExpansionSource.titleKey(context, track.id),
                        text: track.name,
                        edgeFadeInset: 4,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track.artistNames,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: secondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),

              if (showDevice)
                IconButton(
                  tooltip: activeDeviceName ?? context.l10n.deviceConnectTitle,
                  icon: Icon(
                    Icons.devices_rounded,
                    color: activeDeviceName != null
                        ? colorScheme.primary
                        : secondary,
                    size: 20,
                  ),
                  onPressed: () => DevicePickerSheet.show(context),
                ),

              if (showLike)
                MiniPlayerFoldAway(
                  fold: dock,
                  collapse: true,
                  child: LikeButton(
                    track: track,
                    size: 22,
                    inactiveColor: secondary,
                  ),
                ),

              PlayPauseButton(
                size: 40,
                iconSize: 26,
                background: Colors.transparent,
                foreground: foreground,
              ),
            ],
          ),
        );
      },
    );
  }
}
