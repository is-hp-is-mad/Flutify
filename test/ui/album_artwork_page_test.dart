import 'dart:convert';

import 'package:flutify_app/core/theme/album_artwork_scheme.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/image.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/appearance_provider.dart';
import 'package:flutify_app/providers/connect_provider.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/backup/playlist_backup_service.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/detail/album_detail_screen.dart';
import 'package:flutify_app/ui/screens/detail/playlist_detail_screen.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_hero.dart';
import 'package:flutify_app/ui/widgets/track_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

void main() {
  const cover = 'https://example.test/cover.jpg';
  const source = Color(0xFFFF2200);

  setUp(() {
    ArtworkPalette.enabled = false;
    ArtworkPalette.debugDominantOverrides.clear();
  });

  tearDown(ArtworkPalette.clear);

  Future<void> pumpPage(
    WidgetTester tester,
    Widget page, {
    bool increaseContrast = false,
    bool pureBlack = false,
    Map<String, List<SpotifyTrack>> albumTracks = const {},
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    if (increaseContrast || pureBlack) {
      storage.preferences.setAppearanceJson(
        jsonEncode(
          AppearanceSettings(
            increaseContrast: increaseContrast,
            pureBlack: pureBlack,
          ).toJson(),
        ),
      );
    }
    final appearance = AppearanceProvider(storage.preferences);
    final playback = PlaybackProvider(
      FakeAudioPlayerService(),
      storage.playback,
      audioLoader: FakeTrackAudioSource(),
    );
    final library = LibraryProvider(storage.library);
    final api = FakeSpotifyApiService(storage.auth, albumTracks: albumTracks);
    addTearDown(appearance.dispose);
    addTearDown(playback.dispose);
    addTearDown(library.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SpotifyApiService>.value(value: api),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: appearance),
          Provider<ConnectProvider?>.value(value: null),
          Provider<PlaylistBackupService?>.value(value: null),
          Provider<PreferencesProvider?>.value(value: null),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocale.delegates,
          supportedLocales: AppLocale.supportedLocales,
          theme: appearance.theme(Brightness.dark),
          home: page,
        ),
      ),
    );
    await tester.pump();
  }

  SpotifyAlbum album() => const SpotifyAlbum(
    id: 'album-1',
    name: 'After Hours',
    releaseDate: '2020-03-20',
    totalTracks: 1,
    images: [SpotifyImage(url: cover)],
  );

  testWidgets('album page uses the cover scheme for the whole page', (
    tester,
  ) async {
    ArtworkPalette.debugDominantOverrides[cover] = source;
    final scheme = AlbumArtworkScheme.from(source);
    await pumpPage(
      tester,
      AlbumDetailScreen(album: album()),
      pureBlack: true,
      albumTracks: {
        'album-1': const [
          SpotifyTrack(id: 't1', name: 'Night Drive', durationMs: 180000),
        ],
      },
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, scheme.forBrightness(Brightness.dark));
    expect(scaffold.backgroundColor, isNot(Colors.black));
    expect(
      tester.widget<Text>(find.text('Night Drive')).style?.color,
      scheme.foregroundFor(Brightness.dark),
    );
    expect(find.byType(CollectionTint), findsNothing);
    expect(find.byType(CollectionHeroFade), findsNothing);
    expect(find.text('3:00'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Icon &&
            (widget.icon == Icons.favorite_rounded ||
                widget.icon == Icons.favorite_border_rounded) &&
            widget.size == 22,
      ),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.height == 0.5,
      ),
      findsOneWidget,
    );
  });

  testWidgets('album track titles wrap and the menu hides album / artist', (
    tester,
  ) async {
    await pumpPage(
      tester,
      AlbumDetailScreen(album: album()),
      albumTracks: {
        'album-1': const [
          SpotifyTrack(id: 't1', name: 'Night Drive', durationMs: 180000),
        ],
      },
    );

    expect(tester.widget<Text>(find.text('Night Drive')).maxLines, 3);
    final tile = tester.element(find.text('Night Drive'));
    expect(TrackMenuScope.hidesNavigation(tile), isTrue);
    const track = SpotifyTrack(
      id: 't1',
      name: 'Night Drive',
      artists: [SpotifyArtist(id: 'a1', name: 'Artist')],
      album: SpotifyAlbum(id: 'album-1', name: 'After Hours'),
    );
    expect(TrackMenu.isAvailable(tile, track, TrackAction.album), isFalse);
    expect(TrackMenu.isAvailable(tile, track, TrackAction.artist), isFalse);
    expect(TrackMenu.isAvailable(tile, track, TrackAction.queue), isTrue);
  });

  testWidgets('increase contrast keeps the theme surface', (tester) async {
    ArtworkPalette.debugDominantOverrides[cover] = source;
    final scheme = AlbumArtworkScheme.from(source);
    await pumpPage(
      tester,
      AlbumDetailScreen(album: album()),
      increaseContrast: true,
      pureBlack: true,
      albumTracks: {
        'album-1': const [
          SpotifyTrack(id: 't1', name: 'Night Drive', durationMs: 180000),
        ],
      },
    );

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final surface = Theme.of(
      tester.element(find.byType(AlbumDetailScreen)),
    ).colorScheme.surface;
    expect(scaffold.backgroundColor, isNull);
    expect(surface, Colors.black);
    expect(
      tester.widget<Text>(find.text('Night Drive')).style?.color,
      isNot(scheme.foreground),
    );
  });

  testWidgets('a playlist keeps CollectionTint and is not recolored', (
    tester,
  ) async {
    ArtworkPalette.debugDominantOverrides[cover] = source;
    const playlist = SpotifyPlaylist(
      id: 'playlist-1',
      name: 'Daily Mix',
      images: [SpotifyImage(url: cover)],
      tracks: [SpotifyTrack(id: 'p1', name: 'Playlist Song')],
      totalTracks: 1,
    );
    await pumpPage(tester, const PlaylistDetailScreen(playlist: playlist));

    expect(find.byType(CollectionTint), findsOneWidget);
    expect(find.byType(CollectionHeroFade), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      isNull,
    );
    expect(find.text('Playlist Song'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
  });
}
