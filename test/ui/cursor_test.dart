import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/home/home_screen.dart';
import 'package:flutify_app/ui/screens/library/library_screen.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyric_line_view.dart';
import 'package:flutify_app/ui/screens/settings/widgets/gradient_track_slider.dart';
import 'package:flutify_app/ui/screens/settings/widgets/settings_segmented.dart';
import 'package:flutify_app/ui/widgets/user_avatar.dart';
import 'package:flutify_app/ui/widgets/share/share_action_tile.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';

/// 可点击控件的鼠标指针：自绘控件必须是手型，Material 默认与禁用态不能被误伤。
void main() {
  /// 鼠标设备 id（flutter_test 默认鼠标设备号为 1）。
  const mouseDevice = 1;

  Future<TestGesture> mouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    return gesture;
  }

  Future<void> hover(
    WidgetTester tester,
    TestGesture gesture,
    Finder finder,
  ) async {
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pump();
  }

  MouseCursor? activeCursor() =>
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(mouseDevice);

  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpMobileApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 900);
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
        spotifyApiService: SpotifyApiService(storage.auth),
      ),
    );
    await settle(tester);
  }

  testWidgets('设置分段控件每段显示手型', (tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 300,
          child: SettingsSegmented<String>(
            values: const ['a', 'b'],
            labelOf: (value) => value,
            selected: 'a',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final gesture = await mouse(tester);
    await hover(tester, gesture, find.text('b'));
    expect(activeCursor(), SystemMouseCursors.click);
  });

  testWidgets('分享卡片按复制文本或回调显示手型，无动作保持箭头', (tester) async {
    final gesture = await mouse(tester);
    for (final action in ['copy', 'callback', 'none']) {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 160,
            height: 130,
            child: ShareActionTile(
              icon: Icons.link,
              label: 'Share action',
              copyText: action == 'copy' ? 'spotify:track:cursor-test' : null,
              onTap: action == 'callback' ? () async => null : null,
            ),
          ),
        ),
      );
      await hover(tester, gesture, find.byType(ShareActionTile));
      expect(
        activeCursor(),
        action == 'none' ? SystemMouseCursors.basic : SystemMouseCursors.click,
        reason: action,
      );
    }
  });

  testWidgets('取色滑杆显示手型', (tester) async {
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 240,
          child: GradientTrackSlider(
            value: 0.5,
            colors: const [Colors.red, Colors.blue],
            thumbColor: Colors.red,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final gesture = await mouse(tester);
    await hover(tester, gesture, find.byType(GradientTrackSlider));
    expect(activeCursor(), SystemMouseCursors.click);
  });

  testWidgets('可跳转歌词行显示手型，不可跳转保持箭头', (tester) async {
    await tester.pumpWidget(
      wrap(
        LyricLineView(
          text: 'walking down the road',
          distance: 0,
          cursor: SystemMouseCursors.click,
          onTap: () {},
        ),
      ),
    );
    final gesture = await mouse(tester);
    await hover(tester, gesture, find.byType(LyricLineView));
    expect(activeCursor(), SystemMouseCursors.click);

    await tester.pumpWidget(
      wrap(
        const LyricLineView(
          text: 'walking down the road',
          distance: 0,
          cursor: SystemMouseCursors.click,
        ),
      ),
    );
    await hover(tester, gesture, find.byType(LyricLineView));
    expect(activeCursor(), SystemMouseCursors.basic);
  });

  testWidgets('窄窗桌面布局的头像（首页 / 音乐库）显示手型', (tester) async {
    await pumpMobileApp(tester);
    final gesture = await mouse(tester);

    final homeAvatar = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byType(UserAvatar),
    );
    expect(homeAvatar, findsOneWidget);
    await hover(tester, gesture, homeAvatar);
    expect(activeCursor(), SystemMouseCursors.click);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('音乐库'),
      ),
    );
    await settle(tester);

    final libraryAvatar = find.descendant(
      of: find.byType(LibraryScreen),
      matching: find.byType(UserAvatar),
    );
    expect(libraryAvatar, findsOneWidget);
    await hover(tester, gesture, libraryAvatar);
    expect(activeCursor(), SystemMouseCursors.click);
    expect(tester.takeException(), isNull);
  });

  testWidgets('应用主题：可用 IconButton 手型、禁用保持箭头', (tester) async {
    await pumpMobileApp(tester);
    final gesture = await mouse(tester);

    // 首页刷新按钮：未配置 API 时禁用 → 箭头
    final refresh = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byIcon(Icons.refresh_rounded),
    );
    expect(refresh, findsOneWidget);
    await hover(tester, gesture, refresh);
    expect(activeCursor(), SystemMouseCursors.basic);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('音乐库'),
      ),
    );
    await settle(tester);

    // 音乐库搜索按钮：可用 → 手型（主题统一覆盖 Material 的桌面默认箭头）
    final search = find.descendant(
      of: find.byType(LibraryScreen),
      matching: find.byIcon(Icons.search_rounded),
    );
    expect(search, findsOneWidget);
    await hover(tester, gesture, search);
    expect(activeCursor(), SystemMouseCursors.click);
    expect(tester.takeException(), isNull);
  });
}
