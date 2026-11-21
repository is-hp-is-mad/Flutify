import 'dart:async';
import 'dart:typed_data';

import 'package:flutify_app/core/theme/artist_artwork_scheme.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/artist_overview.dart';
import 'package:flutify_app/models/image.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/apple_music/apple_music_artist_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/album_detail_screen.dart';
import 'package:flutify_app/ui/screens/detail/artist_detail_screen.dart';
import 'package:flutify_app/ui/screens/detail/widgets/artist_hero.dart';
import 'package:flutify_app/ui/widgets/player_controls.dart';
import 'package:flutify_app/ui/widgets/cover_image.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/widgets/track_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

const _artist = SpotifyArtist(
  id: '6qqNVTkY8uBg9cP3Jd7DAH',
  name: 'Billie Eilish',
  uri: 'spotify:artist:6qqNVTkY8uBg9cP3Jd7DAH',
  images: [SpotifyImage(url: 'https://i.scdn.co/avatar')],
  genres: ['Alt-Pop', 'Indie'],
  followers: 1200,
);

class _OverviewApi extends FakeSpotifyApiService {
  _OverviewApi(super.storage);

  ArtistOverview overview = const ArtistOverview();
  List<SpotifyTrack> topTracks = const [];
  AppleMusicArtistService? artistMedia;

  @override
  AppleMusicArtistService get appleMusicArtist =>
      artistMedia ?? super.appleMusicArtist;

  @override
  bool get isConfigured => true;

  @override
  Future<SpotifyArtist> getArtist(String id) async => _artist;

  @override
  Future<List<SpotifyTrack>> getArtistTopTracks(String id) async => topTracks;

  @override
  Future<List<SpotifyAlbum>> getArtistAlbums(String id) async => const [];

  @override
  Future<ArtistOverview> getArtistOverview(String id) async => overview;
}

class _ArtistMedia extends AppleMusicArtistService {
  _ArtistMedia({required this.media, this.bytes, this.pendingVideo})
    : super(MockClient((_) async => throw StateError('Unexpected request')));

  final AppleMusicArtistMedia media;
  final Uint8List? bytes;
  final Completer<Uint8List?>? pendingVideo;

  @override
  Future<AppleMusicArtistMedia?> find(
    String name, {
    required String language,
    required bool wide,
  }) async => media;

  @override
  Future<Uint8List?> video(AppleMusicArtistMedia media) async =>
      pendingVideo == null ? bytes : await pendingVideo!.future;
}

const _amPhoto = AppleMusicArtistMedia(
  artworkTemplate: 'https://am.test/artist/{w}x{h}{c}.{f}',
  bgColor: 'ff0000',
);
const _amVideo = AppleMusicArtistMedia(
  artworkTemplate: 'https://am.test/artist/{w}x{h}{c}.{f}',
  bgColor: 'ff0000',
  videoUrl: 'https://am.test/artist.m3u8',
);

Future<_OverviewApi> _pump(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  void Function(_OverviewApi)? configure,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  ArtworkPalette.enabled = false;
  addTearDown(ArtworkPalette.clear);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  final api = _OverviewApi(storage.auth);
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
  await _settle(tester);
  AppRoutes.openArtist(tester.element(find.byType(MainShell)), _artist);
  await _settle(tester);
  return api;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get _scrollable => find
    .descendant(
      of: find.byType(ArtistDetailScreen),
      matching: find.byType(Scrollable),
    )
    .first;

List<SpotifyTrack> _tracks(int n) => [
  for (var i = 0; i < n; i++)
    SpotifyTrack(id: 't$i', name: 'Song $i', artists: const [_artist]),
];

void main() {
  testWidgets(
    'AM photo without a video never replaces the Spotify artist photo',
    (tester) async {
      await _pump(
        tester,
        configure: (api) {
          api.artistMedia = _ArtistMedia(media: _amPhoto);
          api.overview = const ArtistOverview(
            headerImages: [SpotifyImage(url: 'https://i.scdn.co/header')],
          );
        },
      );
      final hero = tester.widget<ArtistHero>(find.byType(ArtistHero));
      expect(hero.imageUrl, 'https://i.scdn.co/header');
      expect(hero.video, isNull);

      await tester.tap(find.byKey(const Key('artist-info-button')));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('artist-info-sheet')),
          matching: find.byWidgetPredicate(
            (w) => w is CoverImage && w.url == 'https://i.scdn.co/header',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending and failed AM video both keep the Spotify photo and palette',
    (tester) async {
      final pending = Completer<Uint8List?>();
      ArtworkPalette.debugArtistOverrides['https://i.scdn.co/avatar'] =
          const Color(0xFF001122);
      await _pump(
        tester,
        configure: (api) {
          api.artistMedia = _ArtistMedia(
            media: _amVideo,
            pendingVideo: pending,
          );
        },
      );
      ArtistHero hero() => tester.widget<ArtistHero>(find.byType(ArtistHero));
      expect(hero().imageUrl, 'https://i.scdn.co/avatar');
      expect(hero().video, isNull);
      expect(hero().scheme.sourceColor, const Color(0xFF001122));

      pending.complete(null);
      await _settle(tester);
      expect(hero().imageUrl, 'https://i.scdn.co/avatar');
      expect(hero().video, isNull);
      expect(hero().scheme.sourceColor, const Color(0xFF001122));
    },
  );

  testWidgets(
    'available AM video uses Spotify photo for its placeholder and fallback',
    (tester) async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      await _pump(
        tester,
        configure: (api) {
          api.artistMedia = _ArtistMedia(media: _amVideo, bytes: bytes);
        },
      );
      final hero = tester.widget<ArtistHero>(find.byType(ArtistHero));
      expect(hero.video, same(bytes));
      expect(hero.imageUrl, 'https://i.scdn.co/avatar');
    },
  );

  testWidgets(
    'phone header centers name and [info, play, star] buttons with top-right shuffle+share capsule',
    (tester) async {
      await _pump(tester, configure: (api) => api.topTracks = _tracks(2));

      final hero = tester.getRect(
        find
            .descendant(
              of: find.byType(ArtistHero),
              matching: find.byType(ClipRect),
            )
            .first,
      );
      expect(hero.width, 390);
      expect(hero.height, 390 + 96);

      // Artist name is horizontally centered.
      final name = tester.getRect(
        find
            .descendant(
              of: find.byType(ArtistHero),
              matching: find.text('Billie Eilish'),
            )
            .first,
      );
      expect(name.center.dx, closeTo(hero.center.dx, 2));

      // Three circular buttons: [ (i) 48dp ] --24dp-- [ (▶) 72dp ] --24dp-- [ (☆) 48dp ]
      final infoRect = tester.getRect(
        find.byKey(const Key('artist-info-button')),
      );
      final playRect = tester.getRect(
        find.byKey(const Key('artist-hero-play-button')),
      );
      final starRect = tester.getRect(
        find.byKey(const Key('artist-follow-star-button')),
      );
      expect(infoRect.size, const Size(48, 48));
      expect(playRect.size, const Size(72, 72));
      expect(starRect.size, const Size(48, 48));
      expect(playRect.center.dx, closeTo(hero.center.dx, 1));
      expect(playRect.left - infoRect.right, closeTo(24, 1));
      expect(starRect.left - playRect.right, closeTo(24, 1));

      // Top-left back button and top-right shuffle + share capsule.
      expect(find.byKey(const Key('artist-back-button')), findsOneWidget);
      final topActions = find.byKey(const Key('artist-top-actions'));
      expect(topActions, findsOneWidget);
      expect(
        find.descendant(of: topActions, matching: find.byType(ShuffleButton)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: topActions,
          matching: find.byKey(const Key('artist-share-button')),
        ),
        findsOneWidget,
      );
      expect(tester.getRect(topActions).right, closeTo(390 - 16, 1));

      // Follower count is moved off the main page into the Artist Info sheet.
      expect(find.text('1,200 位粉丝'), findsNothing);

      // Tapping the star button toggles artist follow state.
      final library = tester
          .element(find.byType(MainShell))
          .read<LibraryProvider>();
      expect(library.isFollowing(_artist.id), isFalse);
      await tester.tap(find.byKey(const Key('artist-follow-star-button')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(library.isFollowing(_artist.id), isTrue);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'info button morphs nonlinearly into Artist Info sheet with monthly listeners and followers',
    (tester) async {
      await _pump(
        tester,
        configure: (api) {
          api.overview = const ArtistOverview(
            monthlyListeners: 15852288,
            biography: 'Grammy-winning singer-songwriter.',
          );
        },
      );

      // Monthly listeners are hidden on the main page.
      expect(find.textContaining('月听众'), findsNothing);

      final infoBtn = find.byKey(const Key('artist-info-button'));
      final anchorRect = tester.getRect(infoBtn);
      await tester.tap(infoBtn);

      // Mid-flight frame: nonlinear spring morph expands from the (i) button toward full sheet.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final midSheet = tester.getRect(
        find.byKey(const Key('artist-info-sheet')),
      );
      expect(midSheet.width, greaterThan(anchorRect.width));
      expect(midSheet.width, lessThan(370));

      await _settle(tester);
      final finalSheet = tester.getRect(
        find.byKey(const Key('artist-info-sheet')),
      );
      expect(finalSheet.width, closeTo(370, 1));
      expect(find.textContaining('月听众'), findsOneWidget);
      expect(find.text('1,200 位粉丝'), findsOneWidget);
      expect(find.text('Alt-Pop'), findsOneWidget);
      expect(find.text('Grammy-winning singer-songwriter.'), findsOneWidget);

      // Closing collapses back smoothly.
      await tester.tap(find.byKey(const Key('artist-info-close-button')));
      await _settle(tester);
      expect(find.byKey(const Key('artist-info-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'artist page background replicates Apple Music 7.0 artwork scheme',
    (tester) async {
      ArtworkPalette.debugArtistOverrides['https://i.scdn.co/avatar'] =
          const Color(0xFFB2AFAD);

      await _pump(tester);

      final expected = ArtistArtworkScheme.from(
        const Color(0xFFB2AFAD),
      ).backgroundColor;
      final scaffold = tester.widget<Scaffold>(
        find.descendant(
          of: find.byType(ArtistDetailScreen),
          matching: find.byType(Scaffold),
        ),
      );
      expect(scaffold.backgroundColor, expected);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'artist media blends into the page without a frosted image overlay',
    (tester) async {
      await _pump(tester);

      final blurred = find.descendant(
        of: find.byType(ArtistHero),
        matching: find.byType(ImageFiltered),
      );
      expect(
        blurred,
        findsNothing,
        reason:
            'A static blurred image must never cover the clear photo or video.',
      );

      final mirrors = tester
          .widgetList<Transform>(
            find.descendant(of: blurred, matching: find.byType(Transform)),
          )
          .where((t) => t.transform.storage[5] == -2)
          .toList();
      expect(mirrors, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide header uses the Apple Music 2.28:1 ratio plus bottom blend',
    (tester) async {
      await _pump(tester, size: const Size(1800, 1000));
      final hero = tester.getRect(
        find
            .descendant(
              of: find.byType(ArtistHero),
              matching: find.byType(ClipRect),
            )
            .first,
      );
      expect(hero.width, greaterThanOrEqualTo(600));
      expect(
        hero.height,
        closeTo(hero.width / ArtistHero.wideAspectRatio + 92, 1.5),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('overview sections render Spotify data in Apple Music order', (
    tester,
  ) async {
    await _pump(
      tester,
      configure: (api) {
        api.topTracks = _tracks(9);
        api.overview = const ArtistOverview(
          headerImages: [SpotifyImage(url: 'https://i.scdn.co/header')],
          biography: 'Singer-songwriter from Los Angeles.',
          monthlyListeners: 15852288,
          latestRelease: SpotifyAlbum(
            id: 'latest',
            name: 'Latest Single',
            albumType: 'single',
            releaseDate: '2026-10-31',
            totalTracks: 1,
          ),
          albums: [
            SpotifyAlbum(id: 'al1', name: 'First Album', releaseDate: '2019'),
          ],
          singles: [
            SpotifyAlbum(
              id: 'sg1',
              name: 'A Single',
              albumType: 'single',
              releaseDate: '2025',
            ),
          ],
          relatedArtists: [SpotifyArtist(id: 'r1', name: 'FINNEAS')],
        );
      },
    );

    expect(
      tester.widget<ArtistHero>(find.byType(ArtistHero)).imageUrl,
      'https://i.scdn.co/header',
    );
    expect(find.byKey(const Key('artist-latest-release-card')), findsOneWidget);
    expect(find.text('Latest Single'), findsOneWidget);

    // Top songs: four rows per page, paged sideways.
    expect(
      find.descendant(
        of: find.byType(PageView),
        matching: find.byType(TrackTile),
      ),
      findsWidgets,
    );
    final first = tester.getRect(find.text('Song 0'));
    final fifth = tester.getRect(find.text('Song 4'));
    expect(fifth.left, greaterThan(first.left + 200));
    expect((fifth.top - first.top).abs(), lessThan(1));

    // Latest release opens the album page.
    await tester.tap(find.text('Latest Single'));
    await _settle(tester);
    expect(find.byType(AlbumDetailScreen), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await _settle(tester);

    for (final label in ['专辑', '单曲和 EP', '粉丝也喜欢', '关于']) {
      await tester.scrollUntilVisible(
        find.text(label),
        200,
        scrollable: _scrollable,
      );
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('First Album'), findsOneWidget);
    expect(find.text('FINNEAS'), findsOneWidget);
    expect(find.text('Singer-songwriter from Los Angeles.'), findsOneWidget);
    expect(find.byKey(const Key('artist-albums-link')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turning the Apple Music header off keeps the Spotify image', (
    tester,
  ) async {
    await _pump(tester);
    final prefs = tester
        .element(find.byType(MainShell))
        .read<PreferencesProvider>();
    prefs.update(prefs.prefs.copyWith(appleMusicArtistMedia: false));
    await _settle(tester);
    expect(prefs.prefs.appleMusicArtistMedia, isFalse);
    expect(
      tester.widget<ArtistHero>(find.byType(ArtistHero)).imageUrl,
      'https://i.scdn.co/avatar',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling collapses the header into the title bar', (
    tester,
  ) async {
    await _pump(
      tester,
      configure: (api) {
        api.topTracks = _tracks(4);
        api.overview = const ArtistOverview(
          biography: 'Long enough page to scroll past the header.',
          albums: [SpotifyAlbum(id: 'al1', name: 'First Album')],
          singles: [SpotifyAlbum(id: 'sg1', name: 'A Single')],
          relatedArtists: [SpotifyArtist(id: 'r1', name: 'FINNEAS')],
        );
      },
    );
    await tester.drag(_scrollable, const Offset(0, -600));
    await _settle(tester);
    final hero = tester.getRect(
      find
          .descendant(
            of: find.byType(ArtistHero),
            matching: find.byType(ClipRect),
          )
          .first,
    );
    expect(hero.height, lessThan(120));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'artist media fade reaches the page color before the photo ends',
    (tester) async {
      await _pump(tester);
      final hero = find.byType(ArtistHero);
      final fade = find.descendant(
        of: hero,
        matching: find.byKey(const Key('artist-hero-media-fade')),
      );
      final rect = tester.getRect(fade);
      expect(rect.bottom, closeTo(390, 0.1));
      expect(rect.height, closeTo(249.6, 0.1));
      final decoration =
          tester.widget<DecoratedBox>(fade).decoration as BoxDecoration;
      final gradient = decoration.gradient! as LinearGradient;
      final scheme = tester.widget<ArtistHero>(hero).scheme;
      expect(gradient.colors.first.a, 0);
      expect(gradient.colors.last, scheme.backgroundColor);
      expect(tester.takeException(), isNull);
    },
  );
}
