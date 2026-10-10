import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../models/track.dart';
import '../../widgets/connect/now_playing_source.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/liquid_glass.dart';
import '../../widgets/player_controls.dart';
import 'lyrics/lyrics_backdrop.dart';
import 'lyrics/lyrics_glass_controls.dart';
import 'lyrics/lyrics_view.dart';
import 'lyrics/lyrics_translation_controls.dart';
import 'player_modal.dart';

/// 同步歌词面板（Apple Music iOS 风格，手机 / 窄窗口使用）。
/// 遥控远程设备时同样可用（手机上点远程迷你播放器即打开它）。
///
/// 层级（自下而上）：
/// 1. 流动封面背景 [LyricsBackdrop]；
/// 2. 歌词滚动区 [LyricsView]，可从上下两块玻璃下方滚过；
/// 3. 顶部液态玻璃信息胶囊（封面 / 歌名 / 关闭）；
/// 4. 底部液态玻璃控制台 [LyricsGlassControls]。
class LyricsSheet extends StatelessWidget {
  const LyricsSheet({super.key});

  static const double _headerHeight = 140;
  static const double _controlsHeight = 150;

  static Future<void> show(BuildContext context) =>
      PlayerModal.show(context, (captureRoute) {
        return showModalBottomSheet(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: false,
          backgroundColor: Colors.transparent,
          builder: (sheetContext) {
            captureRoute(sheetContext);
            return const LyricsSheet();
          },
        );
      });

  @override
  Widget build(BuildContext context) {
    // 遥控远程设备时展示远程曲目，歌词按远程进度滚动、控制台作用于远程设备
    final remote = NowPlayingSource.isRemote(context);
    final track = NowPlayingSource.track(context);
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final corner = Radius.circular(context.tokens.corner(32));

    return LyricsTranslationScope(
      key: ValueKey((track?.id, remote)),
      child: ClipRRect(
        borderRadius: BorderRadius.vertical(top: corner),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.92,
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
                LyricsView(
                  appleMusicStyle:
                      !kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.android,
                  key: ValueKey((track.id, remote)),
                  track: track,
                  remote: remote,
                  topInset: _headerHeight,
                  bottomInset: _controlsHeight + bottomSafe,
                ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: _Header(track: track),
              ),
              if (track != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16 + bottomSafe,
                  child: const LyricsGlassControls(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部：拖拽条 + 玻璃信息胶囊。
class _Header extends StatelessWidget {
  final SpotifyTrack? track;

  const _Header({required this.track});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                if (track != null)
                  const Positioned(
                    top: 0,
                    right: 0,
                    child: LyricsTranslationButton(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          LiquidGlass(
            borderRadius: tokens.radius(22),
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            child: Row(
              children: [
                CoverImage(
                  url: track?.coverUrl ?? '',
                  size: 44,
                  borderRadius: tokens.radius(10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track?.name ?? context.l10n.lyricsTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track?.artistNames ?? context.l10n.lyricsNotPlaying,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (track != null)
                  LikeButton(
                    track: track!,
                    size: 22,
                    inactiveColor: Colors.white70,
                  ),
                IconButton(
                  icon: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  tooltip: context.l10n.commonClose,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
