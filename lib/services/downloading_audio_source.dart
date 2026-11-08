// StreamAudioSource 是 just_audio 提供自定义字节源的唯一方式（标注为实验性，升级 just_audio 时需留意）。
// ignore_for_file: experimental_member_use

import 'package:just_audio/just_audio.dart';

import 'protocol/progressive_download.dart';

/// 把边下边播的 [ProgressiveAudio] 交给 just_audio。
///
/// just_audio 会在本机起一个 HTTP 代理，播放器（Windows 上为 media_kit / mpv，
/// Android 上为 ExoPlayer）按 Range 请求字节区间；区间内未下载到的部分由
/// [ProgressiveAudio.read] 等待下载推进后再返回，因此拖动到未下载处会短暂缓冲而不是失败。
class DownloadingAudioSource extends StreamAudioSource {
  final ProgressiveAudio audio;

  DownloadingAudioSource(this.audio, {super.tag});

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final length = audio.length;
    final from = (start ?? 0).clamp(0, length);
    final to = (end ?? length).clamp(from, length);
    return StreamAudioResponse(
      sourceLength: length,
      contentLength: to - from,
      offset: from,
      contentType: audio.contentType,
      stream: audio.read(from, to),
    );
  }
}
