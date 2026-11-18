import 'dart:convert';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

/// 布局兜底：在一系列窗口宽度（手机 → 桌面，含断点两侧）与默认 / 最大字号下渲染主页和设置页，
/// 任何 RenderFlex 溢出 / 布局异常都会让测试失败（Flutter 测试中溢出即报错）。
///
/// 桌面窗口最小可缩到 360 宽，所以每个宽度都可能被用户真实拖到。
void main() {
  const widths = <double>[320, 360, 390, 414, 480, 520, 600, 700, 799, 800, 900, 1024, 1100, 1280, 1440];
  // 高度给足：移动端设置页是懒加载 ListView，一屏放下全部分组才能都被布局到
  const height = 2400.0;

  for (final fontScale in const [1.0, AppearanceSettings.maxFontScale]) {
    testWidgets('no overflow across widths (font ${(fontScale * 100).round()}%)', (tester) async {
      ArtworkPalette.enabled = false;
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;

      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      await storage.preferences.setAppearanceJson(jsonEncode(AppearanceSettings.defaults.copyWith(fontScale: fontScale).toJson()));

      for (final width in widths) {
        tester.view.physicalSize = Size(width, height);
        await tester.pumpWidget(FlutifyApp(
          key: ValueKey(width),
          storageService: storage,
          audioEngine: FakeAudioPlayerService(),
          emePlayer: EmePlayer(),
          spotifyApiService: FakeSpotifyApiService(storage.auth),
          trackAudioLoader: FakeTrackAudioSource(),
        ));
        await tester.pump(const Duration(milliseconds: 500));

        Navigator.of(tester.element(find.byType(MainShell)), rootNavigator: true)
            .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(SettingsScreen), findsOneWidget, reason: '宽度 $width');
        // 溢出由框架直接报错（带出问题组件的创建位置）；这里打印宽度便于定位
        debugPrint('layout sweep ok: width=$width fontScale=$fontScale');
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
  }
}
