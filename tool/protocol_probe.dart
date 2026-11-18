// 开发工具：完整曲目协议链路端到端探测（纯 Dart，无需运行 App；需要自行提供账号或令牌）。
//
// 用途：验证 access_token → 音频密钥 → CDN 解密整条播放链路；`--ap-check` 只做 AP 握手自检（无需凭据）。
// 用法（在 app/ 目录下）：
//   dart run tool/protocol_probe.dart --ap-check
//   dart run tool/protocol_probe.dart --token <access_token> --track spotify:track:0VjIjW4GlUZAMYd2vXMi3b --out D:\tmp
//
// 流程只走逆向协议：metadata/4 → storage-resolve → AP(RequestKey) → CDN 下载解密。
// 输出本地已解密的完整曲目（OGG/MP3/FLAC），并校验文件头（如 OggS）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutify_app/services/auth/auth_constants.dart';
import 'package:flutify_app/services/auth/client_token_service.dart';
import 'package:flutify_app/services/protocol/access_point.dart';
import 'package:flutify_app/services/protocol/aes.dart';
import 'package:flutify_app/core/utils/spotify_id.dart';
import 'package:flutify_app/services/protocol/storage_resolver.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/services/protocol/track_metadata.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);

  // ---- AP 握手自检（无需有效凭据）：验证 DH/Shannon/帧格式/MAC 全链路 ----
  if (opts.containsKey('ap-check')) {
    await _apCheck(opts['token'] ?? 'bogus-token-for-handshake-check');
    return;
  }

  final track = opts['track'];
  if (track == null) {
    stderr.writeln('缺少 --track <base62 id 或 spotify:track:...>');
    exit(2);
  }

  final client = http.Client();
  try {
    // ---- 1) access_token：由调用方给定（可从 App 设置页「复制令牌」取得） ----
    final accessToken = opts['token'] ?? '';
    String? clientTokenValue = opts['client-token'];
    final deviceId = SpotifyAuthConstants.generateDeviceId();

    if (accessToken.isEmpty) {
      stderr.writeln('需要 --token <access_token>');
      exit(2);
    }
    stdout.writeln('[1/6] 使用给定 access_token');
    if (clientTokenValue == null) {
      try {
        clientTokenValue = await ClientTokenService(client).request(deviceId).then((t) => t.token);
      } catch (e) {
        stdout.writeln('      client-token 申请失败（继续尝试）：$e');
      }
    }

    Future<Map<String, String>> headers() async => <String, String>{
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/x-protobuf',
          'client-token': ?clientTokenValue,
        };

    // ---- 2) metadata ----
    final id = SpotifyId.fromUri(track);
    stdout.writeln('[2/6] metadata/4/track/${id.toBase16()} ...');
    final metaRes = await client.get(
      Uri.parse('https://spclient.wg.spotify.com/metadata/4/track/${id.toBase16()}'),
      headers: await headers(),
    );
    if (metaRes.statusCode != 200) {
      stderr.writeln('metadata HTTP ${metaRes.statusCode}：${metaRes.body.substring(0, metaRes.body.length.clamp(0, 200))}');
      exit(1);
    }
    final meta = TrackMetadata.parse(metaRes.bodyBytes);
    stdout.writeln('      曲名=${meta.name} 专辑=${meta.albumName} '
        '时长=${meta.durationMs}ms 可选格式=${meta.files.map((f) => f.format.name).join(',')}');
    final file = meta.selectFile();
    if (file == null) {
      stderr.writeln('没有可下载的音频文件');
      exit(1);
    }
    stdout.writeln('      选中格式=${file.format.name} file_id=${file.fileIdHex}');

    // ---- 3) storage-resolve ----
    stdout.writeln('[3/6] storage-resolve ...');
    final storage = await resolveAudioStorage(
      fileIdHex: file.fileIdHex,
      headers: headers,
      client: client,
    );
    for (final url in storage.cdnUrls) {
      stdout.writeln('      CDN: $url');
    }

    // ---- 4) AP 握手 + 登录 + 音频密钥 ----
    stdout.writeln('[4/6] AP 握手（DH + Shannon）+ RequestKey ...');
    final ap = await SpotifyAccessPoint.connect(client: client);
    try {
      final welcome = await ap.authenticate(
        ApCredentials.accessToken(accessToken),
        deviceId: deviceId,
      );
      stdout.writeln('      AP 登录成功 user=${welcome.canonicalUsername} '
          '可复用凭据=${welcome.reusableAuth.length}B');
      final key = await ap.requestAudioKey(file.fileId, id.raw);
      stdout.writeln('      音频密钥 ${key.length}B = ${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');

      // ---- 5) CDN 下载 + AES-128-CTR 解密 ----
      stdout.writeln('[5/6] 下载 + 解密 ...');
      final outDir = Directory(opts['out'] ?? Directory.systemTemp.path);
      await outDir.create(recursive: true);
      final outFile = File('${outDir.path}${Platform.pathSeparator}'
          '${id.toBase62()}.${file.extension}');
      var lastPercent = -1;
      final saved = await _downloadAndDecrypt(
        client: client,
        urls: storage.cdnUrls,
        key: key,
        destination: outFile,
        onProgress: (p) {
          final percent = (p * 100).floor();
          if (percent != lastPercent && percent % 10 == 0) {
            lastPercent = percent;
            stdout.writeln('      $percent%');
          }
        },
      );

      // ---- 6) 校验 ----
      final head = await saved.openRead(0, 4).fold<BytesBuilder>(BytesBuilder(), (b, c) {
        b.add(c);
        return b;
      });
      final headBytes = head.toBytes();
      final magic = String.fromCharCodes(headBytes.map((b) => b >= 0x20 && b < 0x7f ? b : 0x2e));
      stdout.writeln('[6/6] 完成：${saved.path}');
      stdout.writeln('      大小=${await saved.length()} 字节 文件头=$magic (${headBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()})');
      if (file.format == AudioFileFormat.oggVorbis96 ||
          file.format == AudioFileFormat.oggVorbis160 ||
          file.format == AudioFileFormat.oggVorbis320) {
        if (magic == 'OggS') {
          stdout.writeln('      ✅ OggS 校验通过 —— 完整版全曲已落盘');
        } else {
          stderr.writeln('      ❌ 文件头不是 OggS，解密或密钥链路可能有误');
          exit(1);
        }
      } else {
        stdout.writeln('      ✅ 完整版全曲已落盘（${file.format.name}）');
      }
    } finally {
      ap.close();
    }
  } finally {
    client.close();
  }
}

Future<File> _downloadAndDecrypt({
  required http.Client client,
  required List<String> urls,
  required Uint8List key,
  required File destination,
  required void Function(double) onProgress,
}) async {
  Object? lastError;
  for (final url in urls) {
    try {
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        throw StateError('CDN HTTP ${response.statusCode}');
      }
      final total = response.contentLength ?? -1;
      final cipher = AesCtr(key, kAudioAesIv);
      final sink = destination.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        final data = Uint8List.fromList(chunk);
        cipher.process(data);
        sink.add(data);
        received += data.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      if (received == 0) throw StateError('空文件');
      return destination;
    } catch (e) {
      lastError = e;
    }
  }
  throw StateError('所有 CDN 地址下载失败：$lastError');
}

Future<void> _apCheck(String token) async {
  final client = http.Client();
  try {
    stdout.writeln('[ap-check] 解析接入点 ...');
    final endpoint = await SpotifyAccessPoint.resolveAccessPoint(client: client);
    stdout.writeln('[ap-check] 连接 ${endpoint.host}:${endpoint.port} 并握手（ClientHello → APResponse → ClientResponsePlaintext）...');
    final ap = await SpotifyAccessPoint.connect(client: client);
    try {
      stdout.writeln('[ap-check] 握手成功（RSA 签名验证 + Shannon 密钥推导均通过）');
      stdout.writeln('[ap-check] 用 token 登录验证加密通道（预期：服务端回 AuthFailure）...');
      final welcome = await ap.authenticate(
        ApCredentials.accessToken(token),
        deviceId: SpotifyAuthConstants.generateDeviceId(),
      );
      stdout.writeln('[ap-check] ✅ 意料之外的登录成功：user=${welcome.canonicalUsername}');
    } on ApLoginException catch (e) {
      stdout.writeln('[ap-check] ✅ 收到服务端 AuthFailure（$e）');
      stdout.writeln('[ap-check]    说明：发送/接收 Shannon 加密 + MAC 均被服务端接受，握手链路完好');
    } finally {
      ap.close();
    }
  } catch (e, s) {
    stderr.writeln('[ap-check] ❌ 失败：$e');
    stderr.writeln(s);
    exitCode = 1;
  } finally {
    client.close();
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--')) {
      final key = arg.substring(2);
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        out[key] = args[++i];
      } else {
        out[key] = '';
      }
    }
  }
  return out;
}
