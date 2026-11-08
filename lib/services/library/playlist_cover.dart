import 'dart:convert';

import '../../models/image.dart';

/// 歌单封面地址的推导规则（与官方客户端一致）：
///
/// 1. `attributes.pictureSize`：服务端已生成的各尺寸地址，优先 large → default → small；
/// 2. `attributes.picture`：用户上传封面的 20 字节图片 ID（Base64），
///    转十六进制即 `https://i.scdn.co/image/{id}`；
/// 3. 都没有（未设置封面的自建歌单）：取前几首曲目的专辑封面，
///    ≥ 4 张不同封面时拼成 `mosaic.scdn.co` 四宫格，否则用第一张。
class PlaylistCover {
  PlaylistCover._();

  static const String _imageBase = 'https://i.scdn.co/image/';
  static const String _mosaicBase = 'https://mosaic.scdn.co/640/';

  /// 640px 专辑封面的图片 ID 前缀；四宫格要求同一尺寸的 ID。
  static const String _albumLargePrefix = 'ab67616d0000b273';

  /// 拼四宫格需要的不同封面数量。
  static const int mosaicCount = 4;

  /// 按规则 1、2 从歌单 attributes 取封面；都没有时返回空列表（交给规则 3）。
  static List<SpotifyImage> fromAttributes(Map<String, dynamic>? attributes) {
    if (attributes == null) return const [];
    final sizes = attributes['pictureSize'];
    if (sizes is List) {
      final pictures = sizes.whereType<Map<String, dynamic>>().toList();
      for (final target in const ['large', 'default', 'small']) {
        for (final p in pictures) {
          final url = p['url'];
          if (p['targetName'] == target && url is String && url.isNotEmpty) return [SpotifyImage(url: url)];
        }
      }
    }
    final picture = attributes['picture'];
    if (picture is String && picture.isNotEmpty) {
      final id = _hexFromBase64(picture);
      if (id != null) return [SpotifyImage(url: '$_imageBase$id')];
    }
    return const [];
  }

  /// 规则 3：由曲目的专辑封面（按曲目顺序，每首一组尺寸）生成歌单封面。
  static List<SpotifyImage> fromAlbumCovers(Iterable<List<SpotifyImage>> covers) {
    final ids = <String>[];
    String? firstUrl;
    for (final images in covers) {
      if (images.isEmpty) continue;
      firstUrl ??= images.first.url;
      final id = _largeAlbumId(images);
      if (id != null && !ids.contains(id)) ids.add(id);
      if (ids.length == mosaicCount) break;
    }
    if (ids.length == mosaicCount) return [SpotifyImage(url: '$_mosaicBase${ids.join()}')];
    return firstUrl == null ? const [] : [SpotifyImage(url: firstUrl)];
  }

  /// 一组尺寸里 640px 那张的图片 ID（`i.scdn.co/image/ab67616d0000b273…`）。
  static String? _largeAlbumId(List<SpotifyImage> images) {
    for (final image in images) {
      final index = image.url.indexOf(_imageBase);
      if (index < 0) continue;
      final id = image.url.substring(index + _imageBase.length);
      if (id.startsWith(_albumLargePrefix)) return id;
    }
    return null;
  }

  static String? _hexFromBase64(String value) {
    try {
      final bytes = base64.decode(base64.normalize(value.replaceAll('-', '+').replaceAll('_', '/')));
      if (bytes.isEmpty) return null;
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    } on FormatException {
      return null;
    }
  }
}
