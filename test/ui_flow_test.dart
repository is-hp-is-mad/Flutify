import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/core/utils/error_placeholder.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_hero.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_backdrop.dart';
import 'package:flutify_app/ui/screens/player/queue_list.dart';
import 'package:flutify_app/ui/shell/desktop/now_playing_details.dart';
import 'package:flutify_app/ui/shell/desktop/now_playing_panel.dart';
import 'package:flutify_app/ui/shell/desktop/panel_lyrics_card.dart';
import 'package:flutify_app/ui/shell/shell_layout_controller.dart';
import 'package:flutify_app/ui/widgets/filter_pill.dart';
import 'package:flutify_app/ui/widgets/apple_music_background.dart';
import 'package:flutify_app/ui/widgets/liquid_glass.dart';
import 'package:flutify_app/ui/widgets/mini_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_library_source.dart';
import 'fakes/fake_spotify_api_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

/// 关键交互流程的冒烟测试：布局溢出、断言失败等都会让测试失败。
void main() {
  const mixTracks = [
    SampleCatalog.track1,
    SampleCatalog.track2,
    SampleCatalog.track3,
    SampleCatalog.track4,
  ];
  const mixContext = PlaybackContext.playlist(
    'Synthetic Mix',
    uri: 'spotify:playlist:synthetic',
  );

  /// [library] / [lyrics] / [albumTracks] 注入合成数据；音频加载一律成功（不走网络）。
  Future<void> pumpApp(
    WidgetTester tester,
    Size size, {
    FakeLibrarySource? library,
    Map<String, SpotifyLyrics> lyrics = const {},
    Map<String, List<SpotifyTrack>> albumTracks = const {},
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(
          storage,
          librarySource: library,
          lyricsById: lyrics,
          albumTracks: albumTracks,
        ),
        trackAudioLoader: FakeTrackAudioSource(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> playMix(WidgetTester tester) async {
    final playback = Provider.of<PlaybackProvider>(
      tester.element(find.byType(MainShell)),
      listen: false,
    );
    await playback.playTrack(
      mixTracks.first,
      contextQueue: mixTracks,
      context: mixContext,
    );
    await settle(tester);
  }

  testWidgets('mobile: full player, inline lyrics and queue', (tester) async {
    await pumpApp(
      tester,
      const Size(400, 860),
      lyrics: {
        SampleCatalog.track1.id: const SpotifyLyrics(
          lines: [
            LyricLine(startTimeMs: 0, words: 'First synthetic line'),
            LyricLine(startTimeMs: 4000, words: 'Second synthetic line'),
            LyricLine(startTimeMs: 8000, words: 'Third synthetic line'),
          ],
        ),
      },
    );
    await playMix(tester);

    await tester.tap(find.byType(MiniPlayer));
    await settle(tester);
    expect(find.text('正在播放歌单'), findsOneWidget);
    expect(find.text('Synthetic Mix'), findsWidgets);

    // 播放器内嵌歌词
    await tester.tap(find.byTooltip('歌词'));
    await settle(tester);
    expect(find.text('First synthetic line'), findsOneWidget);
    // 手机只保留内嵌歌词：流动背景和玻璃控制区，不再重复打开全屏面板。
    expect(find.byType(LyricsBackdrop), findsOneWidget);
    // Playback controls plus the source-translation toolbar button.
    expect(find.byType(LiquidGlass), findsNWidgets(2));
    expect(find.byIcon(Icons.translate_rounded), findsOneWidget);
    expect(find.byTooltip('全屏歌词'), findsNothing);
    // Android now uses the native micro-bitmap background and Apple's
    // line-synced opacity/scale treatment, not distance-based text blur.
    expect(find.byType(AppleMusicBackground), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
    // 0:00 时当前行保持清晰。
    final firstLine = find.text('First synthetic line');
    expect(
      find.ancestor(
        of: firstLine,
        matching: find.byWidgetPredicate(
          (w) => w is ImageFiltered && w.enabled,
        ),
      ),
      findsNothing,
    );

    await tester.tap(find.byTooltip('播放队列'));
    await settle(tester);
    expect(find.text('接下来播放：Synthetic Mix'), findsOneWidget);
  });

  testWidgets('mobile: album page stays under the mini player', (tester) async {
    await pumpApp(
      tester,
      const Size(400, 860),
      library: FakeLibrarySource(albums: [SampleCatalog.albumA]),
      albumTracks: {
        SampleCatalog.albumA.id: [SampleCatalog.track1, SampleCatalog.track2],
      },
    );
    await playMix(tester);

    // 主页只展示服务端的推荐分区；媒体库中的专辑从「音乐库」进入
    await tester.tap(find.text('音乐库').last);
    await settle(tester);
    await tester.tap(find.text('Album A').first);
    await settle(tester);

    expect(find.byType(CollectionHero), findsOneWidget);
    expect(find.textContaining('2 首歌曲'), findsWidgets);
    // 详情页压入 Tab 内部的 Navigator，迷你播放器依旧可见
    expect(find.text('Track Two'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
  });

  testWidgets(
    'build errors render a quiet placeholder instead of the red screen',
    (tester) async {
      // 测试框架要求在测试体结束前恢复 ErrorWidget.builder（tearDown 太晚）
      final previous = ErrorWidget.builder;
      installErrorPlaceholder();
      try {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: _Throws())),
        );
        expect(tester.takeException(), isA<StateError>());
        expect(find.byIcon(Icons.hide_image_outlined), findsOneWidget);
      } finally {
        ErrorWidget.builder = previous;
      }
    },
  );

  testWidgets('desktop: three-column shell panels', (tester) async {
    await pumpApp(tester, const Size(1280, 800));

    // 未登录：音乐库左栏只显示登录引导，不展示任何示例内容
    expect(find.text('登录后查看你的音乐库'), findsOneWidget);

    // 收起 / 展开音乐库
    await tester.tap(find.byTooltip('收起音乐库'));
    await settle(tester);
    expect(find.byTooltip('展开音乐库'), findsOneWidget);
    expect(find.text('登录后查看你的音乐库'), findsNothing);
    await tester.tap(find.byTooltip('展开音乐库'));
    await settle(tester);
    expect(find.byTooltip('收起音乐库'), findsOneWidget);

    // ≥ 1280：右栏默认停靠在「正在播放」，没有标签切换；播放栏队列键切到独立的「播放队列」面板，再隐藏
    expect(find.byType(NowPlayingPanel), findsOneWidget);
    expect(find.widgetWithText(FilterPill, '播放队列'), findsNothing);
    // 无曲目时播放栏只有占位，直接调用队列键对应的操作
    tester
        .element(find.byType(NowPlayingPanel))
        .read<ShellLayoutController>()
        .togglePanel(RightPanel.queue);
    await settle(tester);
    expect(find.text('播放队列'), findsWidgets, reason: '面板标题随之切换');
    expect(find.byType(QueueList), findsOneWidget);
    await tester.tap(find.byTooltip('隐藏'));
    await settle(tester);
    expect(find.byType(NowPlayingPanel), findsNothing);
  });

  testWidgets(
    'desktop: now-playing panel embeds lyrics that expand to fill the panel',
    (tester) async {
      await pumpApp(
        tester,
        const Size(1440, 900),
        lyrics: {
          SampleCatalog.track1.id: const SpotifyLyrics(
            lines: [
              LyricLine(startTimeMs: 0, words: 'First synthetic line'),
              LyricLine(startTimeMs: 4000, words: 'Second synthetic line'),
            ],
          ),
        },
      );
      await playMix(tester);

      // 内嵌：歌词卡与「关于艺人」同在详情列表里
      expect(find.byType(NowPlayingDetails), findsOneWidget);
      expect(find.byType(PanelLyricsCard), findsOneWidget);
      expect(find.text('First synthetic line'), findsOneWidget);

      // 放大：歌词卡撑满面板，详情列表让位；再点收起回到详情
      await tester.tap(find.byTooltip('放大歌词'));
      await settle(tester);
      expect(find.byType(NowPlayingDetails), findsNothing);
      expect(find.byType(PanelLyricsCard), findsOneWidget);
      expect(find.text('First synthetic line'), findsOneWidget);

      await tester.tap(find.byTooltip('收起歌词'));
      await settle(tester);
      expect(find.byType(NowPlayingDetails), findsOneWidget);

      // 播放栏队列键：切到独立的队列面板；再按一次关闭
      await tester.tap(find.byTooltip('播放队列'));
      await settle(tester);
      expect(find.byType(QueueList), findsOneWidget);
      expect(find.byType(PanelLyricsCard), findsNothing);
      await tester.tap(find.byTooltip('播放队列'));
      await settle(tester);
      expect(find.byType(NowPlayingPanel), findsNothing);
    },
  );

  testWidgets('desktop: narrow window keeps the floating panel closed', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1100, 760));

    // 1100 – 1280：右栏为浮层，启动时不遮挡内容
    expect(find.byType(NowPlayingPanel), findsNothing);
    expect(find.byTooltip('收起音乐库'), findsOneWidget);
  });

  testWidgets('mobile: library filters, sort and grid view', (tester) async {
    await pumpApp(
      tester,
      const Size(400, 860),
      library: FakeLibrarySource(
        likedTracks: [SampleCatalog.track1],
        playlists: [SampleCatalog.remotePlaylist],
        albums: [SampleCatalog.albumA],
        artists: [SampleCatalog.artistA],
      ),
    );

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('音乐库'),
      ),
    );
    await settle(tester);
    expect(find.text('已点赞的歌曲'), findsWidgets);

    // 艺人条目的副标题也是「艺人」，只点筛选药丸
    await tester.tap(find.widgetWithText(FilterPill, '艺人'));
    await settle(tester);
    expect(find.text('Artist A'), findsWidgets);
    expect(find.text('Remote Mix'), findsNothing);

    await tester.tap(find.byTooltip('网格视图'));
    await settle(tester);
    expect(find.byType(GridView), findsOneWidget);

    await tester.tap(find.byTooltip('清除筛选'));
    await settle(tester);
    expect(find.text('Remote Mix'), findsOneWidget);
  });
}

/// 构建时必定抛异常的组件，用于验证全局错误占位。
class _Throws extends StatelessWidget {
  const _Throws();

  @override
  Widget build(BuildContext context) => throw StateError('boom');
}
