import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../src/rust/api/protocol.dart' as rust;

/// Spotify ID（16 字节 GID）与 base62 / base16 / URI 的互转。
///
/// 与 librespot `spotify_id.rs` 一致：base62 为 22 位定长、大端 u128 语义。
class SpotifyId {
  static const int rawSize = 16;
  static const int base62Size = 22;

  static const String _digits = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

  final Uint8List raw;

  SpotifyId._(this.raw);

  /// 从 22 位 base62 ID 解析（`spotify:track:xxxx` 中的 xxxx）。
  factory SpotifyId.fromBase62(String src) {
    if (src.length != base62Size) {
      throw FormatException('base62 id must be $base62Size chars', src);
    }
    if (RustCore.ready) {
      try {
        return SpotifyId._(rust.spotifyIdFromBase62(src: src));
      } catch (_) {
        throw FormatException('invalid base62 char', src);
      }
    }
    var value = BigInt.zero;
    final sixtyTwo = BigInt.from(62);
    for (final code in src.codeUnits) {
      final p = switch (code) {
        >= 0x30 && <= 0x39 => code - 0x30,
        >= 0x61 && <= 0x7a => code - 0x61 + 10,
        >= 0x41 && <= 0x5a => code - 0x41 + 36,
        _ => throw FormatException('invalid base62 char', src),
      };
      value = value * sixtyTwo + BigInt.from(p);
    }
    return SpotifyId._(_toBeBytes(value, rawSize));
  }

  /// 从 32 位十六进制 GID 解析。
  factory SpotifyId.fromBase16(String src) {
    if (src.length != 32) throw FormatException('base16 id must be 32 chars', src);
    if (RustCore.ready) {
      try {
        return SpotifyId._(rust.spotifyIdFromBase16(src: src));
      } catch (_) {
        throw FormatException('invalid base16 id', src);
      }
    }
    final out = Uint8List(rawSize);
    for (var i = 0; i < rawSize; i++) {
      out[i] = int.parse(src.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return SpotifyId._(out);
  }

  /// 从原始 16 字节解析。
  factory SpotifyId.fromRaw(Uint8List raw) {
    if (raw.length != rawSize) throw FormatException('raw id must be $rawSize bytes');
    return SpotifyId._(Uint8List.fromList(raw));
  }

  /// 从 `spotify:track:xxx` / `track:xxx` / `xxx` 中提取 ID。
  factory SpotifyId.fromUri(String uri) {
    var s = uri.trim();
    final lastColon = s.lastIndexOf(':');
    if (lastColon >= 0) s = s.substring(lastColon + 1);
    return SpotifyId.fromBase62(s);
  }

  /// 22 位 base62。
  String toBase62() {
    if (RustCore.ready) {
      try {
        return rust.spotifyIdToBase62(raw: raw);
      } catch (_) {}
    }
    var value = BigInt.zero;
    for (final b in raw) {
      value = (value << 8) | BigInt.from(b);
    }
    final sixtyTwo = BigInt.from(62);
    final chars = List<String>.filled(base62Size, '0');
    var v = value;
    for (var i = base62Size - 1; i >= 0; i--) {
      chars[i] = _digits[(v % sixtyTwo).toInt()];
      v = v ~/ sixtyTwo;
    }
    return chars.join();
  }

  /// 32 位小写十六进制 GID（metadata 等 REST 路径参数用）。
  String toBase16() {
    if (RustCore.ready) {
      try {
        return rust.spotifyIdToBase16(raw: raw);
      } catch (_) {}
    }
    final sb = StringBuffer();
    for (final b in raw) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List _toBeBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }
}
