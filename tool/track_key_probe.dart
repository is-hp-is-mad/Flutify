// 曲目 → 音频文件清单探针。
//
// 用法：dart run tool/track_key_probe.dart <trackId或URL>
// 输出：曲名、各格式 file_id。
import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/services/protocol/extended_metadata.dart';
import 'package:flutify_app/services/protocol/track_metadata.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/track_key_probe.dart <trackId|open.spotify.com/track/...>');
    exit(2);
  }
  // 从 URL 或裸 id 提取 base62 track id
  final m = RegExp(r'([0-9A-Za-z]{22})').firstMatch(args.first);
  if (m == null) {
    stderr.writeln('无法解析 track id: ${args.first}');
    exit(2);
  }
  final trackId = m.group(1)!;

  final prefs = jsonDecode(
    File('${Platform.environment['APPDATA']}\\com.flutify.music\\flutify_app\\shared_preferences.json').readAsStringSync(),
  ) as Map<String, dynamic>;
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
    // ExtendedMetadataClient 的构造参数是库内私有的，这里直接用其静态编解码方法发请求
    final uri = 'spotify:track:$trackId';
    final res = await client.post(
      Uri.parse('https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata'),
      headers: {
        ...await headers(),
        'Accept': 'application/protobuf',
        'Content-Type': 'application/protobuf',
      },
      body: ExtendedMetadataClient.buildRequest([uri], ExtensionKind.trackV4),
    );
    if (res.statusCode != 200) {
      stderr.writeln('extended-metadata HTTP ${res.statusCode}（401 就先跑 tool/refresh_token.dart）');
      exit(1);
    }
    final raw = ExtendedMetadataClient.parseResponse(res.bodyBytes, ExtensionKind.trackV4)[uri];
    if (raw == null) {
      stderr.writeln('extended-metadata 无 TRACK_V4 数据（401 就先跑 tool/refresh_token.dart）');
      exit(1);
    }
    final meta = TrackMetadata.parse(raw);
    stdout.writeln('曲目: ${meta.name} — ${meta.artistNames.join("/")} (${meta.durationMs}ms)');
    stdout.writeln('文件数: ${meta.files.length}（备选版本 ${meta.alternatives.length} 个）');
    for (final f in meta.files) {
      stdout.writeln('  ${f.format.name.padRight(14)} ${f.fileIdHex}');
    }
  } finally {
    client.close();
  }
}
