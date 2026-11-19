import 'dart:io';
import 'dart:typed_data';

import 'package:flutify_app/core/file_digest.dart';
import 'package:flutify_app/core/rust_core.dart';
import 'package:flutify_app/src/rust/api/protocol.dart' as rust;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

/// 经 FFI 调用本地编译的 Rust 核心，核对 AP 协议接线（参数名 / 类型转换）与对照向量逐字节一致。
///
/// 纯 Dart 的 AP 实现（Shannon / ApCodec / DH）已删除，对照向量与 Rust 单元测试共用
/// `rust/flutify_core/tests/fixtures/ap_vectors.txt`。需要先 `cargo build --release`；没有动态库时跳过。
void main() {
  final library = File(
    Platform.isWindows
        ? 'rust/flutify_core/target/release/rust_lib_flutify.dll'
        : Platform.isMacOS
        ? 'rust/flutify_core/target/release/librust_lib_flutify.dylib'
        : 'rust/flutify_core/target/release/librust_lib_flutify.so',
  );
  final skip = library.existsSync() ? null : '未编译 Rust 核心（cargo build --release）';

  Map<String, String> vectors() => {
    for (final line in File(
      'rust/flutify_core/tests/fixtures/ap_vectors.txt',
    ).readAsLinesSync())
      if (line.contains('='))
        line.substring(0, line.indexOf('=')).trim(): line
            .substring(line.indexOf('=') + 1)
            .trim(),
  };

  Uint8List hex(String s) => Uint8List.fromList([
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);

  String hexOf(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  test('AP 握手、AP 包编解码、文件 SHA-256：Rust FFI 与对照向量一致', () async {
    final v = vectors();
    final file = File('${Directory.systemTemp.path}/flutify_rust_parity.bin')
      ..writeAsBytesSync(hex(v['packets']!));
    // 未加载 Rust 时 sha256OfFile 走 package:crypto
    expect(RustCore.ready, isFalse);
    final dartDigest = await sha256OfFile(file);

    await RustCore.initialize(
      exitOnFailure: false,
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
    expect(RustCore.ready, isTrue);

    expect(hexOf(rust.apDhPublicKey(privateLe: hex(v['privA']!))), v['pubA']);
    final shared = rust.apDhSharedSecret(
      privateLe: hex(v['privA']!),
      remoteBe: hex(v['pubB']!),
    );
    expect(hexOf(shared), v['shared']);
    final keys = rust.apComputeKeys(
      sharedSecret: shared,
      handshakePackets: hex(v['packets']!),
    );
    expect(hexOf(keys.challenge), v['challenge']);
    expect(hexOf(keys.sendKey), v['sendKey']);
    expect(hexOf(keys.recvKey), v['recvKey']);

    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
    final frame = rust.shannonEncodePacket(
      key: keys.sendKey,
      nonce: 1,
      cmd: 0x41,
      payload: payload,
    );
    expect(hexOf(frame), v['frame1']);
    final header = rust.shannonDecryptHeader(
      key: keys.sendKey,
      nonce: 1,
      header: frame.sublist(0, 3),
    );
    expect(header[0], 0x41);
    expect(
      rust.shannonDecodePacket(
        key: keys.sendKey,
        nonce: 1,
        header: frame.sublist(0, 3),
        body: frame.sublist(3, 8),
        mac: frame.sublist(8),
      ),
      payload,
    );
    final tampered = Uint8List.fromList(frame)..[frame.length - 1] ^= 1;
    expect(
      () => rust.shannonDecodePacket(
        key: keys.sendKey,
        nonce: 1,
        header: tampered.sublist(0, 3),
        body: tampered.sublist(3, 8),
        mac: tampered.sublist(8),
      ),
      throwsA(anything),
    );

    expect(await sha256OfFile(file), dartDigest);
    file.deleteSync();
  }, skip: skip);
}
