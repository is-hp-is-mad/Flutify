import 'dart:io';
import 'dart:typed_data';

import 'package:flutify_app/core/file_digest.dart';
import 'package:flutify_app/core/rust_core.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

/// 经 FFI 调用本地编译的 Rust 核心，核对文件 SHA-256 与纯 Dart（package:crypto）结果一致。
///
/// AP 协议（DH / Shannon / 密钥推导）已只在 Rust 内使用，对照向量由 Rust 单元测试覆盖
/// （`rust/flutify_core/tests/fixtures/ap_vectors.txt`）。需要先 `cargo build --release`；没有动态库时跳过。
void main() {
  final library = File(
    Platform.isWindows
        ? 'rust/flutify_core/target/release/rust_lib_flutify.dll'
        : Platform.isMacOS
        ? 'rust/flutify_core/target/release/librust_lib_flutify.dylib'
        : 'rust/flutify_core/target/release/librust_lib_flutify.so',
  );
  final skip = library.existsSync() ? null : '未编译 Rust 核心（cargo build --release）';

  test('文件 SHA-256：Rust FFI 与 package:crypto 一致', () async {
    final file = File('${Directory.systemTemp.path}/flutify_rust_parity.bin')
      ..writeAsBytesSync(
        Uint8List.fromList(List.generate(300, (i) => (i * 37 + 11) & 0xff)),
      );
    // 未加载 Rust 时 sha256OfFile 走 package:crypto
    expect(RustCore.ready, isFalse);
    final dartDigest = await sha256OfFile(file);

    await RustCore.initialize(
      exitOnFailure: false,
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
    expect(RustCore.ready, isTrue);
    expect(await sha256OfFile(file), dartDigest);
    file.deleteSync();
  }, skip: skip);
}
