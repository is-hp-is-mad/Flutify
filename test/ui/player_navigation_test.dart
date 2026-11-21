import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/album_detail_screen.dart';
import 'package:flutify_app/ui/screens/detail/artist_detail_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutify_app/ui/screens/player/immersive_lyrics_screen.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

const _artist = SpotifyArtist(
  id: 'navigation-artist',
  name: 'Navigation Artist',
);
const _guest = SpotifyArtist(id: 'navigation-guest', name: 'Navigation Guest');
const _album = SpotifyAlbum(id: 'navigation-album', name: 'Navigation Album');
const _previousAlbum = SpotifyAlbum(
  id: 'previous-album',
  name: 'Previous Album',
);

enum _Player { full, immersive, stacked }

Future<void> _settle(WidgetTester tester) async {
  // Playback/lyrics animate continuously, so pumpAndSettle cannot be used.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<PlaybackProvider> _pumpPlaying(
  WidgetTester tester,
  TargetPlatform platform, {
  bool multipleArtists = false,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = platform == TargetPlatform.android
      ? const Size(390, 844)
      : const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final paletteEnabled = ArtworkPalette.enabled;
  ArtworkPalette.enabled = false;
  addTearDown(() => ArtworkPalette.enabled = paletteEnabled);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  final audio = FakeAudioPlayerService();
  await tester.pumpWidget(
    FlutifyApp(
      storageService: storage,
      audioEngine: audio,
      emePlayer: EmePlayer(),
      spotifyApiService: FakeSpotifyApiService(storage.auth),
      trackAudioLoader: FakeTrackAudioSource(),
    ),
  );
  await _settle(tester);
  final context = tester.element(find.byType(MainShell));
  final playback = context.read<PlaybackProvider>();
  await playback.playTrack(
    SpotifyTrack(
      id: 'navigation-track',
      name: 'Navigation Track',
      durationMs: 180000,
      artists: multipleArtists ? const [_artist, _guest] : const [_artist],
      album: _album,
    ),
  );
  audio.durationController.add(const Duration(minutes: 3));
  audio.positionController.add(const Duration(seconds: 30));
  audio.stateController.add(PlayerState(true, ProcessingState.ready));
  AppRoutes.openAlbum(context, _previousAlbum);
  await _settle(tester);
  expect(playback.isPlaying, isTrue);
  return playback;
}

Future<void> _openPlayer(WidgetTester tester, _Player player) async {
  if (player != _Player.immersive) {
    FullPlayerSheet.show(tester.element(find.byType(MainShell)));
    await _settle(tester);
  }
  if (player != _Player.full) {
    ImmersiveLyricsScreen.open(
      tester.element(
        find.byType(player == _Player.stacked ? FullPlayerSheet : MainShell),
      ),
    );
    await _settle(tester);
  }
}

Future<void> _openMenu(WidgetTester tester, _Player player) async {
  final screen = find.byType(
    player == _Player.full ? FullPlayerSheet : ImmersiveLyricsScreen,
  );
  if (player != _Player.full) {
    // The immersive window hides its floating buttons after 3 idle seconds;
    // moving the mouse brings them back, as it does for a real user.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    // A hover at the exact position of the previous one is not activity (the
    // lyrics scroll under a still cursor), so nudge the pointer first.
    await mouse.moveTo(tester.getCenter(screen) + const Offset(3, 3));
    await mouse.moveTo(tester.getCenter(screen));
    await tester.pump();
    // The controls card (which now carries the menu button) unfolds with an
    // animation after being woken; wait for it like a real user would.
    await tester.pump(const Duration(milliseconds: 800));
    await mouse.removePointer();
  }
  await tester.tap(
    find.descendant(of: screen, matching: find.byTooltip('更多选项')),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  Navigator.of(
    tester.element(find.byType(MainShell, skipOffstage: false)),
    rootNavigator: true,
  ).popUntil((route) => route.isFirst);
  await _settle(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await _settle(tester);
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    for (final player in _Player.values) {
      for (final destination in ['album', 'artist', 'guest artist']) {
        testWidgets(
          '${platform.name} $player menu opens $destination visibly',
          (tester) async {
            final playback = await _pumpPlaying(
              tester,
              platform,
              multipleArtists: destination == 'guest artist',
            );
            final root = Navigator.of(
              tester.element(find.byType(MainShell)),
              rootNavigator: true,
            );
            final content = AppRoutes.contentNavigator!()!;
            await _openPlayer(tester, player);
            await _openMenu(tester, player);
            await tester.tap(
              find.text(destination == 'album' ? '转至专辑' : '转至艺人'),
            );
            await _settle(tester);
            if (destination == 'guest artist') {
              // Opening the artist picker must not dismiss the player yet.
              expect(root.canPop(), isTrue);
              await tester.tap(find.text(_guest.name));
              await _settle(tester);
            }

            expect(
              find.byType(FullPlayerSheet, skipOffstage: false),
              findsNothing,
            );
            expect(
              find.byType(ImmersiveLyricsScreen, skipOffstage: false),
              findsNothing,
            );
            expect(root.canPop(), isFalse);
            expect(DesktopWindow.immersiveWindow.value, isFalse);
            if (destination == 'album') {
              expect(
                tester
                    .widget<AlbumDetailScreen>(find.byType(AlbumDetailScreen))
                    .album
                    .id,
                _album.id,
              );
            } else {
              expect(
                tester
                    .widget<ArtistDetailScreen>(find.byType(ArtistDetailScreen))
                    .artist
                    .id,
                destination == 'guest artist' ? _guest.id : _artist.id,
              );
            }
            expect(playback.currentTrack?.id, 'navigation-track');
            expect(playback.isPlaying, isTrue);
            expect(playback.position, const Duration(seconds: 30));

            // Back returns to the previous content page, never a hidden player.
            content.pop();
            await _settle(tester);
            expect(
              tester
                  .widget<AlbumDetailScreen>(find.byType(AlbumDetailScreen))
                  .album
                  .id,
              _previousAlbum.id,
            );
            // Closing through navigation also resets the modal open guards.
            await _openPlayer(tester, player);
            expect(
              find.byType(
                player == _Player.full
                    ? FullPlayerSheet
                    : ImmersiveLyricsScreen,
              ),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await _unmount(tester);
          },
        );
      }

      testWidgets('${platform.name} $player keeps player for non-navigation', (
        tester,
      ) async {
        final playback = await _pumpPlaying(
          tester,
          platform,
          multipleArtists: true,
        );
        final root = Navigator.of(
          tester.element(find.byType(MainShell)),
          rootNavigator: true,
        );
        await _openPlayer(tester, player);
        final screen = find.byType(
          player == _Player.full ? FullPlayerSheet : ImmersiveLyricsScreen,
        );
        final playerRoute = ModalRoute.of(tester.element(screen))!;

        await _openMenu(tester, player);
        root.pop(); // Dismiss the menu without selecting anything.
        await _settle(tester);
        expect(playerRoute.isCurrent, isTrue);

        await _openMenu(tester, player);
        await tester.tap(find.text('转至艺人'));
        await _settle(tester);
        root.pop(); // Cancel the multi-artist picker.
        await _settle(tester);
        expect(playerRoute.isCurrent, isTrue);

        await _openMenu(tester, player);
        await tester.tap(find.text('加入播放队列'));
        await _settle(tester);
        expect(playback.userQueue, hasLength(1));
        expect(playerRoute.isCurrent, isTrue);
        expect(screen, findsOneWidget);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });
    }
  }
}
