import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../core/utils/spotify_id.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../auth/proto_codec.dart';

/// 曲目音频文件格式（`metadata.proto` AudioFile.Format）。
enum AudioFileFormat {
  oggVorbis96(0, 'ogg'),
  oggVorbis160(1, 'ogg'),
  oggVorbis320(2, 'ogg'),
  mp3_256(3, 'mp3'),
  mp3_320(4, 'mp3'),
  mp3_160(5, 'mp3'),
  mp3_96(6, 'mp3'),
  mp3_160Enc(7, 'mp3'),
  aac24(8, 'm4a'),
  aac48(9, 'm4a'),
  flac(16, 'flac'),
  xheAac24(18, 'm4a'),
  xheAac16(19, 'm4a'),
  xheAac12(20, 'm4a'),
  flac24Bit(22, 'flac');

  final int wireValue;
  final String extension;

  const AudioFileFormat(this.wireValue, this.extension);

  static AudioFileFormat? fromWire(int value) {
    for (final f in AudioFileFormat.values) {
      if (f.wireValue == value) return f;
    }
    return null;
  }
}

/// 默认格式偏好：先无损、后高码率有损；OGG/MP3 兼容面最大（iOS 端可把 MP3 提前）。
const List<AudioFileFormat> kDefaultFormatPreference = [
  AudioFileFormat.flac,
  AudioFileFormat.flac24Bit,
  AudioFileFormat.oggVorbis320,
  AudioFileFormat.oggVorbis160,
  AudioFileFormat.mp3_320,
  AudioFileFormat.mp3_256,
  AudioFileFormat.mp3_160,
  AudioFileFormat.oggVorbis96,
  AudioFileFormat.mp3_96,
  AudioFileFormat.aac24,
  AudioFileFormat.aac48,
  AudioFileFormat.xheAac24,
  AudioFileFormat.xheAac16,
  AudioFileFormat.xheAac12,
  AudioFileFormat.mp3_160Enc,
];

/// 协议链路（AP 音频密钥 + AES-CTR）可解的格式，按音质从高到低。
///
/// FLAC / AAC / xHE-AAC 走 Widevine（CENC），AP 不下发密钥，无法在此链路播放，故不列入。
/// 免费账号拿不到 320k 的密钥，加载器会在密钥被拒时自动降到下一档。
const List<AudioFileFormat> kPlayableFormatPreference = [
  AudioFileFormat.oggVorbis320,
  AudioFileFormat.oggVorbis160,
  AudioFileFormat.mp3_320,
  AudioFileFormat.mp3_256,
  AudioFileFormat.mp3_160,
  AudioFileFormat.oggVorbis96,
  AudioFileFormat.mp3_96,
];

/// metadata 里的一个音频文件（file_id + format）。
class TrackAudioFile {
  final Uint8List fileId; // 20 字节 SHA-1
  final AudioFileFormat format;

  const TrackAudioFile({required this.fileId, required this.format});

  String get fileIdHex {
    final sb = StringBuffer();
    for (final b in fileId) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  String get extension => format.extension;
}

/// `metadata/4/track/{gid}`（或 extended-metadata）返回的 `metadata.proto.Track` 解析结果。
class TrackMetadata {
  final Uint8List gid;
  final String name;
  final String albumName;
  final List<String> artistNames;
  final int durationMs;
  final bool explicit;
  final List<TrackAudioFile> files;

  /// 备选版本（同曲其他版本，可能带可用文件）。
  final List<TrackMetadata> alternatives;

  const TrackMetadata({
    required this.gid,
    required this.name,
    required this.albumName,
    required this.artistNames,
    required this.durationMs,
    required this.explicit,
    required this.files,
    this.alternatives = const [],
  });

  /// 本曲（含备选版本）是否带有任何音频文件（不论格式）。
  bool get hasAnyFile => files.isNotEmpty || alternatives.any((a) => a.hasAnyFile);

  /// 按 [preference] 选最优文件；本曲没有时递归查 [alternatives]。
  TrackAudioFile? selectFile([List<AudioFileFormat> preference = kDefaultFormatPreference]) {
    for (final format in preference) {
      for (final f in files) {
        if (f.format == format) return f;
      }
    }
    for (final alt in alternatives) {
      final f = alt.selectFile(preference);
      if (f != null) return f;
    }
    return null;
  }

  /// 按 [preference] 顺序列出全部候选文件（本曲优先，其次备选版本），供逐个尝试密钥。
  ///
  /// 音频密钥按「file_id + 所属曲目 gid」请求，备选版本要用它自己的 gid，因此一并返回。
  List<({TrackAudioFile file, Uint8List gid})> candidateFiles([
    List<AudioFileFormat> preference = kPlayableFormatPreference,
  ]) {
    final out = <({TrackAudioFile file, Uint8List gid})>[];
    for (final format in preference) {
      for (final f in files) {
        if (f.format == format) out.add((file: f, gid: gid));
      }
    }
    for (final alt in alternatives) {
      out.addAll(alt.candidateFiles(preference));
    }
    return out;
  }

  /// 解析 protobuf `Track`（宽松：未知字段跳过）。
  factory TrackMetadata.parse(Uint8List data) {
    if (RustCore.ready) {
      try {
        final dto = rust.rustParseTrackMetadataProto(data: data);
        return _fromProtoDto(dto);
      } catch (_) {}
    }
    return _parseTrack(ProtoReader(data));
  }

  static TrackMetadata _fromProtoDto(rust.RustProtoTrackMetadataDto dto) =>
      TrackMetadata(
        gid: dto.gid,
        name: dto.name,
        albumName: dto.albumName,
        artistNames: dto.artistNames,
        durationMs: dto.durationMs,
        explicit: dto.explicit,
        files: [
          for (final f in dto.files)
            if (AudioFileFormat.fromWire(f.format) != null)
              TrackAudioFile(
                fileId: f.fileId,
                format: AudioFileFormat.fromWire(f.format)!,
              ),
        ],
        alternatives: [for (final a in dto.alternatives) _fromProtoDto(a)],
      );

  static TrackMetadata _parseTrack(ProtoReader reader) {
    final gid = Uint8List(16);
    var name = '';
    var albumName = '';
    final artistNames = <String>[];
    var durationMs = 0;
    var explicit = false;
    final files = <TrackAudioFile>[];
    final alternatives = <TrackMetadata>[];

    reader.forEach((f) {
      switch (f.number) {
        case 1 when f.wireType == 2:
          final raw = f.bytesValue;
          if (raw.length == 16) gid.setRange(0, 16, raw);
          break;
        case 2 when f.wireType == 2:
          name = f.asString;
          break;
        case 3 when f.wireType == 2: // album
          f.asMessage.forEach((af) {
            if (af.number == 2 && af.wireType == 2) albumName = af.asString;
          });
          break;
        case 4 when f.wireType == 2: // artist
          f.asMessage.forEach((af) {
            if (af.number == 2 && af.wireType == 2) artistNames.add(af.asString);
          });
          break;
        case 7 when f.wireType == 0: // duration (sint32, 毫秒)
          durationMs = _zigzag32(f.varintValue);
          break;
        case 9 when f.wireType == 0: // explicit
          explicit = f.varintValue != 0;
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
        case 13 when f.wireType == 2: // alternative
          alternatives.add(_parseTrack(f.asMessage));
          break;
      }
    });

    return TrackMetadata(
      gid: gid,
      name: name,
      albumName: albumName,
      artistNames: artistNames,
      durationMs: durationMs,
      explicit: explicit,
      files: files,
      alternatives: alternatives,
    );
  }

  static int _zigzag32(int value) => (value >> 1) ^ -(value & 1);
}

/// base62 track id → 16 字节 GID 的便捷入口。
Uint8List trackGidFromId(String base62OrUri) => SpotifyId.fromUri(base62OrUri).raw;
