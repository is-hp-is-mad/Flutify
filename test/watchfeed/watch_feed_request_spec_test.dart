import 'dart:typed_data';

import 'package:flutify_app/services/watchfeed/watch_feed_request_spec.dart';
import 'package:flutify_app/services/watchfeed/watch_feed_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/proto_tree.dart';

/// feed 响应解析的用例已移到 Rust：`rust/flutify_core/src/watchfeed_backend_tests.rs`。
void main() {
  group('feed URI → 请求', () {
    test('discovery-feed：id 为 entity，query 进 parameters，/ 还原为 :', () {
      final spec = WatchFeedRequestSpec.fromUri(
        'spotify:watch-feed:discovery-feed:37i9dQZF1F?firstItemUris=spotify%3Atrack%3Aabc'
        '&seedItemUri=spotify/track/xyz&presentAsOverlay=true',
      )!;
      expect(spec.feedId, 'discovery-feed');
      expect(spec.entityId, '37i9dQZF1F');
      expect(spec.parameters, {
        'firstItemUris': 'spotify:track:abc',
        'seedItemUri': 'spotify:track:xyz',
      }, reason: 'presentAsOverlay 不发送');
    });

    test('无 entity 的 feed 与路径里的键值对', () {
      expect(
        WatchFeedRequestSpec.fromUri('spotify:watch-feed:tab-feed')!.entityId,
        isNull,
      );
      final spec = WatchFeedRequestSpec.fromUri(
        'spotify:watch-feed:related-clips:k1:v1',
      )!;
      expect(spec.feedId, 'related-clips');
      expect(spec.entityId, isNull);
      expect(spec.parameters, {'k1': 'v1'});
      expect(WatchFeedRequestSpec.fromUri('spotify:track:x'), isNull);
    });

    test('编码请求：feed_id / entity_id / parameters / 分页令牌', () {
      final spec = WatchFeedRequestSpec.fromUri(
        'spotify:watch-feed:discovery-feed:ID?a=b',
      )!;
      final bytes = WatchFeedService.encodeRequest(
        spec,
        pageToken: Uint8List.fromList([8, 5]),
      );
      final msg = ProtoMsg.parse(bytes);
      expect(msg.str(1), 'discovery-feed');
      expect(msg.str(2), 'ID');
      expect(msg.msgs(99).map((e) => '${e.str(1)}=${e.str(2)}'), ['a=b']);
      expect(msg.msg(101).bytes(1), [8, 5]);
      expect(
        ProtoMsg.parse(WatchFeedService.encodeRequest(spec)).has(101),
        isFalse,
        reason: '首页不带令牌',
      );
    });
  });
}
