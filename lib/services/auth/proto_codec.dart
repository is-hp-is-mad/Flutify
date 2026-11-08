import 'dart:convert';
import 'dart:typed_data';

/// 极简 Protobuf wire-format 编解码器（纯 Dart，无需 protoc / 代码生成）。
///
/// 只覆盖 Spotify 登录鉴权链路用到的类型：varint、length-delimited（string / bytes /
/// 嵌套消息）、以及作为 varint 的 int32 / int64 / enum / bool。
/// proto3 语义：默认值字段不编码；解码时缺省即默认值。
///
/// 参考 wire format：https://protobuf.dev/programming-guides/encoding/

/// wire type 常量
class _WireType {
  static const int varint = 0;
  static const int lengthDelimited = 2;
}

/// Protobuf 写入器：按字段号顺序写入，最后 toBytes()。
class ProtoWriter {
  final BytesBuilder _b = BytesBuilder();

  /// 写入 tag（字段号 << 3 | wireType）。
  void _tag(int field, int wireType) => _varint((field << 3) | wireType);

  /// 无符号 varint。
  void _varint(int value) {
    // Dart 原生 int 为 64 位；负数按补码当作无符号 64 位写出（proto 对 int32 负值即如此）
    var v = value;
    for (var i = 0; i < 10; i++) {
      final byte = v & 0x7f;
      // 逻辑右移 7 位（无符号）
      v = (v >> 7) & ~(-1 << (64 - 7));
      if (v == 0) {
        _b.addByte(byte);
        return;
      }
      _b.addByte(byte | 0x80);
    }
  }

  /// int32 / int64 / enum：非 0 才写。
  void int32(int field, int value) {
    if (value == 0) return;
    _tag(field, _WireType.varint);
    _varint(value);
  }

  /// 无条件写入 varint：proto2 的 required 字段、repeated 枚举等
  /// 即使值为 0 也必须显式出现在报文里（如 PRODUCT_CLIENT = 0）。
  void varintAlways(int field, int value) {
    _tag(field, _WireType.varint);
    _varint(value);
  }

  void int64(int field, int value) => int32(field, value);

  void enumValue(int field, int value) => int32(field, value);

  void boolValue(int field, bool value) {
    if (!value) return;
    _tag(field, _WireType.varint);
    _varint(1);
  }

  /// string：非空才写。
  void string(int field, String value) {
    if (value.isEmpty) return;
    bytes(field, utf8.encode(value));
  }

  /// bytes：非空才写。
  void bytes(int field, List<int> value) {
    if (value.isEmpty) return;
    _tag(field, _WireType.lengthDelimited);
    _varint(value.length);
    _b.add(value);
  }

  /// 嵌套消息 / repeated 元素：即使"空"也写入（由调用方决定是否写）。
  void message(int field, ProtoWriter writer) {
    final data = writer.toBytes();
    _tag(field, _WireType.lengthDelimited);
    _varint(data.length);
    _b.add(data);
  }

  Uint8List toBytes() => _b.toBytes();
}

/// 解码出的单个字段。
class ProtoField {
  final int number;
  final int wireType;

  /// varint 值（wireType == 0 时有效）。
  final int varintValue;

  /// length-delimited 原始字节（wireType == 2 时有效）。
  final Uint8List bytesValue;

  ProtoField(this.number, this.wireType, this.varintValue, this.bytesValue);

  String get asString => utf8.decode(bytesValue, allowMalformed: true);

  /// 把本字段作为嵌套消息解析。
  ProtoReader get asMessage => ProtoReader(bytesValue);
}

/// Protobuf 读取器：遍历字段。未知字段自动跳过。
class ProtoReader {
  final Uint8List _data;
  int _pos = 0;

  ProtoReader(this._data);

  bool get hasMore => _pos < _data.length;

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (_pos < _data.length) {
      final byte = _data[_pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  /// 读取下一个字段；到末尾返回 null。
  ProtoField? next() {
    if (!hasMore) return null;
    final tag = _readVarint();
    final field = tag >> 3;
    final wireType = tag & 0x7;

    switch (wireType) {
      case _WireType.varint:
        return ProtoField(field, wireType, _readVarint(), Uint8List(0));
      case _WireType.lengthDelimited:
        final len = _readVarint();
        final value = Uint8List.sublistView(_data, _pos, _pos + len);
        _pos += len;
        return ProtoField(field, wireType, 0, value);
      case 5: // fixed32：跳过 4 字节
        _pos += 4;
        return ProtoField(field, wireType, 0, Uint8List(0));
      case 1: // fixed64：跳过 8 字节
        _pos += 8;
        return ProtoField(field, wireType, 0, Uint8List(0));
      default:
        // 不支持的 wire type：无法安全跳过，终止
        _pos = _data.length;
        return null;
    }
  }

  /// 遍历所有字段并回调。
  void forEach(void Function(ProtoField field) fn) {
    ProtoField? f;
    while ((f = next()) != null) {
      fn(f!);
    }
  }
}
