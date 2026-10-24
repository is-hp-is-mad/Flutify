import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;

/// AES 分组密码（纯 Dart，FIPS-197）+ CTR 工作模式。
///
/// 用途：Spotify 音频文件解密 = AES-128-CTR（key = 音频密钥，IV 为协议固定常量，
/// 见 `track_audio_loader.dart`）。同时支持 AES-192/256（备用凭据 blob 解包会用到）。
/// 自带测试向量（FIPS-197 / SP 800-38A）见 `test/protocol/aes_test.dart`。
class AesCipher {
  static const List<int> _sbox = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];

  static const List<int> _rcon = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

  final Uint8List _key;
  final int _rounds;
  final Uint8List _roundKeys; // 16 字节 × (rounds + 1)

  AesCipher._(this._key, this._rounds, this._roundKeys);

  /// [key] 长度必须为 16 / 24 / 32 字节（AES-128/192/256）。
  factory AesCipher(Uint8List key) {
    final nk = key.length ~/ 4;
    if (nk != 4 && nk != 6 && nk != 8) {
      throw ArgumentError('AES key must be 16/24/32 bytes, got ${key.length}');
    }
    final rounds = nk + 6;
    final expanded = Uint8List(16 * (rounds + 1));
    expanded.setRange(0, key.length, key);

    final temp = Uint8List(4);
    for (var i = nk; i < 4 * (rounds + 1); i++) {
      for (var b = 0; b < 4; b++) {
        temp[b] = expanded[4 * (i - 1) + b];
      }
      if (i % nk == 0) {
        final t = temp[0];
        temp[0] = _sbox[temp[1]] ^ _rcon[i ~/ nk - 1];
        temp[1] = _sbox[temp[2]];
        temp[2] = _sbox[temp[3]];
        temp[3] = _sbox[t];
      } else if (nk > 6 && i % nk == 4) {
        for (var b = 0; b < 4; b++) {
          temp[b] = _sbox[temp[b]];
        }
      }
      for (var b = 0; b < 4; b++) {
        expanded[4 * i + b] = expanded[4 * (i - nk) + b] ^ temp[b];
      }
    }
    return AesCipher._(Uint8List.fromList(key), rounds, expanded);
  }

  /// 单块加密（16 字节）。
  Uint8List encryptBlock(Uint8List block) {
    if (RustCore.ready) {
      try {
        return rust.aesEncryptBlock(key: _key, block: block);
      } catch (_) {}
    }
    final s = Uint8List.fromList(block);
    encryptInPlace(s);
    return s;
  }

  /// 原地加密 16 字节状态（不分配内存，CTR 解密整首曲目时逐块调用）。
  void encryptInPlace(Uint8List s) {
    _addRoundKey(s, 0);
    for (var round = 1; round < _rounds; round++) {
      _subBytes(s);
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, round);
    }
    _subBytes(s);
    _shiftRows(s);
    _addRoundKey(s, _rounds);
  }

  void _addRoundKey(Uint8List s, int round) {
    for (var i = 0; i < 16; i++) {
      s[i] ^= _roundKeys[16 * round + i];
    }
  }

  static void _subBytes(Uint8List s) {
    for (var i = 0; i < 16; i++) {
      s[i] = _sbox[s[i]];
    }
  }

  static void _shiftRows(Uint8List s) {
    // 状态按列排布：s[r + 4c]；行 r 循环左移 r 格（展开写，避免每块分配临时列表）
    var t = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t;

    t = s[2];
    s[2] = s[10];
    s[10] = t;
    t = s[6];
    s[6] = s[14];
    s[14] = t;

    t = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t;
  }

  static void _mixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
      s[4 * c] = _mul2(a0) ^ _mul3(a1) ^ a2 ^ a3;
      s[4 * c + 1] = a0 ^ _mul2(a1) ^ _mul3(a2) ^ a3;
      s[4 * c + 2] = a0 ^ a1 ^ _mul2(a2) ^ _mul3(a3);
      s[4 * c + 3] = _mul3(a0) ^ a1 ^ a2 ^ _mul2(a3);
    }
  }

  static int _mul2(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0)) & 0xff;

  static int _mul3(int x) => _mul2(x) ^ x;
}

/// AES-CTR（128 位大端计数器，即 `Ctr128BE`）。
///
/// 用法：按文件字节流顺序反复调用 [process]（原地 XOR），可跨块增量处理，
/// 等价于一次性处理整个文件。
class AesCtr {
  final Uint8List _key;
  final Uint8List _iv;
  final AesCipher _cipher;
  final Uint8List _counter;
  final Uint8List _keystream = Uint8List(16);
  int _keystreamPos = 16;
  int _offset = 0;

  AesCtr(Uint8List key, Uint8List iv)
      : _key = Uint8List.fromList(key),
        _iv = Uint8List.fromList(iv),
        _cipher = AesCipher(key),
        _counter = Uint8List.fromList(iv) {
    if (iv.length != 16) throw ArgumentError('CTR IV must be 16 bytes');
  }

  /// 从第 [offset] 字节开始加/解密（CTR 可随机访问：计数器 = IV + offset ~/ 16）。
  /// 用于断点续传：HTTP Range 从中途开始时，解密状态与从头处理到该位置完全一致。
  factory AesCtr.atOffset(Uint8List key, Uint8List iv, int offset) {
    if (offset < 0) throw ArgumentError('offset must be >= 0');
    final ctr = AesCtr(key, iv);
    ctr._addToCounter(offset ~/ 16);
    final rem = offset % 16;
    if (rem > 0) {
      ctr._nextKeystreamBlock();
      ctr._keystreamPos = rem;
    }
    ctr._offset = offset;
    return ctr;
  }

  /// XOR 加/解密 [data]（原地）。可任意分块调用。
  void process(Uint8List data) {
    if (data.isEmpty) return;
    if (RustCore.ready) {
      try {
        final out = rust.aesCtrProcessAtOffset(
          key: _key,
          iv: _iv,
          offset: _offset,
          data: data,
        );
        data.setAll(0, out);
        _offset += data.length;
        _syncDartState();
        return;
      } catch (_) {}
    }
    final keystream = _keystream;
    var pos = _keystreamPos;
    for (var i = 0; i < data.length; i++) {
      if (pos == 16) {
        _nextKeystreamBlock();
        pos = 0;
      }
      data[i] ^= keystream[pos++];
    }
    _keystreamPos = pos;
    _offset += data.length;
  }

  /// Rust 路径只推进 [_offset]；这里把 Dart 侧计数器 / 密钥流对齐到同一位置，
  /// 之后哪怕某块回退到纯 Dart 实现，解密结果也与从头连续处理一致。
  void _syncDartState() {
    _counter.setAll(0, _iv);
    _addToCounter(_offset ~/ 16);
    final rem = _offset % 16;
    if (rem > 0) {
      _nextKeystreamBlock();
      _keystreamPos = rem;
    } else {
      _keystreamPos = 16;
    }
  }

  /// 已处理的字节数（含 [AesCtr.atOffset] 的起始偏移）。
  int get offset => _offset;

  void _nextKeystreamBlock() {
    _keystream.setAll(0, _counter);
    _cipher.encryptInPlace(_keystream);
    _incrementCounter();
  }

  /// 128 位大端计数器加上 [blocks]。
  void _addToCounter(int blocks) {
    var carry = blocks;
    for (var i = 15; i >= 0 && carry > 0; i--) {
      final sum = _counter[i] + (carry & 0xff);
      _counter[i] = sum & 0xff;
      carry = (carry >> 8) + (sum >> 8);
    }
  }

  void _incrementCounter() {
    for (var i = 15; i >= 0; i--) {
      _counter[i] = (_counter[i] + 1) & 0xff;
      if (_counter[i] != 0) break;
    }
  }
}
