import 'dart:typed_data';

import 'package:flutify_app/models/watch_feed.dart';
import 'package:flutify_app/services/watchfeed/proto_tree.dart';
import 'package:flutify_app/services/watchfeed/watch_feed_parser.dart';
import 'package:flutify_app/services/watchfeed/watch_feed_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'watch_feed_fixtures.dart';

void main() {
  group('feed 解析', () {
    final page = WatchFeedParser.parseFeed(
      feedResponse(
        items: [
          canvasItem('t1', name: 'Fourth of July'),
          previewItem('t2'),
        ],
        associated: [
          'spotify:watch-feed:discovery-feed:A?isAssociatedFeed=true',
          'not-a-feed',
        ],
        nextToken: [8, 5, 24, 5],
      ),
    );

    test('头部标题、引导、关联 feed 与下一页令牌', () {
      expect(page.headerTitles, ['Similar to Song', '#folk']);
      expect(page.verticalOnboardingText, 'Swipe up to see more');
      expect(page.associatedOnboardingText, 'Swipe for more feeds');
      expect(page.associatedFeedUris, [
        'spotify:watch-feed:discovery-feed:A?isAssociatedFeed=true',
      ], reason: '非 watch-feed 地址被丢弃');
      expect(page.nextPageToken, [8, 5, 24, 5]);
    });

    test('不认识的布局被跳过，只留两条', () {
      expect(page.items, hasLength(2));
    });

    test('Canvas 条目：视频、试听（cdn_url + file_id、循环、淡入）与叠加组件', () {
      final item = page.items.first;
      expect(item.uri, 'spotify:track:t1');
      expect(item.visual.kind, WatchFeedVisualKind.canvas);
      expect(item.visual.videoUrl, 'https://canvaz.scdn.co/t1.mp4');
      expect(item.visual.imageUrl, 'https://i.scdn.co/thumb-t1');
      expect(item.audio?.url, 'https://p.scdn.co/mp3-preview/at1');
      expect(item.audio?.shouldLoop, isTrue);
      expect(item.audio?.fadeIn, isTrue);
      expect(item.creator?.name, 'Artist One');
      expect(item.creator?.subtitle, '2.8M followers');
      expect(item.creator?.imageUrl, 'https://i.scdn.co/artist');
      expect(item.creator?.followText, 'Follow');
      expect(item.creator?.artistId, 'art1');
      expect(item.hashtags.map((h) => h.title), ['#chamber pop', '#sad']);
      expect(
        item.hashtags.first.navigationUri,
        startsWith('spotify:watch-feed:discovery-feed:h1'),
      );
      expect(item.entityRow?.title, 'Fourth of July');
      expect(item.entityRow?.playUri, 'spotify:track:t1');
      expect(item.canShare && item.hasMenu && item.canSave, isTrue);
      expect(item.hasProgressBar, isTrue);
    });

    test('曲目菜单组件还原出完整曲目（保存 / 播放用）', () {
      final track = page.items.first.playableTrack!;
      expect(track.id, 't1');
      expect(track.name, 'Fourth of July');
      expect(track.artistNames, 'Artist One');
      expect(track.album?.name, 'Album One');
      expect(track.coverUrl, 'https://i.scdn.co/album');
    });

    test('无视频条目：封面 + 波形，没有菜单时由曲目行拼出最小曲目', () {
      final item = page.items[1];
      expect(item.visual.kind, WatchFeedVisualKind.trackPreview);
      expect(item.visual.imageUrl, 'https://i.scdn.co/album-t2');
      expect(item.visual.animationUrl, isNotEmpty);
      expect(item.audio?.fadeIn, isFalse);
      expect(item.hashtags.single.title, '#autumn');
      expect(item.hasMenu, isFalse);
      final track = item.playableTrack!;
      expect(track.uri, 'spotify:track:t2');
      expect(track.name, 'Preview');
    });

    test('没有下一页令牌时为 null', () {
      final last = WatchFeedParser.parseFeed(
        feedResponse(items: [previewItem('x')]),
      );
      expect(last.nextPageToken, isNull);
    });
  });

  test('搜索页 browse：取第一个 WatchFeed 区块', () {
    final shelf = WatchFeedParser.parseBrowseShelf(browseResponse())!;
    expect(shelf.title, 'Discover something new');
    expect(shelf.entries.map((e) => e.title), [
      'Music for you',
      '#mellow indie',
    ]);
    final first = shelf.entries.first;
    expect(first.feedUri, contains('firstItemUris='));
    expect(first.firstItemUri, 'spotify:track:first-feedA');
    expect(first.videoUrl, 'https://canvaz.scdn.co/feedA.mp4');
    expect(first.imageUrl, 'https://i.scdn.co/thumb-feedA');
    expect(first.accessibilityText, 'Explore Music for you');
  });

  test('discovery-from-seed：卡片行', () {
    final shelf = WatchFeedParser.parseSeedShelf(seedResponse())!;
    expect(shelf.title, 'Explore Artist One');
    expect(shelf.entries.map((e) => e.title), [
      'Songs by Artist One',
      'Similar to Artist One',
    ]);
    expect(shelf.entries.last.videoUrl, 'https://canvaz.scdn.co/seed-s2.mp4');
  });

  test('损坏或空的字节不抛错', () {
    final broken = Uint8List.fromList([0x0a, 0x7f, 0x01, 0x02]);
    expect(WatchFeedParser.parseFeed(broken).items, isEmpty);
    expect(WatchFeedParser.parseBrowseShelf(broken), isNull);
    expect(WatchFeedParser.parseSeedShelf(Uint8List(0)), isNull);
    expect(ProtoMsg.parse(broken).str(1), isEmpty);
  });

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
