import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../models/track.dart';
import '../../screens/player/immersive_lyrics_screen.dart';
import '../../screens/player/lyrics/glass_icon_button.dart';
import '../../screens/player/lyrics/lyrics_backdrop.dart';
import '../../screens/player/lyrics/lyrics_view.dart';
import '../../screens/player/lyrics/lyrics_translation_controls.dart';
import '../../widgets/cover_image.dart';
import '../../widgets/marquee_text.dart';
import '../shell_layout_controller.dart';

/// 右栏「正在播放」面板里的歌词卡：与全屏歌词同一套液态玻璃观感（流动封面背景 + 白色对焦歌词）。
///
/// - 内嵌（[expanded] 为 false）：固定高度，夹在歌名与「关于艺人」之间，左上角标「歌词」；
/// - 放大（[expanded] 为 true）：撑满整个面板，左上角改为小封面 + 歌名 / 艺人，方便确认在听什么。
///
/// 右上角两枚玻璃按钮：放大 / 收起（切换 [ShellLayoutController.lyricsExpanded]）与进入沉浸式歌词。
class PanelLyricsCard extends StatelessWidget {
  final SpotifyTrack track;
  final bool remote;
  final bool expanded;

  const PanelLyricsCard({
    super.key,
    required this.track,
    required this.remote,
    required this.expanded,
  });

  /// 顶部按钮条的高度：歌词从它下方开始滚动，避免第一行被按钮压住。
  static const double _barHeight = 56;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final layout = context.read<ShellLayoutController>();

    return LyricsTranslationScope(
      key: ValueKey((track.id, remote)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropGroup(
          child: _withBackdrop(
            context,
            LyricsBackdrop(imageUrl: track.coverUrl),
            Stack(
              fit: StackFit.expand,
              children: [
                LyricsView(
                  key: ValueKey((track.id, remote)),
                  track: track,
                  remote: remote,
                  topInset: _barHeight + (expanded ? 8 : 0),
                  bottomInset: 16,
                  // 与全屏歌词同一套 Apple 样式（对焦模糊、逐行滚动、翻译小字），
                  // 只是字号 / 留白按右栏宽度缩小
                  appleMusicStyle: true,
                  appleFontSize: expanded ? 28 : 24,
                  applePadding: 22,
                ),
                // 顶部渐暗：保证按钮与标题在任何封面色上都清晰
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: _barHeight + 16,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), Color(0x00000000)],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 10,
                  top: 10,
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: expanded
                            ? _TrackLabel(track: track)
                            : _CardLabel(text: l10n.lyricsTitle),
                      ),
                      const LyricsTranslationButton(),
                      const SizedBox(width: 8),
                      GlassIconButton(
                        icon: expanded
                            ? Icons.close_fullscreen_rounded
                            : Icons.open_in_full_rounded,
                        tooltip: expanded
                            ? l10n.lyricsCollapse
                            : l10n.lyricsExpand,
                        size: 36,
                        onPressed: layout.toggleLyricsExpanded,
                      ),
                      const SizedBox(width: 8),
                      GlassIconButton(
                        icon: Icons.fullscreen_rounded,
                        tooltip: l10n.lyricsImmersive,
                        size: 36,
                        onPressed: () => ImmersiveLyricsScreen.open(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 内嵌态左上角的「歌词」标签。
class _CardLabel extends StatelessWidget {
  final String text;

  const _CardLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// 放大态左上角：小封面 + 歌名 / 艺人（白字）。
class _TrackLabel extends StatelessWidget {
  final SpotifyTrack track;

  const _TrackLabel({required this.track});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        CoverImage(
          url: track.coverUrl,
          size: 34,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(
                text: track.name,
                style: textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              Text(
                track.artistNames,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: Colors.white.withAlpha(190),
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

/// 材质为「柔光玻璃」时以歌词背景为 [HyperGlassScene] 的采样源，右上角的玻璃按钮
/// 画成真正的柔光玻璃（与全屏歌词同一套）；否则保持原来的背景 + 内容叠放。
Widget _withBackdrop(BuildContext context, Widget backdrop, Widget content) {
  final tokens = context.tokens;
  if (tokens.hyperMaterial && !tokens.powerSaving) {
    return HyperGlassScene(
      background: backdrop,
      captureScale: 0.25,
      child: content,
    );
  }
  return Stack(fit: StackFit.expand, children: [backdrop, content]);
}
