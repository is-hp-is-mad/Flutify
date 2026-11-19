import 'dart:convert';
import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../models/watch_feed.dart';
import '../../src/rust/api/watchfeed.dart' as rust;
import '../rust_backend_bridge.dart';
import 'watch_feed_service.dart';

/// Watch Feed 响应 → 内存模型。
///
/// 生产环境一律由 Rust（`flutify_core` 的 watchfeed_backend）解析，见 [RustWatchFeedDecoder]；
/// 这层接口只作为测试接缝：单元测试里 Rust 核心不加载，可注入替身。
abstract interface class WatchFeedDecoder {
  /// `watch-feed-view/v1/feed` Protobuf 响应。
  Future<WatchFeedPage> feed(Uint8List bytes);

  /// `browsita/v1/browse` Protobuf 响应 → 第一个 WatchFeed 区块；没有则 null。
  Future<WatchFeedShelf?> browseShelf(Uint8List bytes);

  /// `discovery-from-seed` Protobuf 响应 → 卡片行；没有内容返回 null。
  Future<WatchFeedShelf?> seedShelf(Uint8List bytes);

  /// Pathfinder `watchFeedEntity` 响应的 `data`。
  Future<WatchFeedEntityPage> entityFeed(Map<String, dynamic> data);

  /// Pathfinder `watchFeedView` 响应的 `data`；[previousItems] 写进下一页令牌。
  Future<WatchFeedPage> discoveryFeedView(
    Map<String, dynamic> data, {
    List<String> previousItems = const [],
  });
}

/// 生产实现：交给 Rust 解析。
class RustWatchFeedDecoder implements WatchFeedDecoder {
  const RustWatchFeedDecoder();

  void _ensureReady() {
    if (!RustCore.ready) {
      throw const WatchFeedException('Rust 核心未加载，无法解析 Watch Feed');
    }
  }

  @override
  Future<WatchFeedPage> feed(Uint8List bytes) async {
    _ensureReady();
    return RustBackendBridge.watchFeedPageFromDto(
      await rust.rustParseWatchFeed(bytes: bytes),
    );
  }

  @override
  Future<WatchFeedShelf?> browseShelf(Uint8List bytes) async {
    _ensureReady();
    final dto = await rust.rustParseWatchFeedBrowseShelf(bytes: bytes);
    return dto == null ? null : RustBackendBridge.watchFeedShelfFromDto(dto);
  }

  @override
  Future<WatchFeedShelf?> seedShelf(Uint8List bytes) async {
    _ensureReady();
    final dto = await rust.rustParseWatchFeedSeedShelf(bytes: bytes);
    return dto == null ? null : RustBackendBridge.watchFeedShelfFromDto(dto);
  }

  @override
  Future<WatchFeedEntityPage> entityFeed(Map<String, dynamic> data) async {
    _ensureReady();
    return RustBackendBridge.watchFeedEntityPageFromDto(
      await rust.rustParseWatchFeedEntity(dataJson: jsonEncode(data)),
    );
  }

  @override
  Future<WatchFeedPage> discoveryFeedView(
    Map<String, dynamic> data, {
    List<String> previousItems = const [],
  }) async {
    _ensureReady();
    return RustBackendBridge.watchFeedPageFromDto(
      await rust.rustParseWatchFeedDiscoveryView(
        dataJson: jsonEncode(data),
        previousItems: previousItems,
      ),
    );
  }
}
