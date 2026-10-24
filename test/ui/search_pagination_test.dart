import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/detail/artist_detail_screen.dart';
import 'package:flutify_app/ui/screens/search/search_screen.dart';
import 'package:flutify_app/ui/widgets/filter_pill.dart';
import 'package:flutify_app/ui/widgets/track_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/controlled_search_api.dart';
import '../fakes/fake_audio_player_service.dart';
import '../fixtures/search_pages.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('songs can continue past ten results at width $width', (
      tester,
    ) async {
      final api = await pumpSearch(tester, width);
      api.requests.single.result.complete(
        page(tracks: tracks(0, 10), nextTracks: 10),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterPill, 'Songs'));
      await tester.pump();

      final more = find.byKey(const ValueKey('search-load-more-tracks'));
      final scrollable = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(more, 300, scrollable: scrollable);
      await tester.tap(more);
      await tester.pump();
      expect(api.requests.last.offset, 10);
      expect(
        find.byKey(const ValueKey('search-loading-tracks')),
        findsOneWidget,
      );
      api.requests.last.result.complete(
        page(tracks: tracks(10, 13), trackOffset: 10),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Track 12'),
        200,
        scrollable: scrollable,
      );
      expect(find.text('Track 12'), findsOneWidget);
      expect(more, findsNothing);
      final last = tester.widget<TrackTile>(
        find.ancestor(
          of: find.text('Track 12'),
          matching: find.byType(TrackTile),
        ),
      );
      expect(last.contextQueue, hasLength(13));
      expect(last.playbackContext?.name, 'music');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty parsed results retain continuation for each filter', (
    tester,
  ) async {
    final api = await pumpSearch(tester, 390);
    api.requests.single.result.complete(
      page(nextTracks: 20, nextArtists: 20, nextPlaylists: 20),
    );
    await tester.pump();
    for (final (label, type) in [
      ('Songs', 'tracks'),
      ('Artists', 'artists'),
      ('Playlists', 'playlists'),
    ]) {
      await tester.tap(find.widgetWithText(FilterPill, label));
      await tester.pump();
      final more = find.byKey(ValueKey('search-load-more-$type'));
      expect(more, findsOneWidget);
      await tester.tap(more);
      await tester.pump();
      expect(api.requests.last.type, type);
      expect(api.requests.last.offset, 20);
      api.requests.last.result.complete(switch (type) {
        'tracks' => page(
          tracks: const [SpotifyTrack(id: 'track', name: 'Found song')],
        ),
        'artists' => page(
          artists: const [SpotifyArtist(id: 'artist', name: 'Found artist')],
        ),
        _ => page(
          playlists: const [
            SpotifyPlaylist(id: 'playlist', name: 'Found playlist'),
          ],
        ),
      });
      await tester.pump();
      expect(more, findsNothing);
      expect(
        find.text(
          'Found ${type == 'tracks'
              ? 'song'
              : type == 'artists'
              ? 'artist'
              : 'playlist'}',
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('paging error keeps existing results and offers retry', (
    tester,
  ) async {
    final api = await pumpSearch(tester, 390);
    api.requests.single.result.complete(
      page(
        artists: const [SpotifyArtist(id: 'artist', name: 'Existing artist')],
        nextArtists: 10,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-load-more-artists')));
    await tester.pump();
    api.requests.last.result.completeError(StateError('offline'));
    await tester.pump();
    expect(find.text('Existing artist'), findsOneWidget);
    await tester.tap(find.widgetWithText(M3EButton, 'Retry'));
    await tester.pump();
    expect(api.requests.last.offset, 10);
    api.requests.last.result.complete(
      page(
        artists: const [SpotifyArtist(id: 'next', name: 'Next artist')],
      ),
    );
    await tester.pump();
    expect(find.text('Next artist'), findsOneWidget);
    expect(find.text('Existing artist'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('initial error is not presented as no results and can retry', (
    tester,
  ) async {
    final api = await pumpSearch(tester, 390);
    api.requests.single.result.completeError(StateError('offline'));
    await tester.pump();
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search_off_rounded), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    api.requests.last.result.complete(
      page(
        artists: const [SpotifyArtist(id: 'artist', name: 'Recovered artist')],
      ),
    );
    await tester.pump();
    expect(find.text('Recovered artist'), findsOneWidget);
  });

  testWidgets('signed-out search offers sign in instead of a network retry', (
    tester,
  ) async {
    final api = await pumpSearch(tester, 390, signedIn: false);
    api.requests.single.result.completeError(SpotifyDataException.notSignedIn);
    await tester.pump();
    expect(find.text("Sign in to see what's here"), findsOneWidget);
    final signIn = find.widgetWithText(M3EButton, 'Sign in');
    expect(signIn, findsOneWidget);
    expect(tester.widget<M3EButton>(signIn).onPressed, isNotNull);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  // 返回搜索页时路由会把焦点还给上次聚焦的输入框，若输入框仍持有焦点，输入法会再次弹出。
  testWidgets('opening a result does not bring the keyboard back on return', (
    tester,
  ) async {
    final api = await pumpSearch(tester, 390);
    api.requests.single.result.complete(
      page(
        artists: const [SpotifyArtist(id: 'artist', name: 'Found artist')],
      ),
    );
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField));
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('Found artist'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ArtistDetailScreen), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ArtistDetailScreen), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('the keyboard search action dismisses the keyboard', (
    tester,
  ) async {
    final api = await pumpSearch(tester, 390);
    api.requests.single.result.complete(page(tracks: tracks(0, 1)));
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField));
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('choosing a recent search dismisses the keyboard', (
    tester,
  ) async {
    final api = await pumpSearch(
      tester,
      390,
      query: '',
      recent: const ['radiohead'],
    );
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField));
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('radiohead'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.requests.single.query, 'radiohead');
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('playing a song result dismisses the keyboard', (tester) async {
    final api = await pumpSearch(tester, 390);
    api.requests.single.result.complete(page(tracks: tracks(0, 1)));
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField));
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('Track 0'));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);

    // 播放后打开其他页面（如全屏播放器）再返回，输入法也不会再弹出
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.testTextInput.isVisible, isFalse);
  });
}

Future<ControlledSearchApi> pumpSearch(
  WidgetTester tester,
  double width, {
  bool signedIn = true,
  String query = 'music',
  List<String> recent = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  for (final item in recent) {
    await storage.addRecentSearch(item);
  }
  final api = ControlledSearchApi(storage, signedIn: signedIn);
  final spotify = SpotifyProvider(api, storage);
  final audio = FakeAudioPlayerService();
  final playback = PlaybackProvider(audio, storage);
  final library = LibraryProvider(storage);
  final controller = TextEditingController(text: query);
  addTearDown(() {
    spotify.dispose();
    playback.dispose();
    library.dispose();
    controller.dispose();
    audio.dispose();
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<SpotifyApiService>.value(value: api),
        ChangeNotifierProvider.value(value: spotify),
        ChangeNotifierProvider.value(value: playback),
        ChangeNotifierProvider.value(value: library),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocale.supportedLocales,
        localizationsDelegates: AppLocale.delegates,
        home: SearchScreen(controller: controller),
      ),
    ),
  );
  if (query.isNotEmpty) spotify.performSearch(query);
  await tester.pump(const Duration(milliseconds: 350));
  return api;
}
