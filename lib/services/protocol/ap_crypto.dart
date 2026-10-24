/// Access Point 握手的密钥学原语（对照 librespot `handshake.rs` / `diffie_hellman.rs`）：
/// - DH（768 位 Oakley Group 1，generator 2）；
/// - 握手密钥推导（HMAC-SHA1 链）；
/// - 服务端 DH 公钥签名验证（RSA PKCS#1 v1.5 + SHA-1）。
///
/// 运行时由 Rust（flutify_core `ap_crypto`）计算——Dart BigInt 的 768 位 modPow 很慢；
/// 下面的纯 Dart 实现只在未加载 Rust 核心的单元测试环境里使用，两者逐字节一致。
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;

/// Spotify 服务端 RSA 公钥模数（256 字节，指数 65537）。
final Uint8List apServerKey = Uint8List.fromList([
  0xac, 0xe0, 0x46, 0x0b, 0xff, 0xc2, 0x30, 0xaf, 0xf4, 0x6b, 0xfe, 0xc3, 0xbf, 0xbf, 0x86, 0x3d,
  0xa1, 0x91, 0xc6, 0xcc, 0x33, 0x6c, 0x93, 0xa1, 0x4f, 0xb3, 0xb0, 0x16, 0x12, 0xac, 0xac, 0x6a,
  0xf1, 0x80, 0xe7, 0xf6, 0x14, 0xd9, 0x42, 0x9d, 0xbe, 0x2e, 0x34, 0x66, 0x43, 0xe3, 0x62, 0xd2,
  0x32, 0x7a, 0x1a, 0x0d, 0x92, 0x3b, 0xae, 0xdd, 0x14, 0x02, 0xb1, 0x81, 0x55, 0x05, 0x61, 0x04,
  0xd5, 0x2c, 0x96, 0xa4, 0x4c, 0x1e, 0xcc, 0x02, 0x4a, 0xd4, 0xb2, 0x0c, 0x00, 0x1f, 0x17, 0xed,
  0xc2, 0x2f, 0xc4, 0x35, 0x21, 0xc8, 0xf0, 0xcb, 0xae, 0xd2, 0xad, 0xd7, 0x2b, 0x0f, 0x9d, 0xb3,
  0xc5, 0x32, 0x1a, 0x2a, 0xfe, 0x59, 0xf3, 0x5a, 0x0d, 0xac, 0x68, 0xf1, 0xfa, 0x62, 0x1e, 0xfb,
  0x2c, 0x8d, 0x0c, 0xb7, 0x39, 0x2d, 0x92, 0x47, 0xe3, 0xd7, 0x35, 0x1a, 0x6d, 0xbd, 0x24, 0xc2,
  0xae, 0x25, 0x5b, 0x88, 0xff, 0xab, 0x73, 0x29, 0x8a, 0x0b, 0xcc, 0xcd, 0x0c, 0x58, 0x67, 0x31,
  0x89, 0xe8, 0xbd, 0x34, 0x80, 0x78, 0x4a, 0x5f, 0xc9, 0x6b, 0x89, 0x9d, 0x95, 0x6b, 0xfc, 0x86,
  0xd7, 0x4f, 0x33, 0xa6, 0x78, 0x17, 0x96, 0xc9, 0xc3, 0x2d, 0x0d, 0x32, 0xa5, 0xab, 0xcd, 0x05,
  0x27, 0xe2, 0xf7, 0x10, 0xa3, 0x96, 0x13, 0xc4, 0x2f, 0x99, 0xc0, 0x27, 0xbf, 0xed, 0x04, 0x9c,
  0x3c, 0x27, 0x58, 0x04, 0xb6, 0xb2, 0x19, 0xf9, 0xc1, 0x2f, 0x02, 0xe9, 0x48, 0x63, 0xec, 0xa1,
  0xb6, 0x42, 0xa0, 0x9d, 0x48, 0x25, 0xf8, 0xb3, 0x9d, 0xd0, 0xe8, 0x6a, 0xf9, 0x48, 0x4d, 0xa1,
  0xc2, 0xba, 0x86, 0x30, 0x42, 0xea, 0x9d, 0xb3, 0x08, 0x6c, 0x19, 0x0e, 0x48, 0xb3, 0x9d, 0x66,
  0xeb, 0x00, 0x06, 0xa2, 0x5a, 0xee, 0xa1, 0x1b, 0x13, 0x87, 0x3c, 0xd7, 0x19, 0xe6, 0x55, 0xbd,
]);

/// DH 质数：RFC 2409 Oakley Group 1（768 位 / 96 字节）。公钥必须按 96 字节大端发送。
final BigInt dhPrime = BigInt.parse(
  'ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74'
  '020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437'
  '4fe1356d6d51c245e485b576625e7ec6f44c42e9a63a3620ffffffffffffffff',
  radix: 16,
);

/// DH 公钥固定长度（字节）。
const int dhKeyLength = 96;

final BigInt _dhGenerator = BigInt.two;

class DhLocalKeys {
  final BigInt _privateKey;

  /// 私钥原始字节（95 字节小端），交给 Rust 计算。
  final Uint8List _privateLe;

  late final Uint8List publicKey = RustCore.ready
      ? rust.apDhPublicKey(privateLe: _privateLe)
      : _toBeBytes(_dhGenerator.modPow(_privateKey, dhPrime), dhKeyLength);

  DhLocalKeys._(this._privateKey, this._privateLe);

  /// 随机私钥（95 字节小端，与 librespot 一致）。
  factory DhLocalKeys.random([Random? random]) {
    final rnd = random ?? Random.secure();
    final bytes = Uint8List(95);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    var value = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }
    return DhLocalKeys._(value, bytes);
  }

  /// 与对端公钥计算共享密钥（最小大端字节，无前导零，与 librespot `to_bytes_be` 一致）。
  Uint8List sharedSecret(Uint8List remoteKey) {
    if (RustCore.ready) {
      return rust.apDhSharedSecret(privateLe: _privateLe, remoteBe: remoteKey);
    }
    final remote = _fromBytes(remoteKey);
    final shared = remote.modPow(_privateKey, dhPrime);
    return _toBeBytes(shared);
  }
}

/// 由握手期双方报文字节（含帧头）推导 challenge / send_key / recv_key。
///
/// ```
/// data[]  = HMAC-SHA1(key=shared, packets || [i])  for i in 1..=5
/// challenge = HMAC-SHA1(key=data[0..20], packets)
/// send_key  = data[20..52]
/// recv_key  = data[52..84]
/// ```
({Uint8List challenge, Uint8List sendKey, Uint8List recvKey}) apComputeKeys(
  Uint8List sharedSecret,
  Uint8List handshakePackets,
) {
  if (RustCore.ready) {
    final keys = rust.apComputeKeys(
      sharedSecret: sharedSecret,
      handshakePackets: handshakePackets,
    );
    return (challenge: keys.challenge, sendKey: keys.sendKey, recvKey: keys.recvKey);
  }
  final mac = Hmac(sha1, sharedSecret);
  final data = BytesBuilder();
  for (var i = 1; i <= 5; i++) {
    data.add(mac.convert([...handshakePackets, i]).bytes);
  }
  final all = data.toBytes();
  final challenge = Hmac(sha1, Uint8List.sublistView(all, 0, 20)).convert(handshakePackets).bytes;
  return (
    challenge: Uint8List.fromList(challenge),
    sendKey: Uint8List.sublistView(all, 20, 52),
    recvKey: Uint8List.sublistView(all, 52, 84),
  );
}

/// RSA PKCS#1 v1.5 + SHA-1 验签：`sig^e mod n` 还原出的应为
/// `00 01 FF..FF 00 || DigestInfo(SHA-1) || H(message)`。
bool rsaVerifyPkcs1Sha1({
  required Uint8List modulus,
  required Uint8List signature,
  required Uint8List message,
}) {
  if (RustCore.ready) {
    return rust.apRsaVerifyPkcs1Sha1(
      modulus: modulus,
      signature: signature,
      message: message,
    );
  }
  final n = _fromBytes(modulus);
  final s = _fromBytes(signature);
  final e = BigInt.from(65537);
  final m = s.modPow(e, n);
  final em = _toBeBytes(m, modulus.length);

  const digestInfoPrefix = [
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
  ];
  final hash = sha1.convert(message).bytes;
  final expectedLen = digestInfoPrefix.length + hash.length;
  if (em.length != modulus.length) return false;

  // 布局：00 01 | FF × k | 00 | DigestInfo | hash，其中 k ≥ 8；sep 为 00 分隔符下标。
  final sep = em.length - expectedLen - 1;
  if (sep < 10) return false;
  if (em[0] != 0x00 || em[1] != 0x01) return false;
  for (var i = 2; i < sep; i++) {
    if (em[i] != 0xff) return false;
  }
  if (em[sep] != 0x00) return false;
  for (var i = 0; i < digestInfoPrefix.length; i++) {
    if (em[sep + 1 + i] != digestInfoPrefix[i]) return false;
  }
  for (var i = 0; i < hash.length; i++) {
    if (em[sep + 1 + digestInfoPrefix.length + i] != hash[i]) return false;
  }
  return true;
}

BigInt _fromBytes(Uint8List bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  return value;
}

Uint8List _toBeBytes(BigInt value, [int? length]) {
  final out = <int>[];
  var v = value;
  while (v > BigInt.zero) {
    out.insert(0, (v & BigInt.from(0xff)).toInt());
    v = v >> 8;
  }
  if (length != null) {
    if (out.length > length) throw StateError('value too large');
    return Uint8List.fromList([...List.filled(length - out.length, 0), ...out]);
  }
  return Uint8List.fromList(out.isEmpty ? [0] : out);
}
