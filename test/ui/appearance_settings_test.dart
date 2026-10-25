import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/immersive_lyrics_screen.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_translation_controls.dart';
import 'package:flutify_app/ui/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_catalog.dart';

/// 设置页外观项端到端：点选后主题 / 令牌 / MediaQuery 即时变化并持久化；
/// 以及桌面沉浸式歌词的打开与 Esc 退出。
void main() {
  late StorageService storage;

  Future<void> pumpApp(
    WidgetTester tester,
    Size size, {
    Map<String, SpotifyLyrics> lyrics = const {},
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(storage, lyricsById: lyrics),
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

  BuildContext settingsContext(WidgetTester tester) =>
      tester.element(find.byType(SettingsScreen));

  testWidgets('settings: appearance options apply instantly and persist', (
    tester,
  ) async {
    await pumpApp(tester, const Size(500, 900));
    Navigator.of(
      tester.element(find.byType(MainShell)),
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    await settle(tester);

    // 唯一输入框用于 Connect 设备名，不再展示凭据输入框。
    final scrollable = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byType(TextField),
      500,
      scrollable: scrollable,
    );
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields, hasLength(1));
    expect(fields.single.decoration?.hintText, 'Web Player');

    // 主题模式 → 深色；纯黑背景
    await tester.scrollUntilVisible(
      find.text('深色'),
      -500,
      scrollable: scrollable,
    );
    // 反向滚动按步长停下时目标可能只是「已构建」而仍在视口外，再对齐一次
    await tester.ensureVisible(find.text('深色'));
    await settle(tester);
    await tester.tap(find.text('深色'));
    await settle(tester);
    expect(Theme.of(settingsContext(tester)).brightness, Brightness.dark);
    await tester.tap(find.text('纯黑背景'));
    await settle(tester);
    expect(Theme.of(settingsContext(tester)).colorScheme.surface, Colors.black);

    // 圆角 → 方正
    await tester.scrollUntilVisible(
      find.text('方正'),
      300,
      scrollable: scrollable,
    );
    // 「材质」分区多了一行，按步长滚动可能停在目标只露出一半的位置
    await tester.ensureVisible(find.text('方正'));
    await settle(tester);
    await tester.tap(find.text('方正'));
    await settle(tester);
    expect(settingsContext(tester).tokens.squareCorners, isTrue);

    // 减弱动效 → MediaQuery.disableAnimations
    await tester.scrollUntilVisible(
      find.text('减弱动效'),
      300,
      scrollable: scrollable,
    );
    await tester.tap(find.text('减弱动效'));
    await settle(tester);
    expect(settingsContext(tester).reduceMotion, isTrue);

    // 修改已写入存储（防抖 300ms）
    await tester.pump(const Duration(milliseconds: 400));
    expect(storage.appearanceJson, contains('"cornerStyle":"square"'));

    // 恢复默认外观
    await tester.scrollUntilVisible(
      find.text('恢复默认外观'),
      300,
      scrollable: scrollable,
    );
    await tester.tap(find.text('恢复默认外观'));
    await settle(tester);
    expect(settingsContext(tester).tokens.squareCorners, isFalse);
    expect(settingsContext(tester).reduceMotion, isFalse);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
    'desktop: immersive lyrics opens from the player bar and closes with Esc',
    (tester) async {
      await pumpApp(
        tester,
        const Size(1440, 900),
        lyrics: {
          SampleCatalog.track1.id: const SpotifyLyrics(
            lines: [
              LyricLine(startTimeMs: 0, words: 'Immersive first line'),
              LyricLine(startTimeMs: 4000, words: 'Immersive second line'),
            ],
          ),
        },
      );
      final playback = Provider.of<PlaybackProvider>(
        tester.element(find.byType(MainShell)),
        listen: false,
      );
      await playback.playTrack(
        SampleCatalog.track1,
        contextQueue: const [SampleCatalog.track1, SampleCatalog.track2],
        context: const PlaybackContext.playlist(
          'Synthetic Mix',
          uri: 'spotify:playlist:synthetic',
        ),
      );
      await settle(tester);

      await tester.tap(find.byTooltip('沉浸式歌词').first);
      await settle(tester);
      expect(find.byType(ImmersiveLyricsScreen), findsOneWidget);
      expect(find.text('Immersive first line'), findsOneWidget);
      expect(find.byTooltip('退出全屏歌词（Esc）'), findsOneWidget);

      // Controls must remain reachable in the minimum window and a short wide window.
      for (final size in [const Size(360, 600), const Size(1000, 600)]) {
        tester.view.physicalSize = size;
        await settle(tester);
        final close = find.byTooltip('退出全屏歌词（Esc）');
        // 沉浸页的翻译开关收进控制卡片底栏
        final translate = find.byType(LyricsTranslationToggle);
        expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
        expect(
          tester.getCenter(close).dx,
          lessThan(tester.getCenter(translate).dx),
        );
        final sliders = find.descendant(
          of: find.byType(ImmersiveLyricsScreen),
          matching: find.byType(Slider),
        );
        final volume = sliders.last;
        // 音量条在播放控件下方、同一块玻璃卡片内部，进度条之下
        final controls = find.byKey(const ValueKey('lyrics-control-card'));
        expect(
          tester.getCenter(volume).dy,
          greaterThan(tester.getCenter(sliders.first).dy),
        );
        expect(
          tester.getCenter(volume).dy,
          lessThan(tester.getBottomLeft(controls).dy),
        );
        expect(tester.getBottomLeft(volume).dy, lessThanOrEqualTo(size.height));
        expect(tester.takeException(), isNull);
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(ImmersiveLyricsScreen), findsNothing);
    },
  );
}
