import 'dart:typed_data';

import '../auth/proto_codec.dart';

/// 只读的 protobuf 消息树：一次性拆出所有字段，按字段号取值。
///
/// 服务端驱动的 Watch Feed 组件多、字段会漂移，这里一律宽松处理：
/// 缺失字段返回空值，损坏的字节在出错处截断（已解析的字段保留），绝不抛错。
class ProtoMsg {
  final Map<int, List<ProtoField>> _fields;

  const ProtoMsg._(this._fields);

  /// 空消息：所有取值都返回空。
  static const ProtoMsg empty = ProtoMsg._({});

  factory ProtoMsg.parse(List<int> bytes) {
    if (bytes.isEmpty) return empty;
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final fields = <int, List<ProtoField>>{};
    final reader = ProtoReader(data);
    try {
      ProtoField? field;
      while ((field = reader.next()) != null) {
        (fields[field!.number] ??= []).add(field);
      }
    } catch (_) {
      // 长度越界等损坏：保留已读到的字段。
    }
    return ProtoMsg._(fields);
  }

  bool has(int number) => _fields.containsKey(number);

  ProtoField? _last(int number, int wireType) {
    final list = _fields[number];
    if (list == null) return null;
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].wireType == wireType) return list[i];
    }
    return null;
  }

  Iterable<ProtoField> _all(int number, int wireType) =>
      (_fields[number] ?? const <ProtoField>[]).where(
        (f) => f.wireType == wireType,
      );

  /// 字符串字段；缺失为空串。
  String str(int number) => _last(number, 2)?.asString ?? '';

  /// 重复字符串字段。
  List<String> strs(int number) => [
    for (final f in _all(number, 2)) f.asString,
  ];

  /// varint 字段（int / enum）；缺失为 0。
  int integer(int number) => _last(number, 0)?.varintValue ?? 0;

  /// bool 字段；缺失为 false。
  bool flag(int number) => integer(number) != 0;

  /// 原始字节字段；缺失为 null。
  Uint8List? bytes(int number) => _last(number, 2)?.bytesValue;

  /// 嵌套消息；缺失为 [empty]。
  ProtoMsg msg(int number) {
    final f = _last(number, 2);
    return f == null ? empty : ProtoMsg.parse(f.bytesValue);
  }

  /// 重复嵌套消息。
  List<ProtoMsg> msgs(int number) => [
    for (final f in _all(number, 2)) ProtoMsg.parse(f.bytesValue),
  ];

  /// google.protobuf.Any 字段（type_url = 1，value = 2）；缺失为 null。
  ProtoAny? any(int number) {
    if (!has(number)) return null;
    final any = ProtoAny.fromMsg(msg(number));
    return any.typeUrl.isEmpty ? null : any;
  }

  /// 重复的 Any 字段；没有 type_url 的条目跳过。
  List<ProtoAny> anys(int number) => [
    for (final m in msgs(number))
      if (m.str(1).isNotEmpty) ProtoAny.fromMsg(m),
  ];
}

/// google.protobuf.Any：类型地址 + 内层消息。
class ProtoAny {
  final String typeUrl;
  final ProtoMsg value;

  const ProtoAny(this.typeUrl, this.value);

  factory ProtoAny.fromMsg(ProtoMsg msg) => ProtoAny(msg.str(1), msg.msg(2));

  /// 类型短名，如 `type.googleapis.com/spotify.watchfeed.component.item.v1.Hashtag` → `Hashtag`。
  String get typeName {
    final dot = typeUrl.lastIndexOf('.');
    return dot < 0 ? typeUrl : typeUrl.substring(dot + 1);
  }
}
