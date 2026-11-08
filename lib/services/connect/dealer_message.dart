import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// dealer 推送的一条消息（`{"type":"message","uri":…,"headers":{…},"payloads":[…]}`）。
///
/// [payloads] 已按内容解码：
/// - JSON 对象 / 数组：原样；
/// - base64 字符串：解出字节（`Transfer-Encoding: gzip` 或带 gzip 魔数 `1f 8b` 时先解压），
///   能按 UTF-8 + JSON 解析为 Map / List 则给出解析结果，否则保留为 [Uint8List]；
/// - base64 解码失败保留原字符串；gzip 解不开保留未解压的字节。调用方忽略这类 payload 即可。
class DealerMessage {
  final String type;
  final String uri;
  final Map<String, String> headers;
  final List<Object?> payloads;

  const DealerMessage({this.type = 'message', this.uri = '', this.headers = const {}, this.payloads = const []});

  /// 按名字取头，忽略大小写（服务端同时出现过 `Spotify-Connection-Id` 与 `content-type` 这类写法）。
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  factory DealerMessage.fromJson(Map<String, dynamic> json) {
    final headers = <String, String>{
      for (final entry in ((json['headers'] as Map?) ?? const {}).entries) '${entry.key}': '${entry.value}',
    };
    final isGzip = headers.entries.any((e) => e.key.toLowerCase() == 'transfer-encoding' && e.value == 'gzip');
    final rawPayloads = json['payloads'];
    return DealerMessage(
      type: json['type'] as String? ?? '',
      uri: json['uri'] as String? ?? '',
      headers: headers,
      payloads: [
        if (rawPayloads is List)
          for (final p in rawPayloads) decodePayload(p, gzipped: isGzip),
      ],
    );
  }

  /// 解码单个 payload，规则见类文档。
  static Object? decodePayload(Object? raw, {bool gzipped = false}) {
    if (raw is! String) return raw;
    Uint8List bytes;
    try {
      bytes = base64.decode(raw);
    } on FormatException {
      return raw;
    }
    if (gzipped || (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)) {
      try {
        bytes = Uint8List.fromList(gzip.decode(bytes));
      } catch (_) {
        // 声明了 gzip 但解不开：保留原始字节
        return bytes;
      }
    }
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is Map || json is List) return json;
    } catch (_) {}
    return bytes;
  }
}
