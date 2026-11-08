import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/appearance_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/shell/mobile/android_floating_bar.dart';
import 'package:flutify_app/ui/shell/mobile/mobile_bottom_bar.dart';
import 'package:flutify_app/ui/widgets/mini_player.dart';
import 'package:flutify_app/ui/widgets/player_controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_glass/hyper_ui.dart' show HyperBottomBar;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_track_audio_source.dart';

/// Android 柔光玻璃的悬浮底栏：尺寸、随滚动收放、切换 Tab；其他平台保持原底栏。
void main() {
  const tracks = [
    SpotifyTrack(id: 'synthetic-1', name: 'Synthetic One', durationMs: 180000),
    SpotifyTrack(id: 'synthetic-2', name: 'Synthetic Two', durationMs: 200000),
  ];

  // 平台覆盖要在测试体结束前复位，否则框架报调试变量未还原
  void shellTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    bool playing = true,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: SpotifyApiService(storage),
        trackAudioLoader: FakeTrackAudioSource(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final shell = tester.element(find.byType(MainShell));
    final appearance = shell.read<AppearanceProvider>();
    appearance.update(
      appearance.settings.copyWith(glassMaterial: GlassMaterial.hyper),
    );
    await tester.pump();
    if (playing) {
      await shell.read<PlaybackProvider>().playTrack(
        tracks.first,
        contextQueue: tracks,
        context: const PlaybackContext.playlist(
          'Synthetic Mix',
          uri: 'spotify:playlist:synthetic',
        ),
      );
    }
    await settle(tester);
  }

  FloatingBarFold fold(WidgetTester tester) =>
      tester.widget<MobileBottomBar>(find.byType(MobileBottomBar)).fold!;

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(ValueKey(key)));

  // 弹簧停在目标的容差内，不是精确等于目标
  void expectRect(Rect actual, Rect expected) {
    for (final (a, e) in [
      (actual.left, expected.left),
      (actual.top, expected.top),
      (actual.right, expected.right),
      (actual.bottom, expected.bottom),
    ]) {
      expect(a, closeTo(e, 0.5), reason: '$actual vs $expected');
    }
  }

  Finder heart() => find.descendant(
    of: find.byType(MiniPlayer),
    matching: find.byType(LikeButton),
  );

  shellTest('展开：左右留 16，播放器 56 高在导航 64 高之上，间隔 8', (tester) async {
    await pumpShell(tester);
    expect(find.byType(AndroidFloatingBar), findsOneWidget);
    expect(find.byType(HyperBottomBar), findsNothing);

    final nav = rectOf(tester, 'floating-bar-nav');
    expect(
      nav,
      const Rect.fromLTRB(16, 844 - 34 - 12 - 64, 390 - 16, 844 - 46),
    );
    final player = rectOf(tester, 'floating-bar-player');
    expect(player.left, 16);
    expect(player.right, 374);
    expect(player.height, 56);
    expect(nav.top - player.bottom, 8);
    expect(
      tester.getRect(
        find.byKey(const ValueKey('mini-player-expansion-source')),
      ),
      player,
    );
    for (final label in ['主页', '搜索', '音乐库']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(heart(), findsOneWidget);
    expect(find.byKey(const ValueKey('floating-bar-search')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  shellTest('往下滚动收起成两枚圆钮，播放器下沉到中间；往回滚沿原路展开', (tester) async {
    await pumpShell(tester);
    final open = rectOf(tester, 'floating-bar-nav');

    fold(tester).value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // 途中：药丸正在变窄，搜索圆钮已经分裂出来
    final moving = rectOf(tester, 'floating-bar-nav');
    expect(moving.width, inExclusiveRange(56, open.width));
    expect(find.byKey(const ValueKey('floating-bar-search')), findsOneWidget);

    await settle(tester);
    final left = rectOf(tester, 'floating-bar-nav');
    final search = rectOf(tester, 'floating-bar-search');
    final player = rectOf(tester, 'floating-bar-player');
    expectRect(left, const Rect.fromLTWH(16, 844 - 46 - 56, 56, 56));
    expectRect(
      search,
      const Rect.fromLTWH(390 - 16 - 56, 844 - 46 - 56, 56, 56),
    );
    expectRect(
      player,
      Rect.fromLTRB(left.right + 8, left.top, search.left - 8, left.bottom),
    );
    // 标签、心形与进度线收起；当前 Tab 图标与播放键留着
    expect(find.text('主页'), findsNothing);
    expect(heart(), findsNothing);
    expect(find.byIcon(Icons.home_filled), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MiniPlayer),
        matching: find.byType(PlayPauseButton),
      ),
      findsOneWidget,
    );

    fold(tester).value = false;
    await settle(tester);
    expectRect(rectOf(tester, 'floating-bar-nav'), open);
    expect(find.byKey(const ValueKey('floating-bar-search')), findsNothing);
    expect(heart(), findsOneWidget);
    expect(find.text('主页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  shellTest('收起后点左钮展开，点搜索钮切到搜索并展开', (tester) async {
    await pumpShell(tester);
    fold(tester).value = true;
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('floating-bar-expand')));
    await settle(tester);
    expect(fold(tester).value, isFalse);
    expect(find.text('音乐库'), findsOneWidget);

    fold(tester).value = true;
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('floating-bar-search')));
    await settle(tester);
    expect(
      tester
          .widget<MobileBottomBar>(find.byType(MobileBottomBar))
          .selectedIndex,
      1,
    );
    expect(fold(tester).value, isFalse);

    // 在搜索页收起时，左钮仍是上一个非搜索 Tab
    fold(tester).value = true;
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('floating-bar-nav')),
        matching: find.byIcon(Icons.home_outlined),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  shellTest('点按与横向拖动切换 Tab，胶囊移动时浮起并回弹落位', (tester) async {
    await pumpShell(tester);
    int selected() => tester
        .widget<MobileBottomBar>(find.byType(MobileBottomBar))
        .selectedIndex;

    await tester.tap(find.byKey(const ValueKey('floating-bar-tab-2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(selected(), 2);
    // 移动中：胶囊浮起，镜片（放大 + 边缘高光）出现
    expect(find.byKey(const ValueKey('floating-bar-lens')), findsOneWidget);
    await settle(tester);
    expect(find.byKey(const ValueKey('floating-bar-lens')), findsNothing);

    final nav = rectOf(tester, 'floating-bar-nav');
    final gesture = await tester.startGesture(
      nav.centerRight - const Offset(40, 0),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-200, 0));
    // 第一帧只记下弹簧的起始时间
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byKey(const ValueKey('floating-bar-lens')), findsOneWidget);
    await gesture.up();
    await settle(tester);
    expect(selected(), 0);
    expect(tester.takeException(), isNull);
  });

  shellTest('没有曲目时只有导航药丸', (tester) async {
    await pumpShell(tester, playing: false);
    expect(find.byKey(const ValueKey('floating-bar-player')), findsNothing);
    expect(
      tester.getSize(find.byType(AndroidFloatingBar)).height,
      34 + 12 + 64,
    );
  });

  shellTest('iOS 保持原来的柔光玻璃底栏', (tester) async {
    await pumpShell(tester, platform: TargetPlatform.iOS);
    expect(find.byType(AndroidFloatingBar), findsNothing);
    expect(find.byType(HyperBottomBar), findsOneWidget);
  });

  testWidgets('滚动驱动收放：往下读收起，往回滚保持收起，回到顶部才展开', (tester) async {
    final fold = FloatingBarFold();
    addTearDown(fold.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationListener<ScrollNotification>(
          onNotification: fold.handle,
          child: ListView.builder(
            controller: controller,
            itemCount: 100,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('$i')),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -10));
    await tester.pump();
    expect(fold.value, isFalse, reason: '抖动不收起');
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(fold.value, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pump();
    expect(fold.value, isTrue, reason: '往回滚但没到顶，保持收起');
    controller.jumpTo(0);
    await tester.pump();
    expect(fold.value, isFalse);
  });

  testWidgets('惯性滚动中手动展开，这次滚动不再收回去；下一次往下滚才收起', (tester) async {
    final fold = FloatingBarFold();
    addTearDown(fold.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: NotificationListener<ScrollNotification>(
          onNotification: fold.handle,
          child: ListView.builder(
            itemCount: 500,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('$i')),
          ),
        ),
      ),
    );
    await tester.fling(find.byType(ListView), const Offset(0, -400), 4000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(fold.value, isTrue);

    fold.expand();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(fold.value, isFalse, reason: '惯性还在走，但不再收起');
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(fold.value, isTrue);
  });
}
