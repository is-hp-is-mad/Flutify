import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_color_utilities/quantize/quantizer_celebi.dart';
import 'package:material_color_utilities/score/score.dart';

/// 从专辑封面提取氛围色（Spotify 全屏播放器 / 迷你播放器的动态背景）。
///
/// 取色在 112px 缩略图上进行，结果按 URL 缓存；同一 URL 的并发请求会合并。
class ArtworkPalette {
  ArtworkPalette._();

  /// Widget 测试中图片永远不会加载，而 fromImageProvider 内部有 5 秒超时计时器，
  /// 会被判定为 pending timer，因此测试里需关闭取色。
  static bool enabled = true;

  static final Map<String, Color> _cache = {};
  static final Map<String, Future<Color?>> _pending = {};
  static final Map<String, Color> _dominantCache = {};
  static final Map<String, Future<Color?>> _dominantPending = {};
  static final Map<String, Color> _artistCache = {};
  static final Map<String, Future<Color?>> _artistPending = {};

  /// 测试注入专辑页主色。[resolveDominant] 优先读这里，不受 [enabled] 影响。
  static final Map<String, Color> debugDominantOverrides = {};

  /// 测试注入艺人页头图原色。[resolveArtistColor] 优先读这里，不受 [enabled] 影响。
  static final Map<String, Color> debugArtistOverrides = {};

  static int _generation = 0;
  static void clear() {
    _generation++;
    _cache.clear();
    _pending.clear();
    _dominantCache.clear();
    _dominantPending.clear();
    _artistCache.clear();
    _artistPending.clear();
    debugDominantOverrides.clear();
    debugArtistOverrides.clear();
  }

  static Color? cached(String url) => _cache[url];

  static Future<Color?> resolve(String url) {
    if (!enabled || url.isEmpty) return Future.value(null);
    final hit = _cache[url];
    if (hit != null) return Future.value(hit);

    // 回调必须是块体，否则会返回被移除的 Future 自身，导致 whenComplete 自我等待
    final generation = _generation;
    return _pending[url] ??= _extract(url, generation).whenComplete(() {
      if (generation == _generation) _pending.remove(url);
    });
  }

  static Future<Color?> _extract(String url, int generation) async {
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: ResizeImage(
          CachedNetworkImageProvider(url),
          width: 112,
          height: 112,
        ),
        brightness: Brightness.dark,
      );
      final color = scheme.primaryContainer;
      if (generation == _generation) _cache[url] = color;
      return color;
    } catch (_) {
      return null;
    }
  }

  /// 封面本身的主色，给专辑页 OKLCH 调整用。
  ///
  /// Apple Music 使用服务端 artwork `bgColor`，同一封面不会因为主题明暗而换原色。
  /// Spotify 没有该字段，因此本地用 Celebi 聚类和 HCT 评分找出有代表性的颜色，
  /// 再交给 `AlbumArtworkScheme` 分别生成深浅背景，而不是预先选暗色或亮色。
  static Color? cachedDominant(String url) =>
      debugDominantOverrides[url] ?? _dominantCache[url];

  static Future<Color?> resolveDominant(String url) {
    final override = debugDominantOverrides[url];
    if (override != null) return Future.value(override);
    if (!enabled || url.isEmpty) return Future.value(null);
    final hit = _dominantCache[url];
    if (hit != null) return Future.value(hit);

    final generation = _generation;
    return _dominantPending[url] ??= _extractDominant(url, generation)
        .whenComplete(() {
          if (generation == _generation) _dominantPending.remove(url);
        });
  }

  static Future<Color?> _extractDominant(String url, int generation) async {
    ui.Image? image;
    try {
      image = await _loadImage(
        ResizeImage(CachedNetworkImageProvider(url), width: 112, height: 112),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final color = bytes == null ? null : await dominantColor(bytes);
      if (color != null && generation == _generation) {
        _dominantCache[url] = color;
      }
      return color;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }

  static Future<ui.Image> _loadImage(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(
      const ImageConfiguration(size: Size(112, 112)),
    );
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        if (!completer.isCompleted) {
          completer.completeError(error, stack ?? StackTrace.empty);
        }
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        stream.removeListener(listener);
        throw TimeoutException('artwork dominant color');
      },
    );
  }

  /// 对 RGBA 像素做 128 色聚类，再按色簇占比、HCT 色度及相邻色相占比评分。
  ///
  /// 黑白灰封面没有符合评分条件的颜色，此时用最大真实色簇而不是评分库
  /// 默认的 Google Blue。透明像素不参与聚类。
  @visibleForTesting
  static Future<Color?> dominantColor(ByteData data) async {
    final rgba = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final pixels = <int>[];
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      pixels.add(0xFF000000 | rgba[i] << 16 | rgba[i + 1] << 8 | rgba[i + 2]);
    }
    if (pixels.isEmpty) return null;

    final quantized = await QuantizerCelebi().quantize(pixels, 128);
    final colors = quantized.colorToCount;
    if (colors.isEmpty) return null;
    final fallback = colors.entries
        .reduce((best, entry) => entry.value > best.value ? entry : best)
        .key;
    final argb = Score.score(
      colors,
      desired: 1,
      fallbackColorARGB: fallback,
    ).first;
    return Color(argb);
  }

  /// 艺人头图的背景原色（在没有 Apple Music `bgColor` 时供 `ArtistArtworkScheme.from` 使用）。
  ///
  /// 与 [dominantColor] 不同，这里不做人像主题色评分，也不预先压暗——压暗交由
  /// `ArtistArtworkScheme.from`（`la.C5366a` 的 `lum * 0.6`）统一完成；
  /// 同时提高照片下边缘与左右边缘的背景权重，使头图底部能无缝融进整页背景色。
  static Color? cachedArtistColor(String url) =>
      debugArtistOverrides[url] ??
      debugDominantOverrides[url] ??
      _artistCache[url];

  static Future<Color?> resolveArtistColor(String url) {
    final override = debugArtistOverrides[url] ?? debugDominantOverrides[url];
    if (override != null) return Future.value(override);
    if (!enabled || url.isEmpty) return Future.value(null);
    final hit = _artistCache[url];
    if (hit != null) return Future.value(hit);

    final generation = _generation;
    return _artistPending[url] ??= _extractArtistColor(url, generation)
        .whenComplete(() {
          if (generation == _generation) _artistPending.remove(url);
        });
  }

  static Future<Color?> _extractArtistColor(String url, int generation) async {
    ui.Image? image;
    try {
      image = await _loadImage(
        ResizeImage(CachedNetworkImageProvider(url), width: 112, height: 112),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final color = bytes == null
          ? null
          : artistPhotoColor(bytes, width: image.width, height: image.height);
      if (color != null && generation == _generation) {
        _artistCache[url] = color;
      }
      return color;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }

  /// 对艺人照片按边缘 / 底部背景加权做 5-bit 分桶，选出主导背景簇后计算簇内加权平均色。
  @visibleForTesting
  static Color? artistPhotoColor(
    ByteData data, {
    int width = 112,
    int height = 112,
  }) {
    final pixels = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final totalPixels = pixels.length ~/ 4;
    if (totalPixels == 0) return null;
    final effectiveWidth = width > 0 ? width : 112;
    final effectiveHeight = height > 0
        ? height
        : (totalPixels / effectiveWidth).ceil().clamp(1, 4096);

    final weights = <int, double>{};
    final sumR = <int, double>{};
    final sumG = <int, double>{};
    final sumB = <int, double>{};

    for (var p = 0; p < totalPixels; p++) {
      final i = p * 4;
      if (pixels[i + 3] < 128) continue;
      final x = p % effectiveWidth;
      final y = p ~/ effectiveWidth;
      final nx = x / effectiveWidth;
      final ny = y / effectiveHeight;
      // 人物通常在中央，背景与底部衔接区在下缘（ny >= 0.65）和左右边缘（nx <= 0.18 || nx >= 0.82）
      var w = 1.0;
      if (ny >= 0.65) w += 1.8;
      if (nx <= 0.18 || nx >= 0.82 || ny <= 0.12) w += 0.9;

      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      // 4-bit 粗分桶（16 级），聚合相近的棚拍墙面或舞台灯光渐变，再取桶内真实像素均值
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      weights[key] = (weights[key] ?? 0) + w;
      sumR[key] = (sumR[key] ?? 0) + r * w;
      sumG[key] = (sumG[key] ?? 0) + g * w;
      sumB[key] = (sumB[key] ?? 0) + b * w;
    }
    if (weights.isEmpty) return null;

    var bestKey = 0;
    var bestScore = -1.0;
    weights.forEach((key, w) {
      final r = sumR[key]! / w;
      final g = sumG[key]! / w;
      final b = sumB[key]! / w;
      final maxCh = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final minCh = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final chromaBoost = 1.0 + ((maxCh - minCh) / 255.0) * 0.55;
      final score = w * chromaBoost;
      if (score > bestScore) {
        bestScore = score;
        bestKey = key;
      }
    });

    // 把主导桶及其 4-bit 邻域（曼哈顿距离 <= 2）一起加权平均，消除分桶台阶感
    final br = (bestKey >> 8) & 15;
    final bg = (bestKey >> 4) & 15;
    final bb = bestKey & 15;
    var accW = 0.0, accR = 0.0, accG = 0.0, accB = 0.0;
    weights.forEach((key, w) {
      final kr = (key >> 8) & 15;
      final kg = (key >> 4) & 15;
      final kb = key & 15;
      final dist = (kr - br).abs() + (kg - bg).abs() + (kb - bb).abs();
      if (dist <= 2) {
        accW += w;
        accR += sumR[key]!;
        accG += sumG[key]!;
        accB += sumB[key]!;
      }
    });
    if (accW <= 0) return null;
    return Color.fromARGB(
      255,
      (accR / accW).round().clamp(0, 255),
      (accG / accW).round().clamp(0, 255),
      (accB / accW).round().clamp(0, 255),
    );
  }
}

/// 根据封面 URL 异步提供氛围色；取色完成前使用 [fallback]。
class ArtworkColorBuilder extends StatefulWidget {
  final String imageUrl;
  final Color fallback;
  final Widget Function(BuildContext context, Color color) builder;

  const ArtworkColorBuilder({
    super.key,
    required this.imageUrl,
    required this.fallback,
    required this.builder,
  });

  @override
  State<ArtworkColorBuilder> createState() => _ArtworkColorBuilderState();
}

class _ArtworkColorBuilderState extends State<ArtworkColorBuilder> {
  Color? _color;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ArtworkColorBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _resolve();
  }

  void _resolve() {
    final url = widget.imageUrl;
    _color = ArtworkPalette.cached(url) ?? _color;
    if (ArtworkPalette.cached(url) != null) return;
    ArtworkPalette.resolve(url).then((color) {
      if (!mounted || widget.imageUrl != url || color == null) return;
      setState(() => _color = color);
    });
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _color ?? widget.fallback);
}
