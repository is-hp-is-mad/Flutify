import 'dart:convert';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/detail/podcast_detail_screen.dart';
import 'package:flutify_app/ui/screens/home/home_screen.dart';
import 'package:flutify_app/ui/screens/home/home_section_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_home.dart';

/// 主页（填满真实结构的合成数据）：
/// - 布局兜底：手机 → 桌面共 15 个宽度 × 默认 / 最大字号，滚到底、选中二级标签，任何溢出即失败；
/// - 行为：快捷入口、推荐理由、「显示全部」只在有更多条目时出现并能打开、播客点按给出提示。
void main() {
  const widths = <double>[
    320,
    360,
    390,
    414,
    480,
    520,
    600,
    700,
    799,
    800,
    900,
    1024,
    1100,
    1280,
    1440,
  ];

  Future<StorageService> storageWith(double fontScale) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await storage.preferences.setAppearanceJson(
      jsonEncode(
        AppearanceSettings.defaults.copyWith(fontScale: fontScale).toJson(),
      ),
    );
    return storage;
  }

  Future<void> pumpHome(
    WidgetTester tester,
    StorageService storage,
    Size size, {
    Key? key,
  }) async {
    tester.view.physicalSize = size;
    await tester.pumpWidget(
      FlutifyApp(
        key: key,
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(storage.auth,
          homeFeed: SampleHome.feed,
        ),
        trackAudioLoader: FakeTrackAudioSource(),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder homeScroll() => find
      .descendant(
        of: find.byType(HomeScreen),
        matching: find.byType(CustomScrollView),
      )
      .first;

  for (final fontScale in const [1.0, AppearanceSettings.maxFontScale]) {
    testWidgets(
      'home: no overflow across widths (font ${(fontScale * 100).round()}%)',
      (tester) async {
        ArtworkPalette.enabled = false;
        addTearDown(tester.view.reset);
        tester.view.devicePixelRatio = 1;
        final storage = await storageWith(fontScale);

        for (final width in widths) {
          await pumpHome(
            tester,
            storage,
            Size(width, 1400),
            key: ValueKey(width),
          );
          expect(find.byType(HomeScreen), findsOneWidget, reason: '宽度 $width');

          // 逐屏滚到底：卡架、推荐流网格、推荐流之后的卡架都要真正布局一次
          for (var i = 0; i < 6; i++) {
            await tester.drag(homeScroll(), const Offset(0, -900));
            await tester.pump(const Duration(milliseconds: 100));
          }

          // 选中二级标签：标签栏变为「× + 一级 + 二级」
          Provider.of<SpotifyProvider>(
            tester.element(find.byType(MainShell)),
            listen: false,
          ).selectHomeFacet('sub-2');
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          debugPrint('home sweep ok: width=$width fontScale=$fontScale');
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
      },
    );
  }

  group('home behaviour', () {
    setUp(() => ArtworkPalette.enabled = false);

    testWidgets('shortcuts, feed reasons and show-all', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      await pumpHome(tester, await storageWith(1.0), const Size(1280, 2400));

      // 快捷入口 8 个（含已点赞的歌曲）；「显示全部」只出现在条目多于已显示数量的分区
      expect(find.text('已点赞的歌曲'), findsWidgets);
      expect(find.text('显示全部'), findsOneWidget);
      expect(find.text('最近播放'), findsOneWidget);

      for (var i = 0; i < 3; i++) {
        await tester.drag(homeScroll(), const Offset(0, -900));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('为你推荐'), findsWidgets);

      for (var i = 0; i < 6; i++) {
        await tester.drag(homeScroll(), const Offset(0, 900));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('显示全部'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(HomeSectionScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('tapping a podcast opens the show page', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      await pumpHome(tester, await storageWith(1.0), const Size(1280, 2400));

      await tester.tap(find.text('Podcast 0'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 播客节目页已支持：进入详情页（测试环境无网络，随后显示加载失败占位）
      expect(find.byType(PodcastDetailScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
  });
}
