import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/services/audio_player_service.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';

/// 启动冒烟测试：移动端（底部导航）与桌面端（三栏框架）都能正常出第一帧。
void main() {
  Future<void> pumpApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 封面取色会启动图片解码计时器，测试结束时仍未完成会报 pending timer
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: AudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: SpotifyApiService(storage.auth),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('mobile smoke test: bottom navigation', (tester) async {
    await pumpApp(tester, const Size(400, 860));

    final nav = find.byType(NavigationBar);
    expect(nav, findsOneWidget);
    for (final label in ['主页', '搜索', '音乐库']) {
      expect(find.descendant(of: nav, matching: find.text(label)), findsOneWidget);
    }
  });

  testWidgets('desktop smoke test: top bar, library sidebar and player bar', (tester) async {
    await pumpApp(tester, const Size(1280, 800));

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byTooltip('主页'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.text('你想听什么？'), findsOneWidget);
    expect(find.byTooltip('折叠音乐库'), findsOneWidget);
  });
}
