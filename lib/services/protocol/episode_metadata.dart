import 'dart:typed_data';

import '../auth/proto_codec.dart';
import 'track_metadata.dart';

/// `hm://metadata/4/episode/{gid}`（Mercury over AP）返回的 `metadata.proto.Episode` 解析结果。
///
/// 字段号经 tool/mercury_probe.dart 实测（2026-10，桌面版会话）：
/// - 1 = gid（16 字节）；2 = 标题；7 = 时长（毫秒，普通 varint，非 zigzag）；
/// - 12 = 音频文件（AudioFile：1 = file_id(20B)，2 = format）；
/// - 64 = 简介；68 = 封面 ImageGroup；71 = 所属节目（1 = gid，2 = 名称）。
///
/// 与曲目的差异：单集音频 AP 不下发音频密钥（错误码 0），文件本身仍是加密存储 ——
/// 当前无法解密播放，解析结果主要用于展示与「尝试播放 → 友好报错」链路。
class EpisodeMetadata {
  final Uint8List gid;
  final String name;
  final String showName;
  final int durationMs;
  final String description;
  final List<TrackAudioFile> files;

  const EpisodeMetadata({
    required this.gid,
    required this.name,
    this.showName = '',
    this.durationMs = 0,
    this.description = '',
    this.files = const [],
  });

  /// 本集是否带有任何音频文件（不论格式）。
  bool get hasAnyFile => files.isNotEmpty;

  /// 按 [preference] 顺序列出全部候选文件（供逐个尝试密钥）。
  List<({TrackAudioFile file, Uint8List gid})> candidateFiles([
    List<AudioFileFormat> preference = kPlayableFormatPreference,
  ]) {
    final out = <({TrackAudioFile file, Uint8List gid})>[];
    for (final format in preference) {
      for (final f in files) {
        if (f.format == format) out.add((file: f, gid: gid));
      }
    }
    return out;
  }

  /// 解析 protobuf `Episode`（宽松：未知字段跳过）。
  factory EpisodeMetadata.parse(Uint8List data) {
    final gid = Uint8List(16);
    var name = '';
    var showName = '';
    var durationMs = 0;
    var description = '';
    final files = <TrackAudioFile>[];

    ProtoReader(data).forEach((f) {
      switch (f.number) {
        case 1 when f.wireType == 2:
          final raw = f.bytesValue;
          if (raw.length == 16) gid.setRange(0, 16, raw);
          break;
        case 2 when f.wireType == 2:
          name = f.asString;
          break;
        case 7 when f.wireType == 0:
          durationMs = f.varintValue;
          break;
        case 12 when f.wireType == 2: // file
          final fileId = Uint8List(20);
          var format = -1;
          f.asMessage.forEach((ff) {
            if (ff.number == 1 && ff.wireType == 2) {
              final raw = ff.bytesValue;
              if (raw.length == 20) fileId.setRange(0, 20, raw);
            }
            if (ff.number == 2 && ff.wireType == 0) format = ff.varintValue;
          });
          final fmt = AudioFileFormat.fromWire(format);
          if (fmt != null && fileId.any((b) => b != 0)) {
            files.add(TrackAudioFile(fileId: fileId, format: fmt));
          }
          break;
        case 64 when f.wireType == 2:
          description = f.asString;
          break;
        case 71 when f.wireType == 2: // show
          f.asMessage.forEach((sf) {
            if (sf.number == 2 && sf.wireType == 2) showName = sf.asString;
          });
          break;
      }
    });

    return EpisodeMetadata(
      gid: gid,
      name: name,
      showName: showName,
      durationMs: durationMs,
      description: description,
      files: files,
    );
  }
}
