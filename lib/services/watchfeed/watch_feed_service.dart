import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../../models/watch_feed.dart';
import '../auth/proto_codec.dart';
import '../pathfinder/pathfinder_client.dart';
import '../pathfinder/pathfinder_operations.dart';
import 'watch_feed_parser.dart';

/// Watch Feed 接口失败（含未登录）。
class WatchFeedException implements Exception {
  final String message;
  final int? statusCode;

  const WatchFeedException(this.message, [this.statusCode]);

  @override
  String toString() => 'WatchFeedException($statusCode): $message';
}

/// 官方竖滑发现流（Watch Feed）的数据通道：spclient protobuf 接口。
///
/// 会话头（Bearer、client-token、语言）沿用 [SpotifyApiService] 的 `_headers`，
/// 但平台身份必须声明为 Android：实测同一令牌带 `app-platform: WebPlayer` 时这些接口
/// 返回空内容（204 / 空 200），声明 Android 后返回完整数据。
class WatchFeedService {
  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;

  WatchFeedService(this._client, {required this._headers});

  /// 桌面版实体 feed 走 Pathfinder（Web 播放器身份，用会话原本的头，不改平台）。
  late final PathfinderClient _pathfinder = PathfinderClient(
    _client,
    headers: _headers,
  );

  /// 实体 feed（`spotify:watch-feed:{artist|album|playlist}:<id>`）的一页；官方网页版每页 25 条。
  Future<WatchFeedEntityPage> fetchEntityFeed(
    String feedUri, {
    int offset = 0,
    int limit = 25,
  }) async {
    try {
      final data = await _pathfinder.query(
        PathfinderOperation.watchFeedEntity,
        {'watchFeedUri': feedUri, 'limit': limit, 'offset': offset},
      );
      return WatchFeedParser.parseEntityFeed(data);
    } on PathfinderException catch (e) {
      throw WatchFeedException(e.message, e.statusCode);
    }
  }

  /// 声明的 Android 客户端版本（与逆向所用安装包一致）。
  static const String androidAppVersion = '9.2.0.26';

  Future<Map<String, String>> _protoHeaders() async {
    final session = await _headers();
    if (!session.keys.any((k) => k.toLowerCase() == 'authorization')) {
      throw const WatchFeedException('未登录');
    }
    // 去掉会话里的客户端身份头（键大小写不一），换成 Android 身份。
    const overridden = {
      'content-type',
      'accept',
      'app-platform',
      'spotify-app-version',
      'user-agent',
      'origin',
      'referer',
    };
    return {
      for (final e in session.entries)
        if (!overridden.contains(e.key.toLowerCase())) e.key: e.value,
      'content-type': 'application/protobuf',
      'accept': 'application/protobuf',
      'app-platform': 'Android',
      'spotify-app-version': androidAppVersion,
      'user-agent': 'Spotify/$androidAppVersion Android/34 (Pixel 8)',
    };
  }

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse(
    '${SpotifyEndpoints.defaultSpClientBase}/$path',
  ).replace(queryParameters: query);

  Future<Uint8List?> _get(String path, Map<String, String> query) async {
    final res = await _client.get(
      _uri(path, query),
      headers: await _protoHeaders(),
    );
    if (res.statusCode == 204) return null;
    if (res.statusCode != 200) {
      throw WatchFeedException('请求失败', res.statusCode);
    }
    return res.bodyBytes;
  }

  /// 搜索页「Discover something new」：browse 页里的 WatchFeed 区块；没有返回 null。
  Future<WatchFeedShelf?> fetchBrowseShelf({String? timezone}) async {
    final body = await _get('browsita/v1/browse', {'timezone': ?timezone});
    return body == null ? null : WatchFeedParser.parseBrowseShelf(body);
  }

  /// 以曲目为种子的入口卡片（「Explore 某艺人」）；服务端无内容时返回 null。
  Future<WatchFeedShelf?> fetchSeedShelf({
    required String trackUri,
    required String creatorUri,
    String contextUri = '',
  }) async {
    final body = await _get('watch-feed-entrypoints/v1/discovery-from-seed', {
      'entityUri': trackUri,
      'creatorUri': creatorUri,
      'contextUri': contextUri,
      'isTablet': 'false',
    });
    return body == null ? null : WatchFeedParser.parseSeedShelf(body);
  }

  /// 拉一页 feed。[feedUri] 为 `spotify:watch-feed:…`；[pageToken] 为上一页的 nextPageToken。
  Future<WatchFeedPage> fetchFeed(
    String feedUri, {
    Uint8List? pageToken,
  }) async {
    final spec = WatchFeedRequestSpec.fromUri(feedUri);
    if (spec == null) throw WatchFeedException('无法识别的 feed：$feedUri');
    final res = await _client.post(
      _uri('watch-feed-view/v1/feed'),
      headers: await _protoHeaders(),
      body: encodeRequest(spec, pageToken: pageToken),
    );
    if (res.statusCode != 200) {
      throw WatchFeedException('请求失败', res.statusCode);
    }
    return WatchFeedParser.parseFeed(res.bodyBytes);
  }

  /// WatchFeedRequest{1 feed_id, 2 entity_id, 99 map parameters, 101 pagination{1 token}}。
  static Uint8List encodeRequest(
    WatchFeedRequestSpec spec, {
    Uint8List? pageToken,
  }) {
    final writer = ProtoWriter()..string(1, spec.feedId);
    final entity = spec.entityId;
    if (entity != null && entity.isNotEmpty) writer.string(2, entity);
    for (final e in spec.parameters.entries) {
      writer.message(
        99,
        ProtoWriter()
          ..string(1, e.key)
          ..string(2, e.value),
      );
    }
    if (pageToken != null && pageToken.isNotEmpty) {
      writer.message(101, ProtoWriter()..bytes(1, pageToken));
    }
    return writer.toBytes();
  }
}
