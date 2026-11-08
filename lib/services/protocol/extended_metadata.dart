import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth/proto_codec.dart';

/// extended-metadata 扩展类型（`extension_kind.proto` 中本 App 用到的部分）。
class ExtensionKind {
  /// 音频文件列表（`AudioFilesExtensionResponse`）。
  static const int audioFiles = 5;

  /// 完整曲目元数据（`spotify.metadata.Track`，含 file / alternative 字段）。
  static const int trackV4 = 10;
}

/// extended-metadata 批量接口（`POST spclient /extended-metadata/v0/extended-metadata`）。
///
/// 现网的 `metadata/4/track` 对新版客户端会省略 `file`（音频文件）字段，官方客户端改为
/// 通过 extended-metadata 取 `TRACK_V4` 扩展，其载荷就是完整的 `spotify.metadata.Track`。
///
/// 请求（`BatchedEntityRequest`）：
/// ```
/// 1 header { 1 country = "from_token" }
/// 2 entity_request (repeated) { 1 entity_uri; 2 query (repeated) { 1 extension_kind } }
/// ```
/// 响应（`BatchedExtensionResponse`）：
/// ```
/// 2 extended_metadata (repeated) {
///   2 extension_kind
///   3 extension_data (repeated) { 1 header { 1 status_code } 2 entity_uri 3 Any { 1 type_url 2 value } }
/// }
/// ```
class ExtendedMetadataClient {
  static const String _endpoint = 'https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata';

  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;

  ExtendedMetadataClient(this._client, {required this._headers});

  /// 取单个实体的某个扩展载荷（Any.value 原始字节）；实体不存在或无该扩展时返回 null。
  ///
  /// HTTP 非 200 抛 [ExtendedMetadataHttpException]，由调用方区分 401 / 其他。
  Future<Uint8List?> fetch(String entityUri, int kind) async {
    final res = await _client.post(
      Uri.parse(_endpoint),
      headers: {
        ...await _headers(),
        'Accept': 'application/protobuf',
        'Content-Type': 'application/protobuf',
      },
      body: buildRequest([entityUri], kind),
    );
    if (res.statusCode != 200) throw ExtendedMetadataHttpException(res.statusCode);
    return parseResponse(res.bodyBytes, kind)[entityUri];
  }

  /// 构造 `BatchedEntityRequest`。
  static Uint8List buildRequest(List<String> entityUris, int kind) {
    final writer = ProtoWriter()..message(1, ProtoWriter()..string(1, 'from_token'));
    for (final uri in entityUris) {
      writer.message(
        2,
        ProtoWriter()
          ..string(1, uri)
          ..message(2, ProtoWriter()..varintAlways(1, kind)),
      );
    }
    return writer.toBytes();
  }

  /// 解析 `BatchedExtensionResponse`：返回 entity_uri → Any.value（仅 status 200 且类型匹配的条目）。
  static Map<String, Uint8List> parseResponse(Uint8List data, int kind) {
    final out = <String, Uint8List>{};
    ProtoReader(data).forEach((array) {
      if (array.number != 2 || array.wireType != 2) return;
      var arrayKind = -1;
      final entries = <ProtoField>[];
      array.asMessage.forEach((f) {
        if (f.number == 2 && f.wireType == 0) arrayKind = f.varintValue;
        if (f.number == 3 && f.wireType == 2) entries.add(f);
      });
      if (arrayKind != kind) return;
      for (final entry in entries) {
        var status = 200;
        var uri = '';
        Uint8List? value;
        entry.asMessage.forEach((f) {
          if (f.number == 1 && f.wireType == 2) {
            f.asMessage.forEach((h) {
              if (h.number == 1 && h.wireType == 0) status = h.varintValue;
            });
          }
          if (f.number == 2 && f.wireType == 2) uri = f.asString;
          if (f.number == 3 && f.wireType == 2) {
            f.asMessage.forEach((any) {
              if (any.number == 2 && any.wireType == 2) value = any.bytesValue;
            });
          }
        });
        if (status == 200 && uri.isNotEmpty && value != null) out[uri] = value!;
      }
    });
    return out;
  }
}

/// extended-metadata 返回非 200。
class ExtendedMetadataHttpException implements Exception {
  final int statusCode;
  const ExtendedMetadataHttpException(this.statusCode);

  @override
  String toString() => 'extended-metadata HTTP $statusCode';
}
