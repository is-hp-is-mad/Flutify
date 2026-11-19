import 'dart:async';
import 'dart:io';

import 'package:flutify_app/core/rust_core.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

/// 全部测试在加载了 Rust 核心（与生产一致）的环境下运行。
///
/// 需要先 `cargo build --release --manifest-path rust/flutify_core/Cargo.toml`。
/// CI（环境变量 `CI` 非空）找不到动态库时直接失败，避免悄悄退回纯 Dart 实现、测了不是生产在跑的代码。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final library = File(
    Platform.isWindows
        ? 'rust/flutify_core/target/release/rust_lib_flutify.dll'
        : Platform.isMacOS
        ? 'rust/flutify_core/target/release/librust_lib_flutify.dylib'
        : 'rust/flutify_core/target/release/librust_lib_flutify.so',
  );
  if (library.existsSync()) {
    await RustCore.initialize(
      exitOnFailure: false,
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
  }
  if (!RustCore.ready) {
    final message =
        'Rust 核心未加载（${library.path}），请先 cargo build --release';
    if ((Platform.environment['CI'] ?? '').isNotEmpty) {
      throw StateError(message);
    }
    stderr.writeln('警告：$message；本次测试使用纯 Dart 实现');
  }
  await testMain();
}
