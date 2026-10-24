import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutify_app/core/file_digest.dart';
import 'package:flutify_app/core/rust_core.dart';
import 'package:flutify_app/services/protocol/ap_codec.dart';
import 'package:flutify_app/services/protocol/ap_crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

/// 经 FFI 调用本地编译的 Rust 核心，核对与纯 Dart 实现逐字节一致（覆盖参数名 / 类型转换等接线）。
///
/// 需要先 `cargo build --release`（rust/flutify_core）；没有动态库时跳过。
void main() {
  final library = File(
    Platform.isWindows
        ? 'rust/flutify_core/target/release/rust_lib_flutify.dll'
        : Platform.isMacOS
        ? 'rust/flutify_core/target/release/librust_lib_flutify.dylib'
        : 'rust/flutify_core/target/release/librust_lib_flutify.so',
  );
  final skip = library.existsSync() ? null : '未编译 Rust 核心（cargo build --release）';

  test('AP 握手、AP 包编解码、文件 SHA-256：Rust 与 Dart 结果一致', () async {
    // 先用纯 Dart 算一遍
    expect(RustCore.ready, isFalse);
    final a = DhLocalKeys.random(Random(42));
    final b = DhLocalKeys.random(Random(7));
    final dartPubA = a.publicKey;
    final dartShared = a.sharedSecret(b.publicKey);
    final packets = Uint8List.fromList(List.generate(300, (i) => (i * 37 + 11) & 0xff));
    final dartKeys = apComputeKeys(dartShared, packets);
    final payload = Uint8List.fromList(List.generate(777, (i) => (i * 5) & 0xff));
    final dartFrame = ApCodec(dartKeys.sendKey, dartKeys.recvKey).encode(0x4a, payload);
    final file = File('${Directory.systemTemp.path}/flutify_rust_parity.bin')
      ..writeAsBytesSync(packets);
    final dartDigest = await sha256OfFile(file);

    await RustCore.initialize(
      exitOnFailure: false,
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
    expect(RustCore.ready, isTrue);

    // 同样的私钥（同一随机种子）经 Rust 计算
    final ra = DhLocalKeys.random(Random(42));
    final rb = DhLocalKeys.random(Random(7));
    expect(ra.publicKey, dartPubA);
    expect(ra.sharedSecret(rb.publicKey), dartShared);
    final rustKeys = apComputeKeys(dartShared, packets);
    expect(rustKeys.challenge, dartKeys.challenge);
    expect(rustKeys.sendKey, dartKeys.sendKey);
    expect(rustKeys.recvKey, dartKeys.recvKey);

    final sender = ApCodec(rustKeys.sendKey, rustKeys.recvKey);
    final frame = sender.encode(0x4a, payload);
    expect(frame, dartFrame);

    // 对端：收发密钥对调，分两段喂入，验证头 / 体解码与 MAC
    final receiver = ApCodec(rustKeys.recvKey, rustKeys.sendKey);
    receiver.addIncoming(Uint8List.sublistView(frame, 0, 2));
    expect(receiver.nextPacket(), isNull);
    receiver.addIncoming(Uint8List.sublistView(frame, 2));
    final packet = receiver.nextPacket()!;
    expect(packet.cmd, 0x4a);
    expect(packet.payload, payload);

    // MAC 被篡改：抛错
    final bad = ApCodec(rustKeys.recvKey, rustKeys.sendKey);
    final tampered = Uint8List.fromList(frame)..[frame.length - 1] ^= 1;
    bad.addIncoming(tampered);
    expect(bad.nextPacket, throwsStateError);

    expect(await sha256OfFile(file), dartDigest);
    file.deleteSync();
  }, skip: skip);
}
