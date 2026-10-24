import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../src/rust/frb_generated.dart';

/// Rust 核心（flutify_core）的加载状态。
///
/// 应用启动时若 Rust 核心加载失败则直接退出进程；
/// 纯 Dart 单元测试环境（未调用 [initialize]）保持 [ready] 为 false。
class RustCore {
  RustCore._();

  static bool _ready = false;
  static bool get ready => _ready;

  /// [externalLibrary]：测试里加载本地编译的动态库（rust/flutify_core/target/release），
  /// 用来核对 Rust 与纯 Dart 实现逐字节一致。
  static Future<void> initialize({
    bool exitOnFailure = true,
    ExternalLibrary? externalLibrary,
  }) async {
    if (_ready) return;
    try {
      await RustLib.init(externalLibrary: externalLibrary ?? _bundledLibrary());
      _ready = true;
    } catch (e, st) {
      debugPrint('Rust 核心加载失败：$e\n$st');
      if (exitOnFailure) {
        exit(1);
      }
    }
  }

  /// 发布版只加载随应用打包的 Rust 库。
  ///
  /// flutter_rust_bridge 的默认加载器在桌面端会先找「当前工作目录 / rust/flutify_core/target/release/」，
  /// 还认环境变量 FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR——开发时方便，发布版里等于允许
  /// 从启动目录加载任意同名 DLL。这里跳过这两步，其余与默认加载顺序一致；调试 / 测试保持默认。
  static ExternalLibrary? _bundledLibrary() {
    if (!kReleaseMode) return null;
    const stem = 'rust_lib_flutify';
    if (Platform.isWindows) {
      final dir = File(Platform.resolvedExecutable).parent.path;
      return ExternalLibrary.open('$dir${Platform.pathSeparator}$stem.dll');
    }
    if (Platform.isLinux) {
      // 由动态链接器按可执行文件的 RPATH（$ORIGIN/lib）查找
      return ExternalLibrary.open('lib$stem.so');
    }
    if (Platform.isMacOS) {
      // .app/Contents/Frameworks 里的 framework（按 @rpath 查找）
      try {
        return ExternalLibrary.open('rust_builder.framework/rust_builder');
      } catch (_) {
        return ExternalLibrary.open('$stem.framework/$stem');
      }
    }
    return null; // Android：默认加载器本来就只认 APK 里的 lib$stem.so
  }
}
