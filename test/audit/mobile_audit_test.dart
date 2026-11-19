import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/auth/login_screen.dart';
import 'package:flutify_app/ui/screens/home/home_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/settings/settings_screen.dart';
import 'package:flutify_app/ui/widgets/mini_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_library_source.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_catalog.dart';

/// 手机竖屏离屏渲染审查（不在屏幕上打开任何窗口）。
///
/// 默认跳过；需要时运行：
///   $env:FLUTIFY_AUDIT='1'; flutter test --update-goldens test/audit
/// 截图输出到 build/audit/（390×844，iPhone 14 尺寸，深浅色各一套），供人工检查布局。
void main() {
  final enabled = Platform.environment['FLUTIFY_AUDIT'] == '1';
  const size = Size(390, 844);
  const tracks = [SampleCatalog.track1, SampleCatalog.track2, SampleCatalog.track3, SampleCatalog.track4];

  /// 加载真实字体（MiSans + Material Icons），否则测试环境用方块字体渲染。
  Future<void> loadFonts() async {
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
    for (final family in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(family['family'] as String);
      for (final font in (family['fonts'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
  }

  /// 图片缓存会查询缓存目录：指向项目 build/ 下，避免 MissingPluginException。
  setUpAll(() {
    final cacheDir = Directory('build/audit_cache')..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cacheDir.absolute.path,
    );
  });

  Future<void> settle(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../../build/audit/$name.png'));
  }

  for (final brightness in Brightness.values) {
    final suffix = brightness.name;

    testWidgets('audit $suffix', skip: !enabled, (tester) async {
      await tester.runAsync(loadFonts);
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      tester.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      ArtworkPalette.enabled = false;

      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final library = FakeLibrarySource(
        likedTracks: tracks,
        playlists: const [SampleCatalog.remotePlaylist],
        albums: const [SampleCatalog.albumA],
        artists: const [SampleCatalog.artistA, SampleCatalog.artistB],
      );
      await tester.pumpWidget(FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(storage.auth,
          librarySource: library,
          lyricsById: {
            SampleCatalog.track1.id: const SpotifyLyrics(lines: [
              LyricLine(startTimeMs: 0, words: '夜空中最亮的星'),
              LyricLine(startTimeMs: 4000, words: '能否听清那仰望的人心底的孤独和叹息'),
              LyricLine(startTimeMs: 8000, words: 'Every night in my dreams I see you'),
              LyricLine(startTimeMs: 12000, words: '我祈祷拥有一颗透明的心灵'),
            ]),
          },
          albumTracks: {SampleCatalog.albumA.id: tracks},
        ),
        trackAudioLoader: FakeTrackAudioSource(),
      ));
      await settle(tester);
      await shot(tester, '${suffix}_01_home_empty');

      final playback = Provider.of<PlaybackProvider>(tester.element(find.byType(MainShell)), listen: false);
      await playback.playTrack(
        tracks.first,
        contextQueue: tracks,
        context: const PlaybackContext.playlist('Synthetic Mix', uri: 'spotify:playlist:synthetic'),
      );
      await settle(tester);
      await shot(tester, '${suffix}_02_home_playing');

      await tester.tap(find.text('搜索').last);
      await settle(tester);
      await shot(tester, '${suffix}_03_search');

      await tester.tap(find.text('音乐库').last);
      await settle(tester);
      await shot(tester, '${suffix}_04_library');

      await tester.tap(find.text('主页').last);
      await settle(tester);
      final home = tester.element(find.byType(HomeScreen));
      AppRoutes.openAlbum(home, SampleCatalog.albumA);
      await settle(tester);
      await shot(tester, '${suffix}_05_album');
      AppRoutes.openArtist(home, SampleCatalog.artistA);
      await settle(tester);
      await shot(tester, '${suffix}_06_artist');
      AppRoutes.openPlaylist(home, SampleCatalog.remotePlaylist);
      await settle(tester);
      await shot(tester, '${suffix}_07_playlist');

      // 全屏播放器：封面 / 歌词 / 队列
      await tester.tap(find.byType(MiniPlayer));
      await settle(tester);
      await shot(tester, '${suffix}_08_player');
      await tester.tap(find.byTooltip('歌词'));
      await settle(tester);
      await shot(tester, '${suffix}_09_player_lyrics');
      await tester.tap(find.byTooltip('全屏歌词'));
      await settle(tester);
      await shot(tester, '${suffix}_10_lyrics_sheet');
      await tester.tap(find.byTooltip('关闭').last);
      await settle(tester);
      await tester.tap(find.byTooltip('播放队列'));
      await settle(tester);
      await shot(tester, '${suffix}_11_player_queue');
      await tester.tap(find.byTooltip('关闭').first);
      await settle(tester);

      final root = Navigator.of(tester.element(find.byType(MainShell)), rootNavigator: true);
      root.push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      await settle(tester);
      await shot(tester, '${suffix}_12_settings_top');
      await tester.drag(find.byType(ListView).last, const Offset(0, -700));
      await settle(tester);
      await shot(tester, '${suffix}_13_settings_bottom');
      root.pop();
      await settle(tester);

      LoginScreen.open(tester.element(find.byType(MainShell)));
      await settle(tester);
      await shot(tester, '${suffix}_14_login');

      // 收尾：卸载界面并跑完防抖 / 缓存等剩余计时器
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
  }

  // 桌面：右栏液态歌词 + 沉浸式全屏歌词（1440×900）
  testWidgets('audit desktop lyrics', skip: !enabled, (tester) async {
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(FlutifyApp(
      storageService: storage,
      audioEngine: FakeAudioPlayerService(),
      emePlayer: EmePlayer(),
      spotifyApiService: FakeSpotifyApiService(storage.auth, lyricsById: {
        SampleCatalog.track1.id: const SpotifyLyrics(lines: [
          LyricLine(startTimeMs: 0, words: '夜空中最亮的星'),
          LyricLine(startTimeMs: 4000, words: '能否听清那仰望的人心底的孤独和叹息'),
          LyricLine(startTimeMs: 8000, words: 'Every night in my dreams I see you'),
          LyricLine(startTimeMs: 12000, words: '我祈祷拥有一颗透明的心灵'),
        ]),
      }),
      trackAudioLoader: FakeTrackAudioSource(),
    ));
    await settle(tester);
    final playback = Provider.of<PlaybackProvider>(tester.element(find.byType(MainShell)), listen: false);
    await playback.playTrack(
      tracks.first,
      contextQueue: tracks,
      context: const PlaybackContext.playlist('Synthetic Mix', uri: 'spotify:playlist:synthetic'),
    );
    await settle(tester);

    await tester.tap(find.byTooltip('歌词').first);
    await settle(tester);
    await shot(tester, 'desktop_01_panel_lyrics');

    await tester.tap(find.byTooltip('沉浸式歌词').first);
    await settle(tester);
    await shot(tester, 'desktop_02_immersive');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });

  // 桌面设置页：嵌在内容区。宽窗口双栏、较窄窗口单列横向行
  for (final (name, windowSize) in const [('wide', Size(1440, 900)), ('narrow', Size(1000, 760))]) {
    testWidgets('audit desktop settings $name', skip: !enabled, (tester) async {
      await tester.runAsync(loadFonts);
      tester.view.physicalSize = windowSize;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      ArtworkPalette.enabled = false;

      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await tester.pumpWidget(FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(storage.auth),
        trackAudioLoader: FakeTrackAudioSource(),
      ));
      await settle(tester);
      await tester.tap(find.byTooltip('账号'));
      await settle(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await shot(tester, 'desktop_settings_$name');
      await tester.drag(find.byType(SettingsScreen), const Offset(0, -600));
      await settle(tester);
      await shot(tester, 'desktop_settings_${name}_bottom');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
  }
}
