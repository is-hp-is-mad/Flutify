import 'dart:convert';

import 'package:flutify_app/services/watchfeed/watch_feed_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/dart_watch_feed_parser.dart';
import 'support/proto_tree.dart';
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
      decoder: const DartWatchFeedDecoder(),
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
      decoder: const DartWatchFeedDecoder(),
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
      decoder: const DartWatchFeedDecoder(),
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
      decoder: const DartWatchFeedDecoder(),
    );
    await expectLater(
      signedOut.fetchBrowseShelf(),
      throwsA(isA<WatchFeedException>()),
    );
  });

  test('discovery-feed 优先走 Web 端 watchFeedView 并携带游标翻页', () async {
    final calls = <Map<String, dynamic>>[];
    final service = WatchFeedService(
      MockClient((req) async {
        expect(req.url.toString(), contains('/pathfinder/v2/query'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        calls.add(body);
        final offset = (body['variables'] as Map)['offset'] as int;
        return http.Response(
          jsonEncode({
            'data': {
              'homeSections': {
                'sections': [
                  {
                    '__typename': 'HomeSection',
                    'data': {
                      '__typename': 'HomeWatchFeedSectionData',
                      'title': {'transformedLabel': '#mandopop'},
                    },
                    'sectionItems': {
                      'pagingInfo': {'nextOffset': offset == 0 ? 40 : 0},
                      'items': [
                        {
                          'content': {
                            '__typename': 'TrackResponseWrapper',
                            'data': {
                              '__typename': 'Track',
                              'uri': offset == 0
                                  ? 'spotify:track:aaa'
                                  : 'spotify:track:bbb',
                              'name': offset == 0 ? 'Song A' : 'Song B',
                              'artists': {
                                'items': [
                                  {
                                    'uri': 'spotify:artist:art1',
                                    'profile': {'name': 'Artist 1'},
                                  },
                                ],
                              },
                              'albumOfTrack': {
                                'uri': 'spotify:album:alb1',
                                'name': 'Album 1',
                                'coverArt': {'sources': []},
                              },
                            },
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            },
          }),
          200,
        );
      }),
      headers: () async => {'Authorization': 'Bearer tok'},
      decoder: const DartWatchFeedDecoder(),
    );

    final page1 = await service.fetchFeed(
      'spotify:watch-feed:discovery-feed:tag1',
    );
    expect(page1.headerTitles, ['#mandopop']);
    expect(page1.items.single.track?.id, 'aaa');
    expect(page1.nextPageToken, isNotNull);

    final page2 = await service.fetchFeed(
      'spotify:watch-feed:discovery-feed:tag1',
      pageToken: page1.nextPageToken,
    );
    expect(page2.items.single.track?.id, 'bbb');
    expect(page2.nextPageToken, isNull);
    expect(calls[0]['operationName'], 'watchFeedView');
    expect((calls[1]['variables'] as Map)['offset'], 40);
    expect(
      (calls[1]['variables'] as Map)['previousItems'],
      ['spotify:track:aaa'],
    );
  });
}
