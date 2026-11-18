// 开发工具：定位 RequestKey 被拒原因（打印 gid / file_id / 各档位密钥请求结果）。
//
// 用法（在 app/ 目录下）：
//   dart run tool/key_debug.dart [trackId]
//
// 输出不含令牌；gid / file_id 为公开元数据。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:flutify_app/services/protocol/access_point.dart';
import 'package:flutify_app/services/protocol/extended_metadata.dart';
import 'package:flutify_app/core/utils/spotify_id.dart';
import 'package:flutify_app/services/protocol/track_metadata.dart';

Future<void> main(List<String> args) async {
  final track = args.isEmpty ? '0VjIjW4GlUZAMYd2vXMi3b' : args.first;
  final prefs = jsonDecode(
    File('${Platform.environment['APPDATA']}\\com.flutify.music\\flutify_app\\shared_preferences.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final token = prefs['flutter.sp_access_token'] as String;
  final clientToken = prefs['flutter.sp_client_token'] as String;

  final headers = () async => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/x-protobuf',
        'client-token': clientToken,
      };

  final client = http.Client();
  final id = SpotifyId.fromUri(track);
  print('track=$track');
  print('gid from base62 id = ${id.toBase16()}');

  final payload = await ExtendedMetadataClient(client, headers: headers)
      .fetch('spotify:track:${id.toBase62()}', ExtensionKind.trackV4);
  print('TRACK_V4 payload ${payload?.length}B');
  if (payload == null) {
    print('!! 无 TRACK_V4 扩展');
    return;
  }
  final meta = TrackMetadata.parse(payload);
  print('parsed gid    = ${meta.gid.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
  print('name=${meta.name} duration=${meta.durationMs}ms files=${meta.files.length} alts=${meta.alternatives.length}');
  for (final f in meta.files) {
    print('  file ${f.format.name} fileId=${f.fileIdHex}');
  }
  for (final alt in meta.alternatives) {
    print('  alt gid=${alt.gid.map((b) => b.toRadixString(16).padLeft(2, '0')).join()} files=${alt.files.map((f) => f.format.name).toList()}');
  }

  // AP：登录后逐个候选请求密钥
  final ap = await SpotifyAccessPoint.connect(client: client);
  try {
    await ap.authenticate(ApCredentials.accessToken(token), deviceId: prefs['flutter.sp_device_id'] as String?);
    print('AP 登录成功 user=${ap.canonicalUsername}');

    for (final c in meta.candidateFiles()) {
      try {
        final key = await ap.requestAudioKey(c.file.fileId, c.gid);
        print('✅ ${c.file.format.name} fileId=${c.file.fileIdHex} key=${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      } catch (e) {
        print('❌ ${c.file.format.name} fileId=${c.file.fileIdHex} gid=${c.gid.map((b) => b.toRadixString(16).padLeft(2, '0')).join()} -> $e');
      }
    }

    // 对照：用 base62 解出的 gid 试第一个候选
    if (meta.files.isNotEmpty) {
      try {
        final key = await ap.requestAudioKey(meta.files.first.fileId, id.raw);
        print('✅ 用 base62-gid 拿到 key=${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      } catch (e) {
        print('❌ 用 base62-gid -> $e');
      }
    }
  } finally {
    ap.close();
    client.close();
  }
}

