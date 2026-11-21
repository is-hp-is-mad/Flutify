import 'package:flutter/material.dart';

import 'cover_image.dart';
import 'motion_video.dart';

/// 静音循环的竖版短视频（官方 Canvas / 发现流卡片）：直接流式播放 CDN 地址。
///
/// 四端（Windows / macOS / Linux / Android）统一经 [MotionVideo] 原生纹理渲染，
/// 不再创建平台视图 WebView：
/// - 只有 [active] 为 true 时才创建原生播放器，否则只画 [posterUrl]（视频首帧，切换无跳变）；
/// - [playing] 控制已创建的视频暂停 / 继续（轻点暂停时不销毁，避免画面闪回首帧）；
/// - 封面始终叠在视频上方，首帧出来后淡出；加载失败或 10 秒超时退回封面。
class LoopingVideo extends StatelessWidget {
  const LoopingVideo({
    super.key,
    required this.videoUrl,
    this.posterUrl = '',
    this.active = true,
    this.playing = true,
  });

  final String videoUrl;

  /// 视频首帧 / 封面；视频未就绪或未激活时显示。
  final String posterUrl;

  /// 是否创建视频（不在屏幕焦点上的卡片传 false）。
  final bool active;

  /// 已创建的视频是否播放。
  final bool playing;

  @override
  Widget build(BuildContext context) {
    return MotionVideo(
      url: videoUrl,
      placeholder: CoverImage(url: posterUrl),
      active: active,
      playing: playing,
    );
  }
}
