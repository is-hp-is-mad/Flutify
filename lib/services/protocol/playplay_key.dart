import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../auth/proto_codec.dart';

/// playplay 音频密钥（`POST /playplay/v1/key/{fileId}` 响应）。
///
/// 桌面客户端音频链：extended-metadata 取 file_id → playplay 取 (R1, R2) →
/// storage-resolve 取 CDN → 整文件下载 → 白盒解包 + 解密 → Ogg。
/// R1（16B）是包装后的文件密钥，R2（4B）参与下游派生；两者都按文件稳定
/// （同一 file_id 多次请求返回相同值，抓包与实测均确认）。
class PlayplayKey {
  /// 包装后的文件密钥（16 字节）。
  final Uint8List r1;

  /// 密钥派生参数（4 字节）。
  final Uint8List r2;

  const PlayplayKey({required this.r1, required this.r2});

  /// 解析响应体：`0a10 <R1:16B> 1204 <R2:4B>`。
  factory PlayplayKey.parse(Uint8List data) {
    if (RustCore.ready) {
      try {
        final dto = rust.rustParsePlayplayKeyProto(data: data);
        return PlayplayKey(r1: dto.r1, r2: dto.r2);
      } catch (_) {}
    }
    Uint8List? r1;
    Uint8List? r2;
    ProtoReader(data).forEach((f) {
      if (f.number == 1 && f.wireType == 2 && f.bytesValue.length == 16) r1 = f.bytesValue;
      if (f.number == 2 && f.wireType == 2 && f.bytesValue.length == 4) r2 = f.bytesValue;
    });
    if (r1 == null || r2 == null) {
      throw StateError('playplay 响应缺 R1/R2（${data.length}B）');
    }
    return PlayplayKey(r1: r1!, r2: r2!);
  }
}

/// 请求体里的 REQK 常量：桌面端 Spotify.dll 硬编码（file offset `0x1967fe8`），
/// 抓包确认各次请求一致，与账号/曲目无关。
const _reqkHex = '025ee50f4d1489d02401286df83f0332';

/// 取一首音频文件的 playplay 密钥（R1/R2）。
///
/// [fileIdHex] 为 40 位十六进制 file_id；[headers] 复用 loader 的鉴权头
/// （access_token + client-token + 桌面 UA）；失败抛 [StateError]（含 HTTP 码）。
Future<PlayplayKey> fetchPlayplayKey({
  required String fileIdHex,
  required Future<Map<String, String>> Function() headers,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final body = RustCore.ready
        ? rust.rustEncodePlayplayKeyRequest(
            nowSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          )
        : (ProtoWriter()
              ..varintAlways(1, 5)
              ..bytes(
                2,
                Uint8List.fromList([
                  for (var i = 0; i < _reqkHex.length; i += 2)
                    int.parse(_reqkHex.substring(i, i + 2), radix: 16),
                ]),
              )
              ..varintAlways(4, 1)
              ..varintAlways(5, 1)
              ..int64(6, DateTime.now().millisecondsSinceEpoch ~/ 1000))
            .toBytes();
    final res = await c.post(
      Uri.parse('https://gae2-spclient.spotify.com/playplay/v1/key/$fileIdHex'),
      headers: {...await headers(), 'Content-Type': 'application/x-protobuf'},
      body: body,
    );
    if (res.statusCode != 200) {
      throw StateError('playplay 取密钥失败：HTTP ${res.statusCode}');
    }
    return PlayplayKey.parse(res.bodyBytes);
  } finally {
    if (client == null) c.close();
  }
}
