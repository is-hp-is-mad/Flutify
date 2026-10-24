import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;
import 'shannon.dart';

/// AP 加密通道的一个数据包。
class ApPacket {
  final int cmd;
  final Uint8List payload;

  const ApPacket(this.cmd, this.payload);
}

/// Access Point 加密通道的包编解码（对照 librespot `connection/codec.rs`）。
///
/// 包格式：`cmd(1) + len(2 BE) + payload + mac(4)`；cmd+len+payload 整体过 Shannon，
/// mac 由 finish() 产出。收发各持独立 Shannon 与 nonce（每包以 4 字节大端 nonce 播种，
/// 自 0 递增）。纯字节逻辑，便于脱离 socket 单测。
///
/// 加解密与 MAC 运行时由 Rust（flutify_core `shannon`）完成，这里只负责收包缓冲与 nonce；
/// 纯 Dart 的 [Shannon] 只在未加载 Rust 核心的单元测试环境里使用。
class ApCodec {
  final Uint8List _sendKey;
  final Uint8List _recvKey;
  late final Shannon _encodeCipher = Shannon(_sendKey);
  late final Shannon _decodeCipher = Shannon(_recvKey);

  int _encodeNonce = 0;
  int _decodeNonce = 0;

  final BytesBuilder _incoming = BytesBuilder();
  Uint8List? _pendingHeader; // 已解密的 [cmd, lenH, lenL]
  Uint8List? _pendingHeaderRaw; // 头的密文（Rust 解包体时需要从头重放）
  int? _pendingSize;
  int _pendingNonce = 0;

  ApCodec(Uint8List sendKey, Uint8List recvKey)
      : _sendKey = Uint8List.fromList(sendKey),
        _recvKey = Uint8List.fromList(recvKey);

  /// 编码一个待发送包（含 4 字节 MAC）。
  Uint8List encode(int cmd, Uint8List payload) {
    if (payload.length > 0xffff) throw ArgumentError('payload too large');
    final body = Uint8List(3 + payload.length);
    body[0] = cmd;
    body[1] = (payload.length >> 8) & 0xff;
    body[2] = payload.length & 0xff;
    body.setRange(3, body.length, payload);

    if (RustCore.ready) {
      return rust.shannonEncodePacket(
        key: _sendKey,
        nonce: _encodeNonce++,
        cmd: cmd,
        payload: payload,
      );
    }
    _encodeCipher.nonceU32(_encodeNonce++);
    _encodeCipher.encrypt(body);
    final mac = _encodeCipher.finish(4);

    return Uint8List.fromList([...body, ...mac]);
  }

  /// 喂入收到的原始字节。
  void addIncoming(Uint8List bytes) => _incoming.add(bytes);

  /// 取出下一个完整包；数据不足返回 null。MAC 校验失败抛 [StateError]。
  ApPacket? nextPacket() {
    final buf = _incoming.toBytes();

    if (_pendingHeader == null) {
      if (buf.length < 3) {
        _replace(buf);
        return null;
      }
      final raw = Uint8List.fromList(buf.sublist(0, 3));
      final Uint8List header;
      _pendingNonce = _decodeNonce++;
      if (RustCore.ready) {
        header = rust.shannonDecryptHeader(key: _recvKey, nonce: _pendingNonce, header: raw);
      } else {
        header = Uint8List.fromList(raw);
        _decodeCipher.nonceU32(_pendingNonce);
        _decodeCipher.decrypt(header);
      }
      _pendingHeaderRaw = raw;
      _pendingHeader = header;
      _pendingSize = (header[1] << 8) | header[2];
      _replace(Uint8List.sublistView(buf, 3).isEmpty
          ? Uint8List(0)
          : Uint8List.fromList(buf.sublist(3)));
    }

    final size = _pendingSize!;
    if (_incoming.length < size + 4) {
      return null;
    }

    final rest = _incoming.toBytes();
    final payloadEnc = Uint8List.fromList(rest.sublist(0, size));
    final mac = Uint8List.fromList(rest.sublist(size, size + 4));
    _replace(rest.length > size + 4 ? Uint8List.fromList(rest.sublist(size + 4)) : Uint8List(0));

    final Uint8List payload;
    if (RustCore.ready) {
      try {
        payload = rust.shannonDecodePacket(
          key: _recvKey,
          nonce: _pendingNonce,
          header: _pendingHeaderRaw!,
          body: payloadEnc,
          mac: mac,
        );
      } catch (e) {
        throw StateError('AP packet MAC mismatch');
      }
    } else {
      _decodeCipher.decrypt(payloadEnc);
      final computed = _decodeCipher.finish(4);
      for (var i = 0; i < 4; i++) {
        if (computed[i] != mac[i]) {
          throw StateError('AP packet MAC mismatch');
        }
      }
      payload = payloadEnc;
    }

    final packet = ApPacket(_pendingHeader![0], payload);
    _pendingHeader = null;
    _pendingHeaderRaw = null;
    _pendingSize = null;
    return packet;
  }

  void _replace(Uint8List remaining) {
    _incoming.clear();
    if (remaining.isNotEmpty) _incoming.add(remaining);
  }
}
