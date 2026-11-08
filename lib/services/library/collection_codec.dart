import 'dart:typed_data';

import '../auth/proto_codec.dart';

/// `collection/v2/paging` 与 `collection/v2/write` 的 protobuf 编解码（无代码生成）。
///
/// 桌面端媒体库「收藏」集合的底层协议（字段号对照桌面端 xpui 的 protobufjs 定义）：
/// ```
/// PageRequest  { 1 username; 2 set; 3 pagination_token; 4 limit }
/// PageResponse { 1 items(repeated CollectionItem); 2 next_page_token; 3 sync_token }
/// WriteRequest { 1 username; 2 set; 3 items(repeated CollectionItem); 4 client_update_id }
/// CollectionItem { 1 identifier(URI); 2 added_at(秒); 3 is_removed }
/// ```
/// `set` 取值：`collection`（曲目 + 专辑）、`artist`（关注的艺人）。
/// 所有解析宽松：字段缺失 / 未知字段都不会抛错。
class CollectionCodec {
  CollectionCodec._();

  /// 曲目 + 专辑所在的集合名。
  static const String setCollection = 'collection';

  /// 关注艺人所在的集合名。
  static const String setArtist = 'artist';

  /// 请求 / 响应的 MIME 类型。
  static const String contentType = 'application/vnd.collection-v2.spotify.proto';

  /// 构造分页请求。[token] 为空表示第一页。
  static Uint8List encodePageRequest({
    required String username,
    required String set,
    String token = '',
    int limit = 300,
  }) {
    return (ProtoWriter()
          ..string(1, username)
          ..string(2, set)
          ..string(3, token)
          ..int32(4, limit))
        .toBytes();
  }

  /// 构造写请求：[added] 为 true 表示加入集合，false 表示移除（is_removed）。
  static Uint8List encodeWriteRequest({
    required String username,
    required String set,
    required String uri,
    required bool added,
    required DateTime now,
    required String clientUpdateId,
  }) {
    final item = ProtoWriter()
      ..string(1, uri)
      ..int32(2, now.millisecondsSinceEpoch ~/ 1000)
      ..boolValue(3, !added);
    return (ProtoWriter()
          ..string(1, username)
          ..string(2, set)
          ..message(3, item)
          ..string(4, clientUpdateId))
        .toBytes();
  }

  /// 解析分页响应。
  static CollectionPage decodePage(Uint8List data) {
    final items = <CollectionEntry>[];
    var next = '';
    try {
      ProtoReader(data).forEach((f) {
        if (f.number == 1 && f.wireType == 2) {
          final entry = _decodeItem(f.bytesValue);
          if (entry != null) items.add(entry);
        }
        if (f.number == 2 && f.wireType == 2) next = f.asString;
      });
    } catch (_) {
      // 响应被截断：保留已解析的条目
    }
    return CollectionPage(items: items, nextToken: next);
  }

  static CollectionEntry? _decodeItem(Uint8List bytes) {
    var uri = '';
    var addedAt = 0;
    var removed = false;
    try {
      ProtoReader(bytes).forEach((f) {
        if (f.number == 1 && f.wireType == 2) uri = f.asString;
        if (f.number == 2 && f.wireType == 0) addedAt = f.varintValue;
        if (f.number == 3 && f.wireType == 0) removed = f.varintValue != 0;
      });
    } catch (_) {}
    if (uri.isEmpty || removed) return null;
    return CollectionEntry(uri: uri, addedAt: addedAt);
  }
}

/// 集合中的一个条目（已过滤掉 is_removed）。
class CollectionEntry {
  /// 实体 URI，如 `spotify:track:xxx`（缺前缀时按原值保留）。
  final String uri;

  /// 加入时间（epoch 秒；缺失为 0）。
  final int addedAt;

  const CollectionEntry({required this.uri, required this.addedAt});

  /// URI 的实体类型：`track` / `album` / `artist` …；无法识别返回空串。
  String get kind {
    final parts = uri.split(':');
    return parts.length >= 3 && parts.first == 'spotify' ? parts[1] : '';
  }

  /// URI 的最后一段（base62 id）。
  String get id => uri.substring(uri.lastIndexOf(':') + 1);
}

/// 一页集合条目。
class CollectionPage {
  final List<CollectionEntry> items;

  /// 下一页游标；空串表示已到最后一页。
  final String nextToken;

  const CollectionPage({required this.items, required this.nextToken});
}
