import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 本地回环（127.0.0.1）纯 Dart 封面图生成服务器。
///
/// 在 Mock / E2E 模式下替代外网 Spotify 图片 CDN：
/// 按 URL 中的 seed 生成渐变色调与几何唱盘图案的 PNG（128x128 RGBA），
/// 既保证离线 CI 零外网依赖，也能驱动封面主色提取（DynamicAccentSync）
/// 与流光背景（AppleMusicBackground / LiquidArtworkBackground）。
class MockCoverServer {
  HttpServer? _server;
  final Map<String, Uint8List> _cache = {};

  /// 启动本地 HTTP 服务；返回监听端口。
  Future<int> start() async {
    if (_server != null) return _server!.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_serve(server));
    return server.port;
  }

  /// 服务器基地址，例如 `http://127.0.0.1:54321`。
  String get baseUrl {
    final s = _server;
    if (s == null) return 'http://127.0.0.1';
    return 'http://127.0.0.1:${s.port}';
  }

  String imageUrl(String seed) => '$baseUrl/cover/${Uri.encodeComponent(seed)}.png';

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        final path = request.uri.path;
        final seed = path.replaceAll(RegExp(r'^/|(\.png)$'), '');
        final bytes = _cache.putIfAbsent(seed, () => generatePng(seed));
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.headers.set('cache-control', 'max-age=3600');
        request.response.add(bytes);
      } catch (_) {
        request.response.statusCode = HttpStatus.internalServerError;
      } finally {
        await request.response.close();
      }
    }
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    _cache.clear();
    if (s != null) await s.close(force: true);
  }

  /// 按确定性种子生成 128x128 的彩色渐变 PNG 字节。
  static Uint8List generatePng(String seed, {int size = 128}) {
    final h = _fnv1a(seed);
    final palettes = const [
      (0xFF1D4ED8, 0xFF06B6D4, 0xFFFDE047), // Ocean / Cyan
      (0xFF7C3AED, 0xFFEC4899, 0xFFFDBA74), // Violet / Pink
      (0xFF059669, 0xFF34D399, 0xFFA7F3D0), // Emerald
      (0xFFBE123C, 0xFFF97316, 0xFFFEF08A), // Rose / Amber
      (0xFF0F172A, 0xFF3B82F6, 0xFFE879F9), // Midnight Neon
      (0xFF854D0E, 0xFFEAB308, 0xFFFCA5A5), // Gold Sunset
      (0xFF4338CA, 0xFF14B8A6, 0xFFF472B6), // Indigo Teal
    ];
    final p = palettes[h % palettes.length];
    final c1r = (p.$1 >> 16) & 0xFF;
    final c1g = (p.$1 >> 8) & 0xFF;
    final c1b = p.$1 & 0xFF;
    final c2r = (p.$2 >> 16) & 0xFF;
    final c2g = (p.$2 >> 8) & 0xFF;
    final c2b = p.$2 & 0xFF;
    final c3r = (p.$3 >> 16) & 0xFF;
    final c3g = (p.$3 >> 8) & 0xFF;
    final c3b = p.$3 & 0xFF;

    // Raw PNG scanlines: filter byte (0) + width * 4 RGBA bytes per row
    final rowStride = 1 + size * 4;
    final raw = Uint8List(rowStride * size);
    final cx = size * (0.35 + ((h >> 4) % 30) / 100.0);
    final cy = size * (0.35 + ((h >> 9) % 30) / 100.0);
    final radius = size * 0.42;

    for (var y = 0; y < size; y++) {
      final rowOffset = y * rowStride;
      raw[rowOffset] = 0; // filter type None
      final ny = y / (size - 1);
      for (var x = 0; x < size; x++) {
        final nx = x / (size - 1);
        final t = (nx * 0.65 + ny * 0.35).clamp(0.0, 1.0);
        var r = c1r + (c2r - c1r) * t;
        var g = c1g + (c2g - c1g) * t;
        var b = c1b + (c2b - c1b) * t;

        final dx = x - cx;
        final dy = y - cy;
        final dist = sqrt(dx * dx + dy * dy);
        final glow = (1.0 - (dist / radius)).clamp(0.0, 1.0);
        if (glow > 0) {
          final k = glow * glow * 0.72;
          r = r * (1 - k) + c3r * k;
          g = g * (1 - k) + c3g * k;
          b = b * (1 - k) + c3b * k;
        }
        // Subtle vinyl ring highlight
        if ((dist - size * 0.24).abs() < 2.2) {
          r = (r + 36).clamp(0, 255);
          g = (g + 36).clamp(0, 255);
          b = (b + 36).clamp(0, 255);
        }

        final px = rowOffset + 1 + x * 4;
        raw[px] = r.round().clamp(0, 255);
        raw[px + 1] = g.round().clamp(0, 255);
        raw[px + 2] = b.round().clamp(0, 255);
        raw[px + 3] = 255;
      }
    }

    return _encodeRgbaPng(size, size, raw);
  }

  static int _fnv1a(String s) {
    var hash = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  static Uint8List _encodeRgbaPng(int width, int height, Uint8List rawScanlines) {
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8) // bit depth
      ..setUint8(9, 6) // color type RGBA
      ..setUint8(10, 0) // compression
      ..setUint8(11, 0) // filter
      ..setUint8(12, 0); // interlace
    final idat = Uint8List.fromList(zlib.encode(rawScanlines));

    final out = BytesBuilder(copy: false)
      ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    _writeChunk(out, 'IHDR', ihdr.buffer.asUint8List());
    _writeChunk(out, 'IDAT', idat);
    _writeChunk(out, 'IEND', Uint8List(0));
    return out.toBytes();
  }

  static void _writeChunk(BytesBuilder out, String type, Uint8List data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    final typeBytes = type.codeUnits;
    out.add(typeBytes);
    out.add(data);
    final crcInput = BytesBuilder(copy: false)
      ..add(typeBytes)
      ..add(data);
    final crc = _crc32(crcInput.toBytes());
    final crcBytes = ByteData(4)..setUint32(0, crc);
    out.add(crcBytes.buffer.asUint8List());
  }

  static final List<int> _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    return c;
  });

  static int _crc32(Uint8List bytes) {
    var c = 0xffffffff;
    for (final b in bytes) {
      c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
    }
    return c ^ 0xffffffff;
  }
}
