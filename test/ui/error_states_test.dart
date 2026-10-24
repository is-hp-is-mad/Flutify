import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_widgets.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';
import '../fixtures/sample_catalog.dart';

/// 接入真实数据后的界面兜底：播放失败提示、未登录时详情页 / 主页的登录引导。
void main() {
  const tracks = [SampleCatalog.track1, SampleCatalog.track2, SampleCatalog.track3];
  const mix = PlaybackContext.playlist('Synthetic Mix', uri: 'spotify:playlist:synthetic');

  Future<void> pumpApp(WidgetTester tester, {Size size = const Size(390, 844), TrackAudioSource? loader}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    await tester.pumpWidget(FlutifyApp(
      storageService: storage,
      audioEngine: FakeAudioPlayerService(),
      emePlayer: EmePlayer(),
      spotifyApiService: FakeSpotifyApiService(storage),
      trackAudioLoader: loader,
    ));
    await settle(tester);
  }

  PlaybackProvider playbackOf(WidgetTester tester) =>
      Provider.of<PlaybackProvider>(tester.element(find.byType(MainShell)), listen: false);

  testWidgets('unplayable track: toast names the track and says it was skipped', (tester) async {
    final loader = FakeTrackAudioSource()
      ..failures[SampleCatalog.track1.id] =
          const TrackPlaybackException(TrackPlaybackFailure.unavailable, 'unavailable');
    await pumpApp(tester, loader: loader);

    await playbackOf(tester).playTrack(tracks.first, contextQueue: tracks, context: mix);
    await settle(tester);

    expect(find.text('「Track One」暂时无法播放，已跳过'), findsOneWidget);
    expect(playbackOf(tester).currentTrack?.id, SampleCatalog.track2.id);
  });

  testWidgets('no session: toast asks to sign in, with a sign-in action', (tester) async {
    await pumpApp(tester);

    await playbackOf(tester).playTrack(tracks.first, contextQueue: tracks, context: mix);
    await settle(tester);

    expect(find.text('登录后才能播放'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '登录'), findsOneWidget);
  });

  testWidgets('network failure: toast offers a retry that reloads the track', (tester) async {
    final loader = FakeTrackAudioSource()
      ..failures[SampleCatalog.track1.id] = const TrackPlaybackException(TrackPlaybackFailure.network, 'offline');
    await pumpApp(tester, loader: loader);

    await playbackOf(tester).playTrack(tracks.first, contextQueue: tracks, context: mix);
    await settle(tester);
    expect(find.text('「Track One」加载失败，请检查网络'), findsOneWidget);

    loader.failures.clear();
    await tester.tap(find.widgetWithText(SnackBarAction, '重试'));
    await settle(tester);
    expect(loader.loaded.where((id) => id == SampleCatalog.track1.id).length, 2);
    expect(playbackOf(tester).playbackError, isNull);
  });

  testWidgets('signed out: a remote playlist shows the sign-in prompt instead of loading forever', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800));

    AppRoutes.openPlaylist(
      tester.element(find.byType(MainShell)),
      const SpotifyPlaylist(id: 'remote-playlist', name: 'Remote Only', totalTracks: 20),
    );
    await settle(tester);

    final placeholder = find.byType(CollectionErrorPlaceholder);
    expect(placeholder, findsOneWidget);
    expect(find.descendant(of: placeholder, matching: find.text('登录后即可查看这里的内容')), findsOneWidget);
    expect(find.descendant(of: placeholder, matching: find.widgetWithText(M3EButton, '登录')), findsOneWidget);
  });

  testWidgets('signed out: home asks to sign in rather than blaming the network', (tester) async {
    await pumpApp(tester);

    expect(find.text('登录后即可查看这里的内容'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsNothing);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
