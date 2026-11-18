// 逆向实测：AP RequestKey 参数组合矩阵（file_id × gid/audio_id）+ file_urls_external 直链。
//
// 用法（app/ 目录）：dart run tool/key_matrix.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:flutify_app/services/protocol/access_point.dart';
import 'package:flutify_app/core/utils/spotify_id.dart';

Future<void> main() async {
  final prefs = jsonDecode(
    File('${Platform.environment['APPDATA']}\\com.flutify.music\\flutify_app\\shared_preferences.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final token = prefs['flutter.sp_access_token'] as String;

  // track-playback/v1/media 各 manifest 组合（顺带取 audio_id）
  final client = http.Client();
  final mediaRes = await client.get(
    Uri.parse('https://spclient.wg.spotify.com/track-playback/v1/media/spotify:track:0VjIjW4GlUZAMYd2vXMi3b'
        '?manifestFileFormat=file_ids_mp4&manifestFileFormat=file_urls_external&manifestFileFormat=file_urls_mp3&manifestFileFormat=file_ids_mp3'),
    headers: {
      'Authorization': 'Bearer $token',
      'client-token': prefs['flutter.sp_client_token'] as String,
    },
  );
  final media = jsonDecode(mediaRes.body) as Map<String, dynamic>;
  final item = (media['media'] as Map)['spotify:track:0VjIjW4GlUZAMYd2vXMi3b']['item'] as Map<String, dynamic>;
  final audioIdHex = (item['audio_id'] as String?) ?? 'fb294b68b1514ec12aa50fe0d77accf9';
  print('audio_id = $audioIdHex');
  final manifest = (item['manifest'] ?? {}) as Map<String, dynamic>;
  for (final e in manifest.entries) {
    print('manifest[${e.key}] = ${jsonEncode(e.value).substring(0, 200)}');
  }

  final gid = SpotifyId.fromUri('spotify:track:0VjIjW4GlUZAMYd2vXMi3b').raw;
  final audioId = audioIdHex == null ? null : Uint8List.fromList([
    for (var i = 0; i < 32; i += 2) int.parse(audioIdHex.substring(i, i + 2), radix: 16),
  ]);

  final files = <String, Uint8List>{
    'ogg320': _hex('4b47b6d3c1de4b23187c52032ad9904e6e5a9010'),
    'mp4_256': _hex('8cb0e0c29cf69c73610b788e775ec1e9461dd941'),
    'mp4_128': _hex('f6e2ff1804615a9cb45b63cbba993d3ba440eb4a'),
    'flac?': _hex('4c15ee84edf6cda3ae2204af493f507924b6b60d'),
    'aac24': _hex('d7a2810572092a42f7b287e29212c88a6ed0348c'),
  };

  final ap = await SpotifyAccessPoint.connect(client: client);
  try {
    await ap.authenticate(ApCredentials.accessToken(token), deviceId: prefs['flutter.sp_device_id'] as String?);
    print('AP 登录成功 user=${ap.canonicalUsername}');
    for (final fe in files.entries) {
      for (final ge in {
        'gid': gid,
        if (audioId != null) 'audioId': audioId!,
      }.entries) {
        try {
          final key = await ap.requestAudioKey(fe.value, ge.value);
          print('✅ ${fe.key} × ${ge.key} key=${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
        } catch (e) {
          print('❌ ${fe.key} × ${ge.key} -> $e');
        }
      }
    }
  } finally {
    ap.close();
    client.close();
  }
}

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ]);
