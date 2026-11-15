import 'dart:convert';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/services/watchfeed/watch_feed_parser.dart';
import 'package:flutify_app/ui/screens/detail/album_detail_screen.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/ui/screens/watchfeed/desktop/desktop_watch_feed.dart';
import 'package:flutify_app/ui/screens/watchfeed/widgets/watch_feed_entity_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import 'watch_feed_fixtures.dart';
import 'watch_feed_screen_test.dart' show FakePreviewPlayer;

/// Pathfinder watchFeedEntity 响应里的一条（无 Canvas，避免测试里创建 WebView）。
Map<String, dynamic> entityTrack(
  int i, {
  List<String> tags = const ['sad'],
  bool fallbackColor = false,
}) => {
  '__typename': 'TrackResponseWrapper',
  'data': {
    '__typename': 'Track',
    'uri': 'spotify:track:tr$i',
    'name': 'Song $i',
    'albumOfTrack': {
      'name': 'Album $i',
      'uri': 'spotify:album:al$i',
      'coverArt': {
        'extractedColors': {
          'colorDark': {'hex': '#303840', 'isFallback': fallbackColor},
        },
        'sources': [
          {'url': 'https://i.scdn.co/cover$i', 'width': 640, 'height': 640},
        ],
      },
    },
    'artists': {
      'items': [
        {
          'uri': 'spotify:artist:ar1',
          'profile': {'name': 'Artist One'},
          'stats': {'monthlyListeners': 15852288},
          'visuals': {
            'avatarImage': {
              'sources': [
                {
                  'url': 'https://i.scdn.co/avatar',
                  'width': 160,
                  'height': 160,
                },
              ],
            },
          },
        },
      ],
    },
    'canvas': null,
    'contentRating': {'label': 'NONE'},
    'discoveryFeedHashtags': [
      for (final t in tags)
        {'title': t, 'uri': 'spotify:watch-feed:discovery-feed:tag$t'},
    ],
    'previews': {
      'audioPreviews': {
        'items': [
          {'url': 'https://p.scdn.co/mp3-preview/p$i'},
        ],
      },
    },
  },
};

/// [mixed] 时第 3 条起每隔一条没有服务端封面色（线上实际如此），并带三个 #标签，
/// 用来复现背景结构切换导致的轮播复位与标签排布问题。
Map<String, dynamic> entityResponse(int count, {bool mixed = false}) => {
  'data': {
    'getWatchFeedForEntity': {
      'items': [
        for (var i = 1; i <= count; i++)
          mixed
              ? entityTrack(
                  i,
                  tags: const ['sad', 'indie folk', 'late night'],
                  fallbackColor: i >= 3 && i.isOdd,
                )
              : entityTrack(i),
      ],
      'totalCount': count,
      'pagingInfo': {'nextOffset': null},
    },
  },
};

void main() {
  setUp(() => ArtworkPalette.enabled = false);
  tearDown(() => ArtworkPalette.enabled = true);

  test('实体 feed 解析：试听、#标签补 #、月度听众、封面深色、专辑', () {
    final page = WatchFeedParser.parseEntityFeed(
      entityResponse(2)['data'] as Map<String, dynamic>,
    );
    expect(page.items, hasLength(2));
    expect(page.nextOffset, isNull);
    final item = page.items.first;
    expect(item.audio?.url, 'https://p.scdn.co/mp3-preview/p1');
    expect(item.hashtags.single.title, '#sad');
    expect(
      item.hashtags.single.navigationUri,
      'spotify:watch-feed:discovery-feed:tagsad',
    );
    expect(item.creator?.monthlyListeners, 15852288);
    expect(item.backgroundColor, 0xFF303840);
    expect(item.track?.album?.id, 'al1');
    expect(item.track?.artists.single.name, 'Artist One');
  });

  Future<({FakePreviewPlayer player, List<String> requests})> pump(
    WidgetTester tester, {
    bool mixed = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sp_access_token': 'token'});
    final storage = await StorageService.init();
    final requests = <String>[];
    final api = SpotifyApiService(
      storage,
      MockClient((request) async {
        requests.add(request.url.toString());
        if (request.url.host == 'api-partner.spotify.com') {
          return http.Response(
            jsonEncode(entityResponse(mixed ? 8 : 3, mixed: mixed)),
            200,
          );
        }
        if (request.url.path.endsWith('/watch-feed-view/v1/feed')) {
          return http.Response.bytes(
            feedResponse(
              items: [previewItem('n1', name: 'Tag Song', withAlbum: true)],
            ),
            200,
          );
        }
        return http.Response('{"items":[]}', 200);
      }),
    );
    final audio = FakeAudioPlayerService();
    final playback = PlaybackProvider(audio, storage);
    final library = LibraryProvider(storage);
    final player = FakePreviewPlayer();
    addTearDown(() {
      playback.dispose();
      library.dispose();
      player.dispose();
      audio.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SpotifyApiService>.value(value: api),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: library),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: AppLocale.delegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      opaque: false,
                      pageBuilder: (_, _, _) => DesktopWatchFeed(
                        feedUri: 'spotify:watch-feed:artist:ar1',
                        title: 'Artist One',
                        opener: context,
                        player: player,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    return (player: player, requests: requests);
  }

  testWidgets('三栏：feed 标题、歌名、艺人行、#标签与右侧按钮；播放首条试听', (tester) async {
    final env = await pump(tester);
    expect(find.text('Artist One'), findsWidgets);
    expect(find.text('Song 1'), findsOneWidget);
    expect(find.text('#sad'), findsOneWidget);
    expect(find.textContaining('monthly listeners'), findsOneWidget);
    expect(find.byKey(const Key('desktop-watch-feed-close')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-watch-feed-next-pill')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('desktop-watch-feed-previous')), findsNothing);
    expect(env.player.played, ['https://p.scdn.co/mp3-preview/p1']);
    expect(
      env.requests.where((u) => u.contains('api-partner')),
      hasLength(1),
      reason: '实体 feed 走 Pathfinder',
    );
  });

  testWidgets('↓ 下一首：换歌、换试听，胶囊变成小箭头，出现上一首', (tester) async {
    final env = await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(find.text('Song 2'), findsOneWidget);
    expect(env.player.played.last, 'https://p.scdn.co/mp3-preview/p2');
    expect(find.byKey(const Key('desktop-watch-feed-next-pill')), findsNothing);
    expect(find.byKey(const Key('desktop-watch-feed-next')), findsOneWidget);
    expect(
      find.byKey(const Key('desktop-watch-feed-previous')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('desktop-watch-feed-previous')));
    await settle(tester);
    expect(find.text('Song 1'), findsOneWidget);
  });

  testWidgets('连续往下翻：轮播停在对应条目，不会跳回第一首', (tester) async {
    await pump(tester, mixed: true);
    for (var i = 2; i <= 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      final pager = tester.widget<PageView>(find.byType(PageView)).controller!;
      expect(pager.page!.round(), i - 1, reason: '第 $i 首时轮播位置');
      expect(find.text('Song $i'), findsOneWidget);
    }
  });

  testWidgets('#标签胶囊按内容宽度排成一行，不铺满整栏', (tester) async {
    await pump(tester, mixed: true);
    final chips = [
      for (final t in ['#sad', '#indie folk', '#late night'])
        tester.getRect(find.text(t)),
    ];
    expect(chips[1].left, greaterThan(chips[0].right), reason: '同一行依次排开');
    expect(chips[2].left, greaterThan(chips[1].right));
    expect(chips[0].top, chips[1].top);
  });

  testWidgets('M 静音、Esc 关闭', (tester) async {
    final env = await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(env.player.muted, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(DesktopWatchFeed), findsNothing);
  });

  testWidgets('点 #标签：本层换成该标签的 feed', (tester) async {
    final env = await pump(tester);
    await tester.tap(find.text('#sad'));
    await settle(tester);
    expect(find.text('Tag Song'), findsOneWidget);
    expect(env.requests.last, contains('watch-feed-view/v1/feed'));
  });

  testWidgets('点歌名：关闭本层，进入专辑并定位到这首', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Song 1'));
    await settle(tester);
    expect(find.byType(DesktopWatchFeed), findsNothing);
    final album = tester.widget<AlbumDetailScreen>(
      find.byType(AlbumDetailScreen),
    );
    expect(album.album.id, 'al1');
    expect(album.focusTrack?.id, 'tr1');
  });

  group('入口按钮', () {
    test('实体 uri → feed uri', () {
      expect(
        WatchFeedEntityButton.feedUriFor('spotify:artist:abc'),
        'spotify:watch-feed:artist:abc',
      );
      expect(WatchFeedEntityButton.feedUriFor('spotify:track:abc'), isNull);
    });

    Future<void> pumpButton(
      WidgetTester tester, {
      required double width,
      required int items,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'sp_access_token': 'token'});
      final storage = await StorageService.init();
      final api = SpotifyApiService(
        storage,
        MockClient((request) async {
          if (request.url.host == 'api-partner.spotify.com') {
            return http.Response(jsonEncode(entityResponse(items)), 200);
          }
          return http.Response('{}', 404);
        }),
      );
      final spotify = SpotifyProvider(api, storage);
      addTearDown(spotify.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: spotify,
          child: MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocale.supportedLocales,
            localizationsDelegates: AppLocale.delegates,
            home: const Scaffold(
              body: Center(
                child: WatchFeedEntityButton(
                  feedUri: 'spotify:watch-feed:artist:ar1',
                  name: 'Artist One',
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('桌面宽度且有内容：显示，提示带实体名', (tester) async {
      await pumpButton(tester, width: 1440, items: 3);
      expect(find.byKey(const Key('watch-feed-entity-button')), findsOneWidget);
      expect(
        find.byTooltip('Explore Artist One in short videos'),
        findsOneWidget,
      );
    });

    testWidgets('没有内容或窄屏：不显示', (tester) async {
      await pumpButton(tester, width: 1440, items: 0);
      expect(find.byKey(const Key('watch-feed-entity-button')), findsNothing);
      await pumpButton(tester, width: 420, items: 3);
      expect(find.byKey(const Key('watch-feed-entity-button')), findsNothing);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
