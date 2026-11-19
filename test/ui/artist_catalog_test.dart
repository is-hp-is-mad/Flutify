import 'dart:async';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/catalog_page.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/artist_catalog_screen.dart';
import 'package:flutify_app/ui/screens/detail/artist_detail_screen.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_widgets.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/widgets/mini_player.dart';
import 'package:flutify_app/ui/widgets/track_tile.dart';
import 'package:flutify_app/ui/widgets/track_options_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

const artist = SpotifyArtist(id: 'catalog-artist', name: 'Catalog Artist');

class ArtistCatalogApi extends FakeSpotifyApiService {
  ArtistCatalogApi(super.storage);

  List<SpotifyTrack> topTracks = [];
  List<SpotifyAlbum> previewAlbums = [];
  final albumPages = <int, CatalogPage<SpotifyAlbum>>{};
  final songPages = <int, ArtistTracksPage>{};
  final failingAlbumOffsets = <int>{};
  final failingSongOffsets = <int>{};
  final deferredAlbums = <int, Completer<CatalogPage<SpotifyAlbum>>>{};

  @override
  bool get isConfigured => true;

  @override
  Future<SpotifyArtist> getArtist(String id) async => artist;

  @override
  Future<List<SpotifyTrack>> getArtistTopTracks(String id) async => topTracks;

  @override
  Future<List<SpotifyAlbum>> getArtistAlbums(String id) async => previewAlbums;

  @override
  Future<CatalogPage<SpotifyAlbum>> getArtistAlbumsPage(
    String id, {
    int offset = 0,
    int limit = 20,
  }) async {
    if (failingAlbumOffsets.contains(offset)) throw StateError('offline');
    if (deferredAlbums.containsKey(offset)) {
      return deferredAlbums[offset]!.future;
    }
    return albumPages[offset] ?? const CatalogPage(items: []);
  }

  @override
  Future<ArtistTracksPage> getArtistTracksPage(
    String id, {
    ArtistTracksCursor? cursor,
    int limit = 50,
  }) async {
    final offset = cursor?.nextAlbumOffset ?? 0;
    if (failingSongOffsets.contains(offset)) throw StateError('offline');
    return songPages[offset] ?? const ArtistTracksPage(items: []);
  }
}

Future<ArtistCatalogApi> pumpArtistApp(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  void Function(ArtistCatalogApi)? configure,
  bool openOverview = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  ArtworkPalette.enabled = false;
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  final api = ArtistCatalogApi(storage.auth);
  configure?.call(api);
  await tester.pumpWidget(
    FlutifyApp(
      storageService: storage,
      audioEngine: FakeAudioPlayerService(),
      emePlayer: EmePlayer(),
      spotifyApiService: api,
      trackAudioLoader: FakeTrackAudioSource(),
    ),
  );
  await settle(tester);
  if (openOverview) {
    AppRoutes.openArtist(tester.element(find.byType(MainShell)), artist);
    await settle(tester);
  }
  return api;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('artist catalog links stay available when previews are empty', (
    tester,
  ) async {
    await pumpArtistApp(tester);

    await tester.scrollUntilVisible(
      find.byKey(const Key('artist-songs-link')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ArtistDetailScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const Key('artist-songs-link')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('artist-albums-link')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ArtistDetailScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const Key('artist-albums-link')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'albums arrow opens a paginated catalog under the existing player',
    (tester) async {
      final albums = List.generate(
        24,
        (i) => SpotifyAlbum(
          id: 'album-$i',
          name: 'Album $i',
          releaseDate: '2024-01-01',
          artists: [artist],
        ),
      );
      await pumpArtistApp(
        tester,
        configure: (api) {
          api.previewAlbums = albums.take(1).toList();
          api.albumPages[0] = CatalogPage(
            items: albums.take(20).toList(),
            nextOffset: 20,
            total: 24,
          );
          api.albumPages[20] = CatalogPage(
            items: albums.skip(20).toList(),
            offset: 20,
            total: 24,
          );
        },
      );
      final playback = tester
          .element(find.byType(MainShell))
          .read<PlaybackProvider>();
      await playback.playTrack(
        const SpotifyTrack(id: 'playing', name: 'Keep playing'),
      );
      await settle(tester);
      final arrow = find.byKey(const Key('artist-albums-link'));
      await tester.scrollUntilVisible(
        arrow,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ArtistDetailScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(tester.element(arrow), alignment: 0.35);
      await settle(tester);
      await tester.tap(arrow);
      await settle(tester);
      expect(find.byType(ArtistCatalogScreen), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(playback.currentTrack?.id, 'playing');

      await tester.scrollUntilVisible(
        find.text('Album 23'),
        350,
        scrollable: find.descendant(
          of: find.byType(ArtistCatalogScreen),
          matching: find.byType(Scrollable),
        ),
      );
      await settle(tester);
      expect(find.text('Album 23'), findsOneWidget);
      await tester.tap(find.byKey(const Key('artist-catalog-back')));
      await settle(tester);
      expect(find.byKey(const Key('artist-albums-link')), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'songs include catalog tracks, deduplicate top tracks, and keep album/year metadata',
    (tester) async {
      const album = SpotifyAlbum(
        id: 'opus',
        name: 'Opus',
        releaseDate: '2024-08-09',
        artists: [artist],
      );
      const top = SpotifyTrack(
        id: 'top',
        name: 'Top track',
        album: SpotifyAlbum(id: 'opus', name: 'Opus'),
        artists: [artist],
      );
      const catalog = SpotifyTrack(
        id: 'catalog',
        name: 'Beyond the top tracks',
        album: album,
        artists: [artist],
      );
      await pumpArtistApp(
        tester,
        configure: (api) {
          api.topTracks = [top];
          api.songPages[0] = ArtistTracksPage(
            items: [
              top.copyWith(album: album),
              catalog,
            ],
          );
        },
      );
      final arrow = find.byKey(const Key('artist-songs-link'));
      await tester.scrollUntilVisible(
        arrow,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ArtistDetailScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(arrow);
      await settle(tester);
      expect(find.text('Top track'), findsOneWidget);
      expect(find.text('Beyond the top tracks'), findsOneWidget);
      expect(find.text('Opus · 2024'), findsNWidgets(2));
      expect(find.byType(TrackTile), findsNWidgets(2));
      final tile = find.widgetWithText(TrackTile, 'Beyond the top tracks');
      expect(
        find.descendant(of: tile, matching: find.byTooltip('更多选项')),
        findsOneWidget,
      );
      await tester.tap(find.text('Beyond the top tracks'));
      await settle(tester);
      final playback = tester
          .element(find.byType(MainShell))
          .read<PlaybackProvider>();
      expect(playback.currentTrack?.id, catalog.id);
      expect(playback.playbackContext.uri, artist.contextUri);
      await tester.tap(
        find.descendant(of: tile, matching: find.byTooltip('更多选项')),
      );
      await settle(tester);
      expect(find.byType(TrackOptionsSheet), findsOneWidget);
      expect(
        tester
            .widget<TrackOptionsSheet>(find.byType(TrackOptionsSheet))
            .track
            .id,
        catalog.id,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed next album page retains content and retries from that page',
    (tester) async {
      final api = await pumpArtistApp(
        tester,
        configure: (api) {
          api.albumPages[0] = const CatalogPage(
            items: [SpotifyAlbum(id: 'first', name: 'First album')],
            nextOffset: 20,
          );
          api.albumPages[20] = const CatalogPage(
            items: [SpotifyAlbum(id: 'last', name: 'Last album')],
            offset: 20,
          );
          api.failingAlbumOffsets.add(20);
        },
      );
      AppRoutes.openArtistAlbums(
        tester.element(find.byType(MainShell)),
        artist,
      );
      await settle(tester);
      expect(find.text('First album'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      api.failingAlbumOffsets.clear();
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(find.text('First album'), findsOneWidget);
      expect(find.text('Last album'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initial catalog failures are retryable and empty results are explicit',
    (tester) async {
      final api = await pumpArtistApp(
        tester,
        configure: (api) => api.failingAlbumOffsets.add(0),
      );
      AppRoutes.openArtistAlbums(
        tester.element(find.byType(MainShell)),
        artist,
      );
      await settle(tester);
      expect(find.text('重试'), findsOneWidget);
      api.failingAlbumOffsets.clear();
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(find.text('暂无可显示的专辑。'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('songs retry continues past top tracks and empty catalog pages', (
    tester,
  ) async {
    const top = SpotifyTrack(id: 'top', name: 'Popular track');
    const deep = SpotifyTrack(id: 'deep', name: 'Deep catalog song');
    final api = await pumpArtistApp(
      tester,
      configure: (api) {
        api.topTracks = [top];
        api.songPages[0] = const ArtistTracksPage(
          items: [],
          nextCursor: ArtistTracksCursor(
            artistId: 'catalog-artist',
            nextAlbumOffset: 20,
          ),
        );
        api.songPages[20] = const ArtistTracksPage(items: [deep]);
        api.failingSongOffsets.add(20);
      },
    );
    AppRoutes.openArtistSongs(tester.element(find.byType(MainShell)), artist);
    await settle(tester);
    expect(find.text('Popular track'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    api.failingSongOffsets.clear();
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('Popular track'), findsOneWidget);
    expect(find.text('Deep catalog song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late catalog response after back navigation is ignored', (
    tester,
  ) async {
    final pending = Completer<CatalogPage<SpotifyAlbum>>();
    await pumpArtistApp(
      tester,
      configure: (api) => api.deferredAlbums[0] = pending,
    );
    AppRoutes.openArtistAlbums(tester.element(find.byType(MainShell)), artist);
    await settle(tester);
    await tester.tap(find.byKey(const Key('artist-catalog-back')));
    await settle(tester);
    pending.complete(
      const CatalogPage(
        items: [SpotifyAlbum(id: 'late', name: 'Late album')],
        nextOffset: 20,
      ),
    );
    await settle(tester);
    expect(find.text('Late album'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry callback after leaving a failed catalog is harmless', (
    tester,
  ) async {
    await pumpArtistApp(
      tester,
      configure: (api) => api.failingAlbumOffsets.add(0),
    );
    AppRoutes.openArtistAlbums(tester.element(find.byType(MainShell)), artist);
    await settle(tester);
    final retry = tester
        .widget<CollectionErrorPlaceholder>(
          find.byType(CollectionErrorPlaceholder),
        )
        .onRetry;
    await tester.tap(find.byKey(const Key('artist-catalog-back')));
    await settle(tester);
    retry();
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('song scrolling reaches releases beyond the first ten tracks', (
    tester,
  ) async {
    final songs = List.generate(
      24,
      (i) => SpotifyTrack(id: 'song-$i', name: 'Catalog song $i'),
    );
    await pumpArtistApp(
      tester,
      configure: (api) {
        api.topTracks = songs.take(2).toList();
        api.songPages[0] = ArtistTracksPage(
          items: songs.take(10).toList(),
          nextCursor: const ArtistTracksCursor(
            artistId: 'catalog-artist',
            nextAlbumOffset: 20,
          ),
        );
        api.songPages[20] = ArtistTracksPage(items: songs.skip(10).toList());
      },
    );
    AppRoutes.openArtistSongs(tester.element(find.byType(MainShell)), artist);
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Catalog song 23'),
      300,
      scrollable: find.descendant(
        of: find.byType(ArtistCatalogScreen),
        matching: find.byType(Scrollable),
      ),
    );
    await settle(tester);
    expect(find.text('Catalog song 23'), findsOneWidget);
    expect(
      tester
          .widget<TrackTile>(find.widgetWithText(TrackTile, 'Catalog song 23'))
          .contextQueue
          ?.length,
      24,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 768.0, 1024.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'catalog layouts fit ${width.toInt()}px at ${scale}x text scale',
        (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          const album = SpotifyAlbum(
            id: 'long',
            name: 'Exception (Soundtrack from the Netflix Anime Series)',
            releaseDate: '2022-10-14',
          );
          await pumpArtistApp(
            tester,
            size: Size(width, 1000),
            openOverview: false,
            configure: (api) {
              api.albumPages[0] = const CatalogPage(items: [album]);
              api.songPages[0] = const ArtistTracksPage(
                items: [
                  SpotifyTrack(
                    id: 'long-song',
                    name:
                        'Merry Christmas Mr. Lawrence (Version for Piano Trio)',
                    album: album,
                    explicit: true,
                  ),
                ],
              );
            },
          );
          AppRoutes.openArtistAlbums(
            tester.element(find.byType(MainShell)),
            artist,
          );
          await settle(tester);
          expect(find.text(album.name), findsOneWidget);
          expect(tester.takeException(), isNull);
          AppRoutes.openArtistSongs(
            tester.element(find.byType(MainShell)),
            artist,
          );
          await settle(tester);
          expect(find.byType(TrackTile), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
