import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../lyrics/zh_script.dart';

/// Apple Music 目录里与 Spotify 艺人同名的艺人形象：方形照片与可选的动态视频。
class AppleMusicArtistMedia {
  /// mzstatic 图片模板（含 `{w}x{h}{c}.{f}` 占位符）。
  final String artworkTemplate;

  /// Apple Music 接口提供的头图底色（6 位或 8 位十六进制，如 `"6b6968"`）。
  final String? bgColor;

  /// `editorialVideo` 的 HLS 主清单，没有动态视频时为空；用 [AppleMusicArtistService.video] 下载。
  final String? videoUrl;

  /// 视频宽高比（方形 1.0，宽屏 16:9）。
  final double videoAspectRatio;

  const AppleMusicArtistMedia({
    required this.artworkTemplate,
    this.bgColor,
    this.videoUrl,
    this.videoAspectRatio = 1,
  });

  /// [width]×[height] 像素、居中裁切的照片地址。
  String artworkUrl(int width, int height) => artworkTemplate
      .replaceAll('{w}', '$width')
      .replaceAll('{h}', '$height')
      .replaceAll('{c}', 'cc')
      .replaceAll('{f}', 'jpg');
}

/// Apple Music 艺人头图（取法与 Apple Music Android 7.0 艺人页一致）：
///
/// - 用 music.apple.com 网页播放器内嵌的公开开发者令牌访问 `amp-api.music.apple.com` 目录接口，
///   不需要 Apple 账号；
/// - 按名字搜索艺人，只接受规范化后与 Spotify 艺人名完全一致的结果，宁可不显示也不配错人；
/// - 视频取 `editorialVideo`：窄屏 `motionArtistSquare1x1`、宽屏 `motionArtistWide16x9`，
///   缺失时退到 `motionArtistSingular16x9`（与 App 的取法相同）。主清单是不加密的 HLS，
///   每个码率档都是单个 fMP4 文件，直接下载交给 `<video>` 循环播放。
///
/// 一切失败都返回 null：这是装饰性内容，不能影响艺人页的其他部分。
class AppleMusicArtistService {
  final http.Client client;

  /// 测试环境关闭（不发真实请求），见 [SpotifyApiService.appleMusicArtist]。
  final bool enabled;

  AppleMusicArtistService(this.client, {this.enabled = true});

  static const _origin = 'https://music.apple.com';
  static const _api = 'https://amp-api.music.apple.com';
  static const _timeout = Duration(seconds: 12);

  /// 视频大小上限：最低档方形视频约 2.5MB，留足余量又不至于误下整段高码率。
  static const _videoLimit = 8 * 1024 * 1024;

  /// 窄屏方形视频的目标边长；宽屏取高度不超过这一档的 16:9 码率。
  static const _squareTarget = 768;
  static const _wideTargetHeight = 576;

  String? _token;
  DateTime _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _pendingToken;

  final Map<String, ({DateTime until, AppleMusicArtistMedia? media})> _cache =
      {};
  final Map<String, Future<AppleMusicArtistMedia?>> _pending = {};
  final Map<String, ({DateTime until, Uint8List? bytes})> _videoCache = {};
  final Map<String, Future<Uint8List?>> _pendingVideo = {};

  /// [name] 为 Spotify 艺人名（已按界面语言本地化）；[language] 为 [AppLocale.spotifyLanguage]。
  Future<AppleMusicArtistMedia?> find(
    String name, {
    required String language,
    required bool wide,
  }) {
    final trimmed = name.trim();
    if (!enabled || trimmed.isEmpty) return Future.value(null);
    final key = '$language|$wide|${normalize(trimmed)}';
    final cached = _cache[key];
    if (cached != null && cached.until.isAfter(DateTime.now())) {
      return Future.value(cached.media);
    }
    return _pending.putIfAbsent(key, () async {
      AppleMusicArtistMedia? media;
      var failed = false;
      try {
        media = await _load(trimmed, language, wide);
      } catch (_) {
        failed = true;
      } finally {
        _pending.remove(key);
      }
      if (_cache.length >= 24) _cache.remove(_cache.keys.first);
      _cache[key] = (
        until: DateTime.now().add(
          failed ? const Duration(minutes: 1) : const Duration(minutes: 30),
        ),
        media: media,
      );
      return media;
    });
  }

  Future<AppleMusicArtistMedia?> _load(
    String name,
    String language,
    bool wide,
  ) async {
    final token = await _ensureToken();
    if (token == null) throw StateError('No Apple Music token');
    final (storefront, locale) = storefrontFor(language);
    var artist = await _search(token, name, storefront, locale);
    // 本地化名对不上时（如英文界面的「周杰伦」）再用美区英文目录试一次
    if (artist == null && storefront != 'us') {
      artist = await _search(token, name, 'us', 'en-US');
    }
    if (artist == null) return null;
    final attributes = artist['attributes'] as Map<String, dynamic>;
    final artwork = attributes['artwork'] as Map<String, dynamic>?;
    final template = artwork?['url'] as String? ?? '';
    if (template.isEmpty) return null;
    final editorialVideo = attributes['editorialVideo'] as Map<String, dynamic>?;
    final (videoUrl, ratio) = pickVideo(
      editorialVideo,
      wide: wide,
    );
    final bgColor = pickBgColor(
      artwork: artwork,
      videos: editorialVideo,
      wide: wide,
    );
    return AppleMusicArtistMedia(
      artworkTemplate: template,
      bgColor: bgColor,
      videoUrl: videoUrl,
      videoAspectRatio: ratio,
    );
  }

  /// 下载 [media] 的动态视频（单个 H.264 fMP4）；没有视频或失败时返回 null，此时只显示照片。
  /// 只保留最近几段，避免来回切换艺人时占用过多内存。
  Future<Uint8List?> video(AppleMusicArtistMedia media) {
    final url = media.videoUrl;
    if (!enabled || url == null) return Future.value(null);
    final cached = _videoCache[url];
    if (cached != null && cached.until.isAfter(DateTime.now())) {
      return Future.value(cached.bytes);
    }
    return _pendingVideo.putIfAbsent(url, () async {
      Uint8List? bytes;
      try {
        bytes = await _downloadVideo(url, media.videoAspectRatio);
      } catch (_) {
      } finally {
        _pendingVideo.remove(url);
      }
      if (_videoCache.length >= 3) _videoCache.remove(_videoCache.keys.first);
      _videoCache[url] = (
        until: DateTime.now().add(
          Duration(minutes: bytes == null ? 1 : 30),
        ),
        bytes: bytes,
      );
      return bytes;
    });
  }

  // ---------------------------------------------------------------------------
  // 令牌
  // ---------------------------------------------------------------------------

  Future<String?> _ensureToken() {
    final token = _token;
    if (token != null && DateTime.now().isBefore(_tokenExpiry)) {
      return Future.value(token);
    }
    return _pendingToken ??= _fetchToken().whenComplete(
      () => _pendingToken = null,
    );
  }

  /// 网页播放器把开发者令牌（ES256 JWT，`iss: AMPWebPlay`）写在入口脚本里。
  Future<String?> _fetchToken() async {
    final page = await _get(Uri.parse('$_origin/us/browse'));
    final script = RegExp(r'/assets/index[^"]*\.js').firstMatch(page)?.group(0);
    if (script == null) return null;
    final js = await _get(Uri.parse('$_origin$script'));
    final token = extractToken(js);
    if (token == null) return null;
    _token = token;
    _tokenExpiry =
        tokenExpiry(token)?.subtract(const Duration(hours: 1)) ??
        DateTime.now().add(const Duration(hours: 12));
    return token;
  }

  static final RegExp _jwt = RegExp(
    r'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}',
  );

  /// 脚本里第一个签发方为 AMPWebPlay 的 JWT。
  static String? extractToken(String script) {
    for (final m in _jwt.allMatches(script)) {
      final payload = _payload(m.group(0)!);
      if (payload?['iss'] == 'AMPWebPlay') return m.group(0);
    }
    return null;
  }

  static DateTime? tokenExpiry(String token) {
    final exp = _payload(token)?['exp'];
    return exp is num
        ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000)
        : null;
  }

  static Map<String, dynamic>? _payload(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 目录
  // ---------------------------------------------------------------------------

  /// 界面语言 → (店面, 显示语言)。艺人名按显示语言返回，与 Spotify 的本地化名一致才能对上。
  static (String, String) storefrontFor(String language) => switch (language) {
    'zh-CN' => ('cn', 'zh-Hans-CN'),
    'zh-TW' => ('tw', 'zh-Hant-TW'),
    'ja' => ('jp', 'ja'),
    _ => ('us', 'en-US'),
  };

  Future<Map<String, dynamic>?> _search(
    String token,
    String name,
    String storefront,
    String locale,
  ) async {
    final uri = Uri.parse('$_api/v1/catalog/$storefront/search').replace(
      queryParameters: {
        'term': name,
        'types': 'artists',
        'limit': '5',
        'l': locale,
        'extend': 'editorialVideo',
        'platform': 'web',
      },
    );
    final body = await _get(
      uri,
      headers: {'Authorization': 'Bearer $token', 'Origin': _origin},
    );
    final data = jsonDecode(body);
    final items = (((data as Map?)?['results'] as Map?)?['artists']
        as Map?)?['data'];
    if (items is! List) return null;
    return matchArtist(name, items.whereType<Map<String, dynamic>>());
  }

  /// 名字规范化后完全一致的第一位艺人；有动态视频的同名艺人优先（同名常是翻唱 / 致敬账号）。
  static Map<String, dynamic>? matchArtist(
    String name,
    Iterable<Map<String, dynamic>> artists,
  ) {
    final target = normalize(name);
    if (target.isEmpty) return null;
    Map<String, dynamic>? first;
    for (final artist in artists) {
      final attributes = artist['attributes'];
      if (attributes is! Map<String, dynamic>) continue;
      if (normalize(attributes['name'] as String? ?? '') != target) continue;
      final video = attributes['editorialVideo'];
      if (video is Map && video.isNotEmpty) return artist;
      first ??= artist;
    }
    return first;
  }

  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// 忽略大小写、空白与标点，繁体统一成简体（「周杰倫」=「周杰伦」，「G.E.M.」=「GEM」）。
  static String normalize(String name) {
    final lower = name.toLowerCase().replaceAll(_nonWord, '');
    return ZhScript.countTraditional(lower) > 0
        ? ZhScript.convert(lower, toSimplified: true)
        : lower;
  }

  /// 返回 (主清单地址, 宽高比)；没有可用视频时地址为 null。
  static (String?, double) pickVideo(
    Map<String, dynamic>? videos, {
    required bool wide,
  }) {
    if (videos == null) return (null, 1);
    final preferred = wide ? 'motionArtistWide16x9' : 'motionArtistSquare1x1';
    for (final (flavor, ratio) in [
      (preferred, wide ? 16 / 9 : 1.0),
      ('motionArtistSingular16x9', 16 / 9),
    ]) {
      final url = (videos[flavor] as Map?)?['video'];
      if (url is String && Uri.tryParse(url)?.scheme == 'https') {
        return (url, ratio);
      }
    }
    return (null, 1);
  }

  static final RegExp _hexColor = RegExp(r'^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$');

  /// 取头图 `bgColor`（与 Apple Music Android 7.0 `profiles2.b.s` 一致）：
  /// 有动态视频时优先用对应规格 `previewFrame.bgColor`，否则退回 `artwork.bgColor`。
  static String? pickBgColor({
    Map<String, dynamic>? artwork,
    Map<String, dynamic>? videos,
    required bool wide,
  }) {
    String? clean(Object? raw) {
      if (raw is! String) return null;
      final trimmed = raw.trim();
      if (!_hexColor.hasMatch(trimmed)) return null;
      return trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
    }

    if (videos != null) {
      final preferred = wide ? 'motionArtistWide16x9' : 'motionArtistSquare1x1';
      for (final flavor in [preferred, 'motionArtistSingular16x9']) {
        final entry = videos[flavor] as Map?;
        final videoUrl = entry?['video'];
        if (videoUrl is String && Uri.tryParse(videoUrl)?.scheme == 'https') {
          final previewBg = clean((entry?['previewFrame'] as Map?)?['bgColor']);
          if (previewBg != null) return previewBg;
          break;
        }
      }
    }
    return clean(artwork?['bgColor']);
  }

  // ---------------------------------------------------------------------------
  // 视频
  // ---------------------------------------------------------------------------

  Future<Uint8List> _downloadVideo(String masterUrl, double ratio) async {
    final master = Uri.parse(masterUrl);
    final variant = pickVariant(
      await _get(master),
      wide: ratio > 1.2,
    );
    if (variant == null) throw StateError('No AVC variant');
    final media = await _get(master.resolve(variant));
    final file = mediaFile(media);
    if (file == null) throw StateError('Unsupported media playlist');
    return _getBytes(master.resolve(variant).resolve(file));
  }

  static final RegExp _streamInf = RegExp(r'^#EXT-X-STREAM-INF:(.*)$');

  /// 主清单里 H.264（avc1）、SDR、分辨率不超过目标的最高一档；不够时取最低档。
  static String? pickVariant(String master, {required bool wide}) {
    final lines = const LineSplitter().convert(master);
    String? best, smallest;
    var bestScore = -1, smallestScore = 1 << 30;
    for (var i = 0; i < lines.length - 1; i++) {
      final m = _streamInf.firstMatch(lines[i]);
      if (m == null) continue;
      final attrs = m.group(1)!;
      final uri = lines[i + 1].trim();
      if (uri.isEmpty || uri.startsWith('#')) continue;
      if (!attrs.contains('avc1') || attrs.contains('VIDEO-RANGE=PQ')) {
        continue;
      }
      final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(attrs);
      final bandwidth =
          int.tryParse(
            RegExp(r'(?:^|,)BANDWIDTH=(\d+)').firstMatch(attrs)?.group(1) ??
                '',
          ) ??
          0;
      if (res == null) continue;
      final h = int.parse(res.group(2)!);
      final limit = wide ? _wideTargetHeight : _squareTarget;
      // 同分辨率选码率较高的一档
      final score = h * 100000000 + bandwidth;
      if (h <= limit && score > bestScore) {
        bestScore = score;
        best = uri;
      }
      if (score < smallestScore) {
        smallestScore = score;
        smallest = uri;
      }
    }
    return best ?? smallest;
  }

  /// 码率档清单里的媒体文件：所有分段与初始化段都指向同一个 fMP4 时返回它，否则 null。
  static String? mediaFile(String playlist) {
    final files = <String>{};
    for (final raw in const LineSplitter().convert(playlist)) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
        if (uri != null) files.add(uri);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        files.add(line);
      } else if (line.startsWith('#EXT-X-KEY:') && !line.contains('NONE')) {
        return null; // 加密分段不能直接播放
      }
    }
    return files.length == 1 ? files.single : null;
  }

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------

  Future<String> _get(Uri uri, {Map<String, String>? headers}) async {
    final response = await client.get(uri, headers: headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw StateError('Apple Music HTTP ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Future<Uint8List> _getBytes(Uri uri) async {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw StateError('Apple Music video HTTP ${response.statusCode}');
    }
    if ((response.contentLength ?? 0) > _videoLimit) {
      await response.stream.listen(null).cancel();
      throw StateError('Apple Music video exceeds size limit');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(_timeout)) {
      if (bytes.length + chunk.length > _videoLimit) {
        throw StateError('Apple Music video exceeds size limit');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
