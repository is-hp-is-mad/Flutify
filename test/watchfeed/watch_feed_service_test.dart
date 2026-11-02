import 'package:flutify_app/services/watchfeed/proto_tree.dart';
import 'package:flutify_app/services/watchfeed/watch_feed_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'watch_feed_fixtures.dart';

/// 会话头（Web 播放器身份）→ 请求时换成 Android 身份；其余鉴权头原样保留。
Future<Map<String, String>> _webSession() async => {
  'Authorization': 'Bearer token',
  'client-token': 'ct',
  'Accept-Language': 'zh-CN',
  'Content-Type': 'application/json',
  'Accept': 'application/json',
  'app-platform': 'WebPlayer',
  'spotify-app-version': '1.2.3',
  'origin': 'https://open.spotify.com',
  'referer': 'https://open.spotify.com/',
};

void main() {
  test('请求头：保留鉴权与语言，平台身份换成 Android、内容类型换成 protobuf', () async {
    late http.Request seen;
    final service = WatchFeedService(
      MockClient((request) async {
        seen = request;
        return http.Response.bytes(
          feedResponse(items: [previewItem('t')]),
          200,
        );
      }),
      headers: _webSession,
    );
    final page = await service.fetchFeed(
      'spotify:watch-feed:discovery-feed:ID?firstItemUris=spotify:track:t',
    );
    expect(page.items, hasLength(1));

    expect(seen.method, 'POST');
    expect(
      seen.url.toString(),
      'https://spclient.wg.spotify.com/watch-feed-view/v1/feed',
    );
    final h = {
      for (final e in seen.headers.entries) e.key.toLowerCase(): e.value,
    };
    expect(h['authorization'], 'Bearer token');
    expect(h['client-token'], 'ct');
    expect(h['accept-language'], 'zh-CN');
    expect(h['app-platform'], 'Android');
    expect(h['spotify-app-version'], WatchFeedService.androidAppVersion);
    expect(h['accept'], 'application/protobuf');
    expect(h['content-type'], startsWith('application/protobuf'));
    expect(h.containsKey('origin'), isFalse);
    expect(h.containsKey('referer'), isFalse);

    final body = ProtoMsg.parse(seen.bodyBytes);
    expect(body.str(1), 'discovery-feed');
    expect(body.str(2), 'ID');
  });

  test('入口：browse 与 discovery-from-seed 的路径、参数；204 视为没有内容', () async {
    final urls = <Uri>[];
    var seedStatus = 200;
    final service = WatchFeedService(
      MockClient((request) async {
        urls.add(request.url);
        if (request.url.path.endsWith('/browse')) {
          return http.Response.bytes(browseResponse(), 200);
        }
        if (seedStatus == 204) return http.Response('', 204);
        return http.Response.bytes(seedResponse(), 200);
      }),
      headers: _webSession,
    );
    final browse = await service.fetchBrowseShelf();
    expect(browse?.entries, hasLength(2));
    expect(urls.last.path, '/browsita/v1/browse');

    final seed = await service.fetchSeedShelf(
      trackUri: 'spotify:track:t',
      creatorUri: 'spotify:artist:a',
    );
    expect(seed?.entries, hasLength(2));
    expect(urls.last.path, '/watch-feed-entrypoints/v1/discovery-from-seed');
    expect(urls.last.queryParameters, {
      'entityUri': 'spotify:track:t',
      'creatorUri': 'spotify:artist:a',
      'contextUri': '',
      'isTablet': 'false',
    });

    seedStatus = 204;
    expect(
      await service.fetchSeedShelf(
        trackUri: 'spotify:track:t',
        creatorUri: 'spotify:artist:a',
      ),
      isNull,
    );
  });

  test('失败与未登录抛 WatchFeedException', () async {
    final failing = WatchFeedService(
      MockClient((_) async => http.Response('', 503)),
      headers: _webSession,
    );
    await expectLater(
      failing.fetchFeed('spotify:watch-feed:tab-feed'),
      throwsA(
        isA<WatchFeedException>().having((e) => e.statusCode, 'status', 503),
      ),
    );
    await expectLater(
      failing.fetchFeed('spotify:track:x'),
      throwsA(isA<WatchFeedException>()),
    );

    final signedOut = WatchFeedService(
      MockClient((_) async => http.Response('', 200)),
      headers: () async => {'Accept': 'application/json'},
    );
    await expectLater(
      signedOut.fetchBrowseShelf(),
      throwsA(isA<WatchFeedException>()),
    );
  });
}
