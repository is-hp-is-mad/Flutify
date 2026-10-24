import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;

/// Spotify 登录用的 Hashcash 工作量证明求解器。
///
/// 算法（与 librespot `util::solve_hash_cash` 一致）：
/// 1. `target = int64_be(SHA1(ctx)[12..20])`；
/// 2. 从 counter=0 起循环，`suffix = be8(target+counter) ++ be8(counter)`（共 16 字节）；
/// 3. 若 `int64_be(SHA1(prefix ++ suffix)[12..20])` 的末尾 0 比特数 >= length，则 suffix 即解。
///
/// ctx：login5 用 login_context 字节；client-token 用空字节。
class Hashcash {
  Hashcash._();

  /// 在后台 Isolate 中求解，避免最长 5 秒的 SHA1 循环阻塞 UI 线程。
  /// Rust 求解同样是同步 FFI 调用，必须放在后台 Isolate 里跑；
  /// 后台 Isolate 自行加载 Rust 核心，加载失败时回退纯 Dart 实现。
  static Future<Uint8List> solveAsync(List<int> ctx, List<int> prefix, int length) {
    final ctxCopy = List<int>.of(ctx);
    final prefixCopy = List<int>.of(prefix);
    final useRust = RustCore.ready;
    return Isolate.run(() async {
      if (useRust) await RustCore.initialize(exitOnFailure: false);
      return solve(ctxCopy, prefixCopy, length);
    });
  }

  /// 求解并返回 16 字节 suffix；[timeout] 内无解则抛异常（与官方 5 秒上限一致）。
  static Uint8List solve(
    List<int> ctx,
    List<int> prefix,
    int length, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (RustCore.ready) {
      try {
        return rust.solveHashcash(
          ctx: ctx,
          prefix: prefix,
          length: length,
          timeoutMs: timeout.inMilliseconds,
        );
      } catch (e) {
        throw StateError('Hashcash 求解超时（$length 位难度）：$e');
      }
    }
    final deadline = DateTime.now().add(timeout);

    final md = sha1.convert(ctx).bytes;
    final target = _int64BE(md, 12);

    var counter = 0;
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Hashcash 求解超时（$length 位难度）');
      }

      final suffix = Uint8List(16);
      _writeInt64BE(suffix, 0, target + counter);
      _writeInt64BE(suffix, 8, counter);

      // 单次 SHA1(prefix ++ suffix)
      final sum = sha1.convert([...prefix, ...suffix]).bytes;

      if (_trailingZeros(_int64BE(sum, 12)) >= length) {
        return suffix;
      }
      counter++;
    }
  }

  /// 从 [bytes] 的 [offset] 处读 8 字节，按大端解析为有符号 64 位整数。
  static int _int64BE(List<int> bytes, int offset) {
    final bd = ByteData(8);
    for (var i = 0; i < 8; i++) {
      bd.setUint8(i, bytes[offset + i]);
    }
    return bd.getInt64(0, Endian.big);
  }

  /// 把有符号 64 位整数按大端写入 [bytes] 的 [offset] 处（溢出按补码回绕）。
  static void _writeInt64BE(Uint8List bytes, int offset, int value) {
    final bd = ByteData(8);
    bd.setInt64(0, value, Endian.big);
    for (var i = 0; i < 8; i++) {
      bytes[offset + i] = bd.getUint8(i);
    }
  }

  /// 64 位整数末尾连续 0 比特的个数；0 视为 64。
  static int _trailingZeros(int value) {
    if (value == 0) return 64;
    var count = 0;
    var v = value;
    while ((v & 1) == 0) {
      count++;
      v >>= 1;
    }
    return count;
  }
}
