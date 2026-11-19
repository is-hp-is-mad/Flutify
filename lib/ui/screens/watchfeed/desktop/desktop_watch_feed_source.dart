import '../../../../models/watch_feed.dart';
import '../../../../services/spotify_api_service.dart';

/// 窗口尺寸分档（见官方 `--size` 变量：≤ 800 小、≤ 1050 中、> 1050 大）。
enum DesktopWatchFeedSize { small, medium, large }

/// 数据来源：实体 feed 按 offset 分页，#标签 feed 按令牌分页。
abstract class DesktopWatchFeedSource {
  bool get hasMore;
  Future<List<WatchFeedItem>> next();
}

class EntityWatchFeedSource implements DesktopWatchFeedSource {
  EntityWatchFeedSource(this.api, this.uri, WatchFeedEntityPage? first) {
    if (first != null) _pending = first;
  }

  final SpotifyApiService api;
  final String uri;
  WatchFeedEntityPage? _pending;
  int? _nextOffset = 0;
  int _loaded = 0;

  /// 官方：已加载不超过 50 条且服务端还有下一页时才继续加载。
  @override
  bool get hasMore => _nextOffset != null && _loaded <= 50;

  @override
  Future<List<WatchFeedItem>> next() async {
    final page =
        _pending ??
        await api.watchFeed.fetchEntityFeed(uri, offset: _nextOffset ?? 0);
    _pending = null;
    _nextOffset = page.nextOffset;
    _loaded += page.items.length;
    return page.items;
  }
}

class DiscoveryWatchFeedSource implements DesktopWatchFeedSource {
  DiscoveryWatchFeedSource(this.api, this.uri);

  final SpotifyApiService api;
  final String uri;
  bool _started = false;
  dynamic _token;

  @override
  bool get hasMore => !_started || _token != null;

  @override
  Future<List<WatchFeedItem>> next() async {
    final page = await api.watchFeed.fetchFeed(uri, pageToken: _token);
    _started = true;
    _token = page.nextPageToken;
    return page.items;
  }
}
