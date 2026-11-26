import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/home/home_item_actions.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_library_source.dart';
import '../fakes/fake_spotify_api_service.dart';

/// 主页封面上的播放键：歌单 / 已点赞的歌曲按用户在歌单页记下的排序播放，
/// 上下文带 reordered 标记（Connect 点歌据此带上整张曲目列表）。
void main() {
  SpotifyTrack track(String name, {int? daysAgo}) => SpotifyTrack(
    id: 'cover-$name',
    name: name,
    artists: [SpotifyArtist(id: 'a-$name', name: 'Artist $name')],
    album: SpotifyAlbum(id: 'al-$name', name: 'Album $name'),
    durationMs: 180000,
    addedAt: daysAgo == null
        ? null
        : DateTime.now().subtract(Duration(days: daysAgo)),
  );

  final tracks = [
    track('Charlie', daysAgo: 3),
    track('Alpha', daysAgo: 400),
    track('Bravo'),
  ];

  const playlist = SpotifyPlaylist(
    id: 'p1',
    name: 'P1',
    ownerName: 'Tester',
    totalTracks: 3,
  );

  const playlistItem = HomeItem(
    kind: HomeItemKind.playlist,
    uri: 'spotify:playlist:p1',
    title: 'P1',
    playlist: playlist,
  );

  const likedItem = HomeItem(
    kind: HomeItemKind.likedSongs,
    uri: 'spotify:collection:tracks',
    title: 'Liked',
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 起 App（歌单内容来自 fake），把 remotePlay 换成捕获器后点封面播放键，返回交给远程的参数。
  Future<(PlaybackContext, List<SpotifyTrack>, SpotifyTrack?)> play(
    WidgetTester tester, {
    required HomeItem item,
    Map<String, String> trackSorts = const {},
    Map<String, SpotifyPlaylist> playlists = const {},
    List<SpotifyTrack> likedTracks = const [],
  }) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ArtworkPalette.enabled = false;
    var prefs = AppPreferences.defaults;
    for (final e in trackSorts.entries) {
      prefs = prefs.withPlaylistTrackSort(e.key, e.value);
    }
    SharedPreferences.setMockInitialValues({'app_prefs': prefs.encode()});
    final storage = await StorageService.init();
    await tester.pumpWidget(
      FlutifyApp(
        storageService: storage,
        audioEngine: FakeAudioPlayerService(),
        emePlayer: EmePlayer(),
        spotifyApiService: FakeSpotifyApiService(
          storage.auth,
          playlists: playlists,
          librarySource: FakeLibrarySource(likedTracks: likedTracks),
        ),
      ),
    );
    await settle(tester);

    (PlaybackContext, List<SpotifyTrack>, SpotifyTrack?)? captured;
    tester.element(find.byType(MainShell)).read<PlaybackProvider>().remotePlay =
        (ctx, ts, start) async {
          captured = (ctx, ts, start);
          return true;
        };
    await HomeItemActions.play(
      tester.element(find.byType(MainShell)),
      item,
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
    return captured!;
  }

  SpotifyPlaylist withTracks(List<SpotifyTrack> ts) => SpotifyPlaylist(
    id: playlist.id,
    name: playlist.name,
    ownerName: playlist.ownerName,
    tracks: ts,
    totalTracks: ts.length,
  );

  testWidgets('cover play on a playlist uses the sort remembered for it', (
    tester,
  ) async {
    final (ctx, played, start) = await play(
      tester,
      item: playlistItem,
      trackSorts: {'p1': 'title:desc'},
      playlists: {'p1': withTracks(tracks)},
    );
    expect(played.map((t) => t.name), ['Charlie', 'Bravo', 'Alpha']);
    expect(ctx.reordered, isTrue);
    expect(ctx.uri, 'spotify:playlist:p1');
    expect(start, isNull);
  });

  testWidgets('no remembered sort: playlist plays in its original order', (
    tester,
  ) async {
    final (ctx, played, start) = await play(
      tester,
      item: playlistItem,
      playlists: {'p1': withTracks(tracks)},
    );
    expect(played.map((t) => t.name), ['Charlie', 'Alpha', 'Bravo']);
    expect(ctx.reordered, isFalse);
    expect(ctx.uri, 'spotify:playlist:p1');
    expect(start, isNull);
  });

  testWidgets('remembered addedAt sort falls back when tracks have no dates', (
    tester,
  ) async {
    final (ctx, played, start) = await play(
      tester,
      item: playlistItem,
      trackSorts: {'p1': 'addedAt'},
      playlists: {
        'p1': withTracks([
          track('Charlie'),
          track('Alpha'),
          track('Bravo'),
        ]),
      },
    );
    expect(played.map((t) => t.name), ['Charlie', 'Alpha', 'Bravo']);
    expect(ctx.reordered, isFalse);
    expect(ctx.uri, 'spotify:playlist:p1');
    expect(start, isNull);
  });

  testWidgets('liked songs cover play uses the sort remembered for it', (
    tester,
  ) async {
    final (ctx, played, start) = await play(
      tester,
      item: likedItem,
      trackSorts: {LibraryProvider.likedSongsId: 'title'},
      likedTracks: tracks,
    );
    expect(played.map((t) => t.name), ['Alpha', 'Bravo', 'Charlie']);
    expect(ctx.reordered, isTrue);
    expect(ctx.uri, LibraryProvider.likedSongsUri);
    expect(start, isNull);
  });
}
