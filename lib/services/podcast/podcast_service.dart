import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../models/podcast.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../auth/auth_constants.dart';
import '../rust_backend_bridge.dart';

/// 播客节目数据来源：解析 open.spotify.com 节目页的服务端渲染状态。
///
/// 为什么不用内部接口 / Web API：
/// - 桌面版 client_id 的公开 Web API（api.spotify.com /v1/shows）长期 429 限流；
/// - 桌面 / 移动端的节目页走 hm:// 桥或未捕获的 persisted query，均不可复用；
/// - open.spotify.com 的节目页 HTML 内嵌 base64 的 `initialState` JSON，
///   含节目完整信息与最新一页单集（约 12 集），无需鉴权、不限流。
///
/// 单集更多元数据（播放状态等）可再用 Pathfinder `decorateContextEpisodesOrChapters` 补全。
///
/// 页面解析（initialState → 节目 / 单集）由 Rust `catalog_backend` 完成；
/// 页面本身默认也由 Rust 拉取，需要走自定义网关时改用 Dart HTTP 拉取后交给 Rust 解析。
class PodcastService {
  final http.Client? _client;

  /// 由 Rust 拉取页面（按目标地址选路代理）。注入自定义 http.Client（测试）时为 false。
  final bool _useRustBackend;

  /// 注意：UA 决定返回的页面变体 —— 完整的桌面 Chrome UA 拿到的是无 initialState 的桌面版
  /// SPA 壳；这个精简 UA 才会拿到内嵌实体数据的 mobile-web-player 页面（tool/show_page_probe.py 实测）。
  static String get _userAgent => SpotifyAuthConstants.podcastUserAgent;

  PodcastService([http.Client? client, bool? useRustBackend])
    : _client = client,
      _useRustBackend = useRustBackend ?? client == null;

  /// 调试钩子（探针用）：拿到原始 HTML 时回调。
  static void Function(String html)? debugHtml;

  /// 取节目详情与最新单集；失败（网络 / 结构变化）抛 [PodcastServiceException]。
  Future<PodcastShow> fetchShow(String showId) async {
    final url = 'https://open.spotify.com/show/$showId';
    final proxy = await _rustProxy(url);
    if (proxy != null) {
      return _rustCall(
        () => rust.rustFetchPodcastShow(showId: showId, proxy: proxy),
        _showFromDto,
      );
    }
    final html = await _fetchHtml(url);
    return _rustCall(
      () async => rust.rustParsePodcastShowHtml(showId: showId, html: html),
      _showFromDto,
    );
  }

  /// 取单集详情（open.spotify.com/episode/{id} 的 initialState）。
  ///
  /// 主要用于「最近播放」等只带单集 URI 的入口：解析出所属节目后再打开节目页。
  /// 单集没有自己的封面时回落到节目封面。失败抛 [PodcastServiceException]。
  Future<PodcastEpisode> fetchEpisode(String episodeId) async {
    final url = 'https://open.spotify.com/episode/$episodeId';
    final proxy = await _rustProxy(url);
    if (proxy != null) {
      return _rustCall(
        () => rust.rustFetchPodcastEpisode(episodeId: episodeId, proxy: proxy),
        _episodeFromDto,
      );
    }
    final html = await _fetchHtml(url);
    return _rustCall(
      () async =>
          rust.rustParsePodcastEpisodeHtml(episodeId: episodeId, html: html),
      _episodeFromDto,
    );
  }

  /// Rust 直接拉取页面时使用的代理；返回 null 表示由 Dart 拉取（测试 / 需走网关）。
  Future<String?> _rustProxy(String url) async {
    if (!_useRustBackend || !RustCore.ready) return null;
    return RustBackendBridge.proxyForUrl(url);
  }

  /// 调用 Rust 拉取 / 解析，把错误串转成 [PodcastServiceException]：
  /// `http:{status}:{message}` 带状态码，其余错误串即可直接展示的中文说明。
  static Future<R> _rustCall<D, R>(
    Future<D> Function() call,
    R Function(D dto) convert,
  ) async {
    if (!RustCore.ready) {
      throw const PodcastServiceException('页面数据无法解析：Rust 核心未加载');
    }
    try {
      return convert(await call());
    } catch (e) {
      final msg = e.toString();
      final m = RegExp(r'^http:(\d+):(.*)$').firstMatch(msg);
      if (m != null) {
        throw PodcastServiceException(m.group(2)!, int.parse(m.group(1)!));
      }
      throw PodcastServiceException(msg);
    }
  }

  /// 用 Dart HTTP 拉取页面 HTML（解析交给 Rust）。
  Future<String> _fetchHtml(String url) async {
    final http.Response res;
    final c = _client ?? http.Client();
    try {
      res = await c.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _userAgent,
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      );
    } catch (e) {
      if (_client == null) c.close();
      throw PodcastServiceException('网络请求失败，请检查网络：$e');
    }
    if (_client == null) c.close();
    if (res.statusCode != 200) {
      throw PodcastServiceException('加载失败', res.statusCode);
    }
    final String html;
    try {
      html = utf8.decode(res.bodyBytes);
    } on FormatException {
      throw const PodcastServiceException('页面数据无法解析');
    }
    debugHtml?.call(html);
    return html;
  }
}

/// 节目页加载失败。[message] 为简体中文说明，可直接展示。
class PodcastServiceException implements Exception {
  final String message;
  final int? statusCode;

  const PodcastServiceException(this.message, [this.statusCode]);

  @override
  String toString() =>
      statusCode == null ? message : '$message（HTTP $statusCode）';
}

PodcastShow _showFromDto(rust.RustPodcastShowDto dto) => PodcastShow(
  id: dto.id,
  uri: dto.uri,
  name: dto.name,
  publisher: dto.publisher,
  description: dto.description,
  images: [for (final img in dto.images) RustBackendBridge.imageFromDto(img)],
  episodes: [for (final ep in dto.episodes) _episodeFromDto(ep)],
);

PodcastEpisode _episodeFromDto(rust.RustPodcastEpisodeDto dto) => PodcastEpisode(
  id: dto.id,
  uri: dto.uri,
  name: dto.name,
  description: dto.description,
  durationMs: dto.durationMs,
  releaseDate: dto.releaseDate,
  images: [for (final img in dto.images) RustBackendBridge.imageFromDto(img)],
  showUri: dto.showUri,
  showName: dto.showName,
  previewUrl: dto.previewUrl,
  resumeMs: dto.resumeMs,
  played: dto.played,
);
