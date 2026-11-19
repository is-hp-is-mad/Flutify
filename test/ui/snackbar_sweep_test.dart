import 'dart:convert';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/models/track_playback_exception.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_catalog.dart';

/// 底部提示兜底：在某个窗口尺寸弹出播放失败提示后，把窗口拖过手机 / 桌面断点、
/// 拖到最小尺寸，提示在每个尺寸下都不能溢出或抛异常（Flutter 测试中溢出即报错）。
///
/// 覆盖最长的两类提示：带「重试」的网络错误、连续失败自动暂停后带「下一首」的提示。
void main() {
  const tracks = [SampleCatalog.track1, SampleCatalog.track2, SampleCatalog.track3];
  const mix = PlaybackContext.playlist('Synthetic Mix', uri: 'spotify:playlist:synthetic');

  /// 弹出提示时的窗口尺寸（桌面宽屏 / 桌面断点 / 手机）。
  const startSizes = [Size(1360, 860), Size(800, 600), Size(390, 844)];

  /// 提示显示期间依次拖到的尺寸（含断点两侧与窗口最小尺寸 360×600）。
  const resizes = [
    Size(360, 600),
    Size(799, 600),
    Size(800, 600),
    Size(1100, 700),
    Size(1440, 900),
    Size(520, 900),
    Size(360, 600),
  ];

  const scenarios = <String, TrackPlaybackFailure>{
    'network-retry': TrackPlaybackFailure.network,
    'auto-paused': TrackPlaybackFailure.unavailable,
  };

  /// 各场景提示文案里的关键字（用于找到提示正文）。
  const keywords = <String, String>{'network-retry': '加载失败', 'auto-paused': '已暂停'};

  for (final fontScale in const [1.0, AppearanceSettings.maxFontScale]) {
    for (final scenario in scenarios.entries) {
      for (final start in startSizes) {
        final name =
            '${scenario.key} shown at ${start.width.toInt()}x${start.height.toInt()} '
            '(font ${(fontScale * 100).round()}%)';
        final keyword = keywords[scenario.key]!;
        testWidgets('toast survives resizing: $name', (tester) async {
          ArtworkPalette.enabled = false;
          addTearDown(tester.view.reset);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = start;

          SharedPreferences.setMockInitialValues({});
          final storage = await StorageService.init();
          await storage.preferences.setAppearanceJson(
            jsonEncode(AppearanceSettings.defaults.copyWith(fontScale: fontScale).toJson()),
          );

          // 网络错误只让第一首失败；自动暂停场景三首全部不可播放
          final loader = FakeTrackAudioSource();
          final failing = scenario.value == TrackPlaybackFailure.network ? tracks.take(1) : tracks;
          for (final track in failing) {
            loader.failures[track.id] = TrackPlaybackException(scenario.value, 'synthetic');
          }

          await tester.pumpWidget(
            FlutifyApp(
              storageService: storage,
              audioEngine: FakeAudioPlayerService(),
              emePlayer: EmePlayer(),
              spotifyApiService: FakeSpotifyApiService(storage.auth),
              trackAudioLoader: loader,
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));

          final playback = Provider.of<PlaybackProvider>(tester.element(find.byType(MainShell)), listen: false);
          await playback.playTrack(tracks.first, contextQueue: tracks, context: mix);
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.byType(SnackBar), findsWidgets, reason: name);

          for (final size in resizes) {
            tester.view.physicalSize = size;
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            final at = '$name → ${size.width.toInt()}x${size.height.toInt()}';

            // 文字必须有可读宽度（旧实现按弹出时的宽度算边距，拖窄后文字被挤成 0 宽）
            final message = find.descendant(of: find.byType(SnackBar), matching: find.textContaining(keyword)).first;
            expect(tester.getSize(message).width, greaterThan(120), reason: at);

            // 卡片完整落在窗口内；桌面布局下还要在 90 高的播放栏之上
            final card = tester.getRect(
              find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first,
            );
            expect(card.left, greaterThanOrEqualTo(0), reason: at);
            expect(card.right, lessThanOrEqualTo(size.width), reason: at);
            expect(card.top, greaterThanOrEqualTo(0), reason: at);
            final floor = size.width >= 800 ? size.height - 90 : size.height;
            expect(card.bottom, lessThanOrEqualTo(floor), reason: at);
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 11));
        });
      }
    }
  }
}
