// 播客单集探针：验证「单集音频走与曲目相同的协议链路」是否可行。
//
// 用法：dart run tool/episode_probe.dart <episodeId或URL>
//   1) extended-metadata 依次尝试 EPISODE_V4(3) / AUDIO_FILES(5)，dump 原始响应结构；
//   2) 若拿到载荷，递归 dump proto 字段（字段号 / wire type / 长度 / 字符串预览），
//      并定位 AudioFile 子消息（20 字节 file_id + format varint）。
import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/services/auth/proto_codec.dart';
import 'package:flutify_app/services/protocol/extended_metadata.dart';
import 'package:flutify_app/core/utils/spotify_id.dart';
import 'package:http/http.dart' as http;

/// base62 episode id → 16 字节 gid 的 hex。
String _gidHex(String episodeId) =>
    SpotifyId.fromUri('spotify:episode:$episodeId').toBase16();

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/episode_probe.dart <episodeId|open.spotify.com/episode/...>',
    );
    exit(2);
  }
  final m = RegExp(r'([0-9A-Za-z]{22})').firstMatch(args.first);
  if (m == null) {
    stderr.writeln('无法解析 episode id: ${args.first}');
    exit(2);
  }
  final episodeId = m.group(1)!;
  final uri = 'spotify:episode:$episodeId';
  stdout.writeln('episode: $uri');

  final prefs =
      jsonDecode(
            File(
              '${Platform.environment['APPDATA']}\\com.flutify.music\\flutify_app\\shared_preferences.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final token = prefs['flutter.sp_access_token'] as String;
  final ct = prefs['flutter.sp_client_token'] as String;
  Future<Map<String, String>> headers() async => {
    'Authorization': 'Bearer $token',
    'client-token': ct,
    'User-Agent': 'Spotify/130100234 Win32_x86_64/0 (PC desktop)',
    'app-platform': 'Win32_x86_64',
    'spotify-app-version': '1.3.1.234.g59d6bf59',
  };

  final client = http.Client();
  try {
    // 0) metadata/4/episode/{gidHex}：单集完整元数据（含正式音频 file 列表）
    //    同时试 AUDIO_FILES 响应头里出现的另一个 32 位 hex（可能是内部 gid）。
    for (final gidHex in [
      _gidHex(episodeId),
      'aa7b168faf743604c5f53d8c84d1027a',
    ]) {
      stdout.writeln('--- metadata/4/episode/$gidHex ---');
      final metaRes = await client.get(
        Uri.parse('https://spclient.wg.spotify.com/metadata/4/episode/$gidHex'),
        headers: await headers(),
      );
      stdout.writeln(
        'HTTP ${metaRes.statusCode}, ${metaRes.bodyBytes.length} bytes',
      );
      if (metaRes.statusCode == 200) {
        _dump(ProtoReader(metaRes.bodyBytes), 0, 2);
        final files = _findAudioFiles(ProtoReader(metaRes.bodyBytes));
        stdout.writeln('音频文件: ${files.length} 个');
        for (final f in files) {
          final hex = f.$2
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          stdout.writeln('  field#${f.$1}  $hex');
        }
      }
    }

    for (final kind in [3, 5]) {
      stdout.writeln('--- extension kind $kind ---');
      final res = await client.post(
        Uri.parse(
          'https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata',
        ),
        headers: {
          ...await headers(),
          'Accept': 'application/protobuf',
          'Content-Type': 'application/protobuf',
        },
        body: ExtendedMetadataClient.buildRequest([uri], kind),
      );
      if (res.statusCode != 200) {
        stdout.writeln(
          'HTTP ${res.statusCode}（401 就先跑 tool/refresh_token.dart）',
        );
        continue;
      }
      stdout.writeln('response ${res.bodyBytes.length} bytes:');
      _dump(ProtoReader(res.bodyBytes), 0, 4);
      final raw = ExtendedMetadataClient.parseResponse(
        res.bodyBytes,
        kind,
      )[uri];
      if (raw == null) {
        stdout.writeln('（无 status=200 的载荷）');
        continue;
      }
      stdout.writeln('>>> payload ${raw.length} bytes:');
      _dump(ProtoReader(raw), 0);
      final files = _findAudioFiles(ProtoReader(raw));
      stdout.writeln('音频文件: ${files.length} 个');
      for (final f in files) {
        final hex = f.$2.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        stdout.writeln('  field#${f.$1}  $hex');
      }
    }
  } finally {
    client.close();
  }
}

/// 递归 dump proto 结构（缩进表示层级）。
void _dump(ProtoReader reader, int depth, [int maxDepth = 3]) {
  final indent = '  ' * depth;
  reader.forEach((f) {
    final info = switch (f.wireType) {
      0 => 'varint=${f.varintValue}',
      2 => () {
        final b = f.bytesValue;
        String? preview;
        try {
          final s = utf8.decode(b);
          if (s.runes.every((r) => r >= 32 && r != 127))
            preview = s.length > 60 ? '${s.substring(0, 60)}…' : s;
        } catch (_) {}
        return 'len=${b.length}${preview != null ? ' "$preview"' : ''}';
      }(),
      _ => 'wire=${f.wireType}',
    };
    stdout.writeln('$indent#${f.number} $info');
    if (f.wireType == 2 && depth < maxDepth && f.bytesValue.length >= 2) {
      try {
        _dump(f.asMessage, depth + 1, maxDepth);
      } catch (_) {}
    }
  });
}

/// 在 proto 里找 AudioFile 子消息（含 20 字节 file_id + format varint），返回 (字段号, fileId)。
List<(int, List<int>)> _findAudioFiles(ProtoReader reader, [int depth = 0]) {
  final out = <(int, List<int>)>[];
  if (depth > 3) return out;
  reader.forEach((f) {
    if (f.wireType != 2) return;
    final bytes = f.bytesValue;
    try {
      List<int>? fileId;
      var hasFormat = false;
      f.asMessage.forEach((ff) {
        if (ff.number == 1 && ff.wireType == 2 && ff.bytesValue.length == 20)
          fileId = ff.bytesValue;
        if (ff.number == 2 && ff.wireType == 0) hasFormat = true;
      });
      if (fileId != null && hasFormat) {
        out.add((f.number, fileId!));
      } else if (bytes.length >= 2) {
        out.addAll(_findAudioFiles(f.asMessage, depth + 1));
      }
    } catch (_) {}
  });
  return out;
}
