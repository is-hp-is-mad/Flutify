// Mercury 探针：通过 AP 的 hm:// 接口取单集完整元数据（含正式音频 file 列表）。
//
// 用法：dart run tool/mercury_probe.dart <episodeId或URL>
// 输出：Episode proto 的字段结构 dump + 定位到的 AudioFile（20 字节 file_id + format）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutify_app/services/auth/proto_codec.dart';
import 'package:flutify_app/services/protocol/access_point.dart';
import 'package:flutify_app/core/utils/spotify_id.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/mercury_probe.dart <episodeId|open.spotify.com/episode/...>',
    );
    exit(2);
  }
  final m = RegExp(r'([0-9A-Za-z]{22})').firstMatch(args.first);
  if (m == null) {
    stderr.writeln('无法解析 episode id: ${args.first}');
    exit(2);
  }
  final gidHex = SpotifyId.fromUri('spotify:episode:${m.group(1)}').toBase16();
  stdout.writeln('episode gid: $gidHex');

  final prefs =
      jsonDecode(
            File(
              '${Platform.environment['APPDATA']}\\com.flutify.music\\flutify_app\\shared_preferences.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final token = prefs['flutter.sp_access_token'] as String;

  // AP 连接、握手与登录由 Rust 核心完成（需已加载 Rust 核心）
  final ap = await SpotifyAccessPoint.connect();
  try {
    await ap.authenticate(ApCredentials.accessToken(token));
    stdout.writeln('AP 登录成功：${ap.canonicalUsername}, closed=${ap.isClosed}');
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      stdout.writeln('  t+${i + 1}s closed=${ap.isClosed}');
      if (ap.isClosed) break;
    }
    Uint8List body;
    try {
      body = await ap.requestMercury('hm://metadata/4/episode/$gidHex');
    } catch (e) {
      stdout.writeln('mercury 失败：$e (closed=${ap.isClosed})');
      rethrow;
    }
    stdout.writeln('metadata/4/episode: ${body.length} bytes');
    _dump(ProtoReader(body), 0, 2);
    final files = _findAudioFiles(ProtoReader(body));
    stdout.writeln('音频文件: ${files.length} 个');
    for (final f in files) {
      final hex = f.$2.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      stdout.writeln('  field#${f.$1}  $hex');
    }
    // 逐档试取音频密钥（只报成功与否）
    final gid = SpotifyId.fromUri('spotify:episode:${m.group(1)}').raw;
    for (final f in files.where((f) => f.$1 == 12)) {
      try {
        final key = await ap.requestAudioKey(Uint8List.fromList(f.$2), gid);
        final hex = f.$2.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        stdout.writeln('  密钥 OK：$hex（${key.length} 字节）');
      } catch (e) {
        final hex = f.$2.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        stdout.writeln('  密钥失败：$hex — $e');
      }
    }

    // 对照组：同一 AP 会话请求普通曲目的音频密钥（Blinding Lights）
    try {
      final trackGid = SpotifyId.fromUri(
        'spotify:track:0VjIjW4GlUZAMYd2vXMi3b',
      );
      final trackMeta = await ap.requestMercury(
        'hm://metadata/4/track/${trackGid.toBase16()}',
      );
      final trackFiles = _findAudioFiles(ProtoReader(trackMeta));
      if (trackFiles.isNotEmpty) {
        final key = await ap.requestAudioKey(
          Uint8List.fromList(trackFiles.first.$2),
          trackGid.raw,
        );
        stdout.writeln('对照组（曲目）密钥 OK：${key.length} 字节');
      } else {
        stdout.writeln('对照组：曲目无音频文件字段');
      }
    } catch (e) {
      stdout.writeln('对照组（曲目）失败：$e');
    }

    // 播客音频不加密：直接 storage-resolve + 下载头部验证魔数
    final httpClient = HttpClient();
    try {
      // 选 OGG_VORBIS_96（format=0，第三个 #12 文件）：播客若免密钥解密，这个格式应能直接播
      final fileHex = '817868f8045cfb4ee76a51d7a3873367a1fa70af';
      final resolveReq = await httpClient.getUrl(
        Uri.parse(
          'https://spclient.wg.spotify.com/storage-resolve/files/audio/interactive/$fileHex?version=10000000',
        ),
      );
      resolveReq.headers.set('Authorization', 'Bearer $token');
      resolveReq.headers.set('Accept', 'application/protobuf');
      final resolveRes = await resolveReq.close();
      final resolveBytes = await resolveRes.expand((c) => c).toList();
      stdout.writeln(
        'storage-resolve: HTTP ${resolveRes.statusCode}, ${resolveBytes.length} bytes',
      );
      if (resolveRes.statusCode == 200) {
        // StorageResolveResponse：result=1 varint（0=CDN），cdnurl=2 repeated string
        final urls = <String>[];
        ProtoReader(Uint8List.fromList(resolveBytes)).forEach((f) {
          if (f.number == 2 && f.wireType == 2) urls.add(f.asString);
        });
        stdout.writeln('cdnurl: ${urls.length} 个');
        if (urls.isNotEmpty) {
          final req = await httpClient.getUrl(Uri.parse(urls.first));
          req.headers.set('Range', 'bytes=0-63');
          final res = await req.close();
          final bytes = await res.expand((c) => c).toList();
          final hex = bytes
              .take(32)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(' ');
          final ascii = bytes
              .take(64)
              .map((b) => b >= 32 && b < 127 ? String.fromCharCode(b) : '.')
              .join();
          stdout.writeln('下载 HTTP ${res.statusCode}');
          stdout.writeln('hex: $hex');
          stdout.writeln('ascii: $ascii');
        }
      }
    } finally {
      httpClient.close();
    }
  } finally {
    ap.close();
  }
}

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
