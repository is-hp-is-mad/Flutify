import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/controlled_home_api.dart';
import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_home.dart';

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('home refresh button works at width $width', (tester) async {
      final api = await pumpHome(tester, width, SampleHome.feed);
      await tester.tap(find.byTooltip('刷新首页'));
      await tester.pump();
      expect(api.requests, hasLength(2));
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.refresh_rounded),
            )
            .onPressed,
        isNull,
      );
      api.requests.last.result.completeError(StateError('offline'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('刷新失败，请检查网络后重试。'), findsOneWidget);
      expect(find.text('已点赞的歌曲'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
  }

  testWidgets('pull to refresh works with an empty short feed', (tester) async {
    final api = await pumpHome(tester, 390, HomeFeed.empty);
    final scroll = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byType(CustomScrollView),
    );
    await tester.drag(scroll, const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(api.requests, hasLength(2));
    api.requests.last.result.complete(SampleHome.feed);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('已点赞的歌曲'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });
}

Future<ControlledHomeApi> pumpHome(
  WidgetTester tester,
  double width,
  HomeFeed feed,
) async {
  ArtworkPalette.enabled = false;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  final api = ControlledHomeApi(storage.auth);
  await tester.pumpWidget(
    FlutifyApp(
      storageService: storage,
      audioEngine: FakeAudioPlayerService(),
      emePlayer: EmePlayer(),
      spotifyApiService: api,
      trackAudioLoader: FakeTrackAudioSource(),
    ),
  );
  api.requests.single.result.complete(feed);
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return api;
}
