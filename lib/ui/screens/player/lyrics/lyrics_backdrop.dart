import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../core/utils/artwork_palette.dart';
import '../../../widgets/connect/now_playing_source.dart';
import '../../../widgets/liquid_artwork_background.dart';
import '../../../widgets/apple_music_background.dart';

/// 所有歌词界面共用的液态背景：封面流动模糊 + 压暗层。
///
/// 全屏歌词、全屏播放器的歌词视图、桌面右栏歌词、沉浸式歌词都使用它，观感一致。
/// 单独订阅播放状态（本机或正在遥控的远程设备）：暂停或「减弱动效」时停止流动，且不牵连歌词重建。
class LyricsBackdrop extends StatelessWidget {
  final String imageUrl;
  final bool reducedEffects;

  const LyricsBackdrop({
    super.key,
    required this.imageUrl,
    this.reducedEffects = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AppleMusicBackground(
        imageUrl: imageUrl,
        reducedEffects: reducedEffects,
      );
    }
    final isPlaying = NowPlayingSource.isPlaying(context);
    final animate =
        isPlaying && !context.reduceMotion && !context.tokens.powerSaving;
    return ArtworkColorBuilder(
      imageUrl: imageUrl,
      fallback: const Color(0xFF1E2838),
      builder: (context, artColor) => LiquidArtworkBackground(
        imageUrl: imageUrl,
        fallback: Color.lerp(artColor, Colors.black, 0.35)!,
        animate: animate,
      ),
    );
  }
}
