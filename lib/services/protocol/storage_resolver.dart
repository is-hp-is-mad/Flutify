import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../auth/proto_codec.dart';
import '../rust_backend_bridge.dart';

/// `storage-resolve` 响应（`spotify.download.proto.StorageResolveResponse`，proto3）。
class StorageResolveResult {
  /// CDN = 0（可直接下载）；STORAGE = 1（旧式分片存储）；RESTRICTED = 3（无权限）。
  final int result;
  final List<String> cdnUrls;
  final Uint8List fileId;

  const StorageResolveResult({required this.result, required this.cdnUrls, required this.fileId});

  bool get isCdn => result == 0;

  factory StorageResolveResult.parse(Uint8List data) {
    var result = 0;
    final cdnUrls = <String>[];
    var fileId = Uint8List(0);
    ProtoReader(data).forEach((f) {
      if (f.number == 1 && f.wireType == 0) result = f.varintValue;
      if (f.number == 2 && f.wireType == 2) cdnUrls.add(f.asString);
      if (f.number == 4 && f.wireType == 2) fileId = f.bytesValue;
    });
    return StorageResolveResult(result: result, cdnUrls: cdnUrls, fileId: fileId);
  }
}

/// 解析音频文件的 CDN 地址（`GET /storage-resolve/files/audio/interactive/{fileIdHex}`）。
///
/// 与 librespot `spclient.rs::get_audio_storage` 一致；若该路径 404，
/// 回退桌面端使用的 `storage-resolve/v2/files/audio/interactive/{fileIdHex}`。
Future<StorageResolveResult> resolveAudioStorage({
  required String fileIdHex,
  required Future<Map<String, String>> Function() headers,
  http.Client? client,
}) async {
  if (client == null && RustCore.ready) {
    final proxy = await RustBackendBridge.proxyForUrl(
      '${SpotifyEndpoints.defaultSpClientBase}/storage-resolve/files/audio/interactive/$fileIdHex',
    );
    if (proxy != null) {
      final dto = await rust.rustResolveAudioStorage(
        spclientBase: SpotifyEndpoints.defaultSpClientBase,
        fileIdHex: fileIdHex,
        proxy: proxy,
      );
      return StorageResolveResult(
        result: dto.result,
        cdnUrls: dto.cdnUrls,
        fileId: Uint8List.fromList(dto.fileId),
      );
    }
  }
  final c = client ?? http.Client();
  try {
    final paths = [
      '/storage-resolve/files/audio/interactive/$fileIdHex',
      '/storage-resolve/v2/files/audio/interactive/$fileIdHex',
    ];
    http.Response? last;
    for (final path in paths) {
      final res = await c.get(
        Uri.parse('https://spclient.wg.spotify.com$path'),
        headers: await headers(),
      );
      if (res.statusCode == 200) {
        final result = StorageResolveResult.parse(res.bodyBytes);
        if (result.cdnUrls.isEmpty) {
          throw StateError('storage-resolve 未返回 CDN 地址（result=${result.result}）');
        }
        return result;
      }
      last = res;
      if (res.statusCode != 404) break;
    }
    throw StateError('storage-resolve 失败：HTTP ${last?.statusCode}');
  } finally {
    if (client == null) c.close();
  }
}
