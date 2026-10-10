import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../widgets/liquid_artwork_background.dart';
import '../../../widgets/apple_music_background.dart';

/// 所有歌词界面共用的液态背景：封面流动模糊 + 压暗层。
///
/// 全屏歌词、全屏播放器的歌词视图、桌面右栏歌词、沉浸式歌词都使用它，观感一致。
/// 与 Android 原生背景一致：暂停时背景仍缓慢流动；仅在「减弱动效」或省电模式下停止流动。
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
    final animate = !context.reduceMotion && !context.tokens.powerSaving;
    // 与 Android 原生背景同一配方：黑底、同样的旋转/饱和度/压暗/模糊
    return LiquidArtworkBackground(
      imageUrl: imageUrl,
      animate: animate,
      dark: Theme.of(context).brightness == Brightness.dark,
    );
  }
}
