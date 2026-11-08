import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/image.dart';
import '../../models/podcast.dart';

/// 播客节目数据来源：解析 open.spotify.com 节目页的服务端渲染状态。
///
/// 为什么不用内部接口 / Web API：
/// - 桌面版 client_id 的公开 Web API（api.spotify.com /v1/shows）长期 429 限流；
/// - 桌面 / 移动端的节目页走 hm:// 桥或未捕获的 persisted query，均不可复用；
/// - open.spotify.com 的节目页 HTML 内嵌 base64 的 `initialState` JSON，
///   含节目完整信息与最新一页单集（约 12 集），无需鉴权、不限流。
///
/// 单集更多元数据（播放状态等）可再用 Pathfinder `decorateContextEpisodesOrChapters` 补全。
class PodcastService {
  final http.Client _client;

  /// 注意：UA 决定返回的页面变体 —— 完整的桌面 Chrome UA 拿到的是无 initialState 的桌面版
  /// SPA 壳；这个精简 UA 才会拿到内嵌实体数据的 mobile-web-player 页面（tool/show_page_probe.py 实测）。
  static const String _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';

  PodcastService([http.Client? client]) : _client = client ?? http.Client();

  static final RegExp _initialStateRe = RegExp(
    r'<script id="initialState"[^>]*>(.*?)</script>',
    dotAll: true,
  );

  /// 调试钩子（探针用）：拿到原始 HTML 时回调。
  static void Function(String html)? debugHtml;

  /// 取节目详情与最新单集；失败（网络 / 结构变化）抛 [PodcastServiceException]。
  Future<PodcastShow> fetchShow(String showId) async {
    final state = await _fetchInitialState(
      'https://open.spotify.com/show/$showId',
    );
    final entities = state['entities'] as Map<String, dynamic>?;
    final items = entities?['items'] as Map<String, dynamic>?;
    final show = items?['spotify:show:$showId'] as Map<String, dynamic>?;
    if (show == null) throw const PodcastServiceException('没有找到对应的节目');

    return PodcastShow(
      id: showId,
      uri: show['uri'] as String? ?? 'spotify:show:$showId',
      name: show['name'] as String? ?? '',
      // publisher 可能是字符串或 {name: ...} 对象
      publisher: switch (show['publisher']) {
        final String s => s,
        final Map<String, dynamic> m => m['name'] as String? ?? '',
        _ => '',
      },
      description: show['description'] as String? ?? '',
      images: _coverArt(show['coverArt']),
      episodes: _episodes(show),
    );
  }

  /// 取单集详情（open.spotify.com/episode/{id} 的 initialState）。
  ///
  /// 主要用于「最近播放」等只带单集 URI 的入口：解析出所属节目后再打开节目页。
  /// 失败抛 [PodcastServiceException]。
  Future<PodcastEpisode> fetchEpisode(String episodeId) async {
    final state = await _fetchInitialState(
      'https://open.spotify.com/episode/$episodeId',
    );
    final items =
        (state['entities'] as Map<String, dynamic>?)?['items']
            as Map<String, dynamic>?;
    final data = items?['spotify:episode:$episodeId'] as Map<String, dynamic>?;
    if (data == null || data['__typename'] != 'Episode') {
      throw const PodcastServiceException('没有找到对应的单集');
    }
    // 所属节目：单集页用 showOrAudiobook（PodcastResponseWrapper），搜索结果用 podcastV2；
    // 两者都是 {data: {...}} 包装
    final wrapper =
        (data['showOrAudiobook'] ?? data['podcastV2']) as Map<String, dynamic>?;
    final showData = (wrapper?['data'] as Map<String, dynamic>?) ?? wrapper;
    final showUri = showData?['uri'] as String? ?? '';
    final showName = showData?['name'] as String? ?? '';
    var episode = _episodeFromData(data, showUri: showUri, showName: showName);
    if (episode == null) throw const PodcastServiceException('单集数据无法解析');
    // 单集没有自己的封面时回落到节目封面
    if (episode.images.isEmpty) {
      final showCovers = _coverArt(showData?['coverArt']);
      if (showCovers.isNotEmpty) {
        episode = PodcastEpisode(
          id: episode.id,
          uri: episode.uri,
          name: episode.name,
          description: episode.description,
          durationMs: episode.durationMs,
          releaseDate: episode.releaseDate,
          images: showCovers,
          showUri: episode.showUri,
          showName: episode.showName,
          previewUrl: episode.previewUrl,
          resumeMs: episode.resumeMs,
          played: episode.played,
        );
      }
    }
    return episode;
  }

  /// 拉取页面并解析 initialState（base64 JSON）。
  Future<Map<String, dynamic>> _fetchInitialState(String url) async {
    final http.Response res;
    try {
      res = await _client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': _userAgent,
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      );
    } catch (e) {
      throw PodcastServiceException('网络请求失败，请检查网络：$e');
    }
    if (res.statusCode != 200) {
      throw PodcastServiceException('加载失败', res.statusCode);
    }
    final html = utf8.decode(res.bodyBytes);
    debugHtml?.call(html);
    final match = _initialStateRe.firstMatch(html);
    if (match == null) throw const PodcastServiceException('页面结构已变化，无法解析');
    try {
      return jsonDecode(utf8.decode(base64.decode(match.group(1)!.trim())))
          as Map<String, dynamic>;
    } catch (_) {
      throw const PodcastServiceException('页面数据无法解析');
    }
  }

  /// 节目页内嵌的单集列表（`pages.items`，ContextEpisodePage）。
  List<PodcastEpisode> _episodes(Map<String, dynamic> show) {
    final pages = show['pages'] as Map<String, dynamic>?;
    final items = pages?['items'] as List<dynamic>?;
    if (items == null) return const [];
    final showName = show['name'] as String? ?? '';
    final showUri = show['uri'] as String? ?? '';
    return [
      for (final item in items)
        if (item is Map<String, dynamic>)
          ?_episode(item['entity'], showUri: showUri, showName: showName),
    ];
  }

  /// 单个单集实体（`entity.data`，__typename = Episode）。
  PodcastEpisode? _episode(
    Object? entity, {
    required String showUri,
    required String showName,
  }) {
    if (entity is! Map<String, dynamic>) return null;
    return _episodeFromData(
      entity['data'],
      showUri: showUri,
      showName: showName,
    );
  }

  /// 从 Episode 数据本体解析（节目页列表项与单集页实体共用）。
  PodcastEpisode? _episodeFromData(
    Object? raw, {
    required String showUri,
    required String showName,
  }) {
    final data = raw as Map<String, dynamic>?;
    if (data == null || data['__typename'] != 'Episode') return null;
    final uri = data['uri'] as String? ?? '';
    final id = uri.startsWith('spotify:episode:')
        ? uri.substring(16)
        : (data['id'] as String? ?? '');
    if (id.isEmpty) return null;

    // 播放状态
    final playedState = data['playedState'] as Map<String, dynamic>?;
    final resumeMs = playedState?['playPositionMilliseconds'] as int? ?? 0;
    final played = playedState?['state'] == 'FINISHED';

    // 试听片段（audio.items 里是若干 mp3-preview 地址）
    String? previewUrl;
    final audio = data['audio'] as Map<String, dynamic>?;
    final audioItems = audio?['items'] as List<dynamic>?;
    if (audioItems != null) {
      for (final a in audioItems) {
        final url = (a as Map<String, dynamic>?)?['url'] as String?;
        if (url != null && url.isNotEmpty) {
          previewUrl = url;
          break;
        }
      }
    }

    // 发布日期：releaseDate 可能是 {isoString} 或纯文本
    final release = data['releaseDate'];
    final releaseDate = release is Map<String, dynamic>
        ? (release['isoString'] as String? ?? '')
        : (release as String? ?? '');

    // 时长：{totalMilliseconds} 或直接毫秒数
    final duration = data['duration'];
    final durationMs = duration is Map<String, dynamic>
        ? (duration['totalMilliseconds'] as int? ?? 0)
        : (duration as int? ?? 0);

    return PodcastEpisode(
      id: id,
      uri: uri,
      name: data['name'] as String? ?? '',
      description: data['description'] as String? ?? '',
      durationMs: durationMs,
      releaseDate: releaseDate,
      images: _coverArt(data['coverArt']),
      showUri: showUri,
      showName: showName,
      previewUrl: previewUrl ?? '',
      resumeMs: played ? 0 : resumeMs,
      played: played,
    );
  }

  /// coverArt.sources → 图片列表（大的在前）。
  static List<SpotifyImage> _coverArt(Object? coverArt) {
    final sources =
        (coverArt as Map<String, dynamic>?)?['sources'] as List<dynamic>?;
    if (sources == null) return const [];
    final images = [
      for (final s in sources)
        if (s is Map<String, dynamic> && s['url'] is String)
          SpotifyImage(
            url: s['url'] as String,
            width: s['width'] as int?,
            height: s['height'] as int?,
          ),
    ];
    images.sort((a, b) => (b.width ?? 0).compareTo(a.width ?? 0));
    return images;
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
