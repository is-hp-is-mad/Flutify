import 'dart:io';

import 'package:crypto/crypto.dart';

import '../src/rust/api/protocol.dart' as rust;
import 'rust_core.dart';

/// 文件的 SHA-256（小写十六进制）。
///
/// 运行时由 Rust 在后台线程流式计算（更新包、缓存文件动辄上百 MB，Dart 算得慢）；
/// 未加载 Rust 核心的单元测试环境退回 package:crypto。
Future<String> sha256OfFile(File file) async {
  if (RustCore.ready) return rust.sha256File(path: file.path);
  return (await sha256.bind(file.openRead()).first).toString();
}
