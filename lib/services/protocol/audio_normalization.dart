import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;

/// Spotify 音频文件自带的响度数据（音量均衡用）。
///
/// 来源：Ogg 文件开头 0xa7 字节的 Spotify 私有头页里，偏移 144 起连续 4 个小端 float32：
/// track_gain_db、track_peak、album_gain_db、album_peak（librespot `NormalisationData`）。
/// 落盘时私有头会被剥掉（标准解码器不认识），因此解析结果另存为同名 `.norm` 旁路文件。
class AudioNormalization {
  final double trackGainDb;
  final double trackPeak;

  const AudioNormalization({required this.trackGainDb, required this.trackPeak});

  static const int headerOffset = 144;
  static const int byteLength = 16;

  /// 旁路文件扩展名（与音频文件同目录、同 file_id）。
  static const String sidecarExtension = 'norm';

  /// 播放器音量倍率。
  ///
  /// 按 librespot 的算法：增益 = 10^(gain_db / 20)，再用峰值限幅避免削波（增益 × 峰值 ≤ 1）。
  /// 播放器音量不能超过 1，所以只做衰减：偏响的歌调低，偏轻的歌保持原样。
  double get volumeFactor {
    if (RustCore.ready) {
      try {
        return rust.normalizationVolumeFactor(
          trackGainDb: trackGainDb,
          trackPeak: trackPeak,
        );
      } catch (_) {}
    }
    var gain = math.pow(10, trackGainDb / 20).toDouble();
    if (trackPeak > 0 && gain * trackPeak > 1) gain = 1 / trackPeak;
    return gain.clamp(0.0, 1.0);
  }

  /// 从 16 字节数据解析；数值明显不合理（损坏 / 非 Spotify 文件）时返回 null。
  static AudioNormalization? parse(Uint8List bytes) {
    if (bytes.length < byteLength) return null;
    if (RustCore.ready) {
      try {
        final info = rust.parseAudioNormalization(bytes: bytes);
        if (info == null) return null;
        return AudioNormalization(
          trackGainDb: info.trackGainDb,
          trackPeak: info.trackPeak,
        );
      } catch (_) {}
    }
    final data = ByteData.sublistView(bytes);
    final gain = data.getFloat32(0, Endian.little);
    final peak = data.getFloat32(4, Endian.little);
    if (!gain.isFinite || !peak.isFinite || gain.abs() > 40 || peak <= 0 || peak > 10) return null;
    return AudioNormalization(trackGainDb: gain, trackPeak: peak);
  }

  /// 读取 [audio] 旁边的 `.norm` 文件；不存在或损坏时返回 null（旧缓存没有旁路文件，按不均衡处理）。
  static AudioNormalization? readSidecar(File audio) {
    try {
      final file = sidecarFor(audio);
      if (!file.existsSync()) return null;
      return parse(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  static File sidecarFor(File audio) {
    final path = audio.path;
    final dot = path.lastIndexOf('.');
    final base = dot > path.lastIndexOf(Platform.pathSeparator) ? path.substring(0, dot) : path;
    return File('$base.$sidecarExtension');
  }
}
