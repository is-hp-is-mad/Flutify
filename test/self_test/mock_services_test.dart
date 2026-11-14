import 'dart:io';

import 'package:flutify_app/core/self_test/mock_audio.dart';
import 'package:flutify_app/core/self_test/mock_cover_server.dart';
import 'package:flutify_app/core/self_test/mock_services.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('MockCoverServer', () {
    test('serves valid deterministic PNG bytes over localhost', () async {
      final server = MockCoverServer();
      final port = await server.start();
      addTearDown(server.close);

      expect(port, greaterThan(0));
      final urlA = server.imageUrl('vinyl_a');
      final urlB = server.imageUrl('vinyl_b');
      expect(urlA, startsWith('http://127.0.0.1:$port/'));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<List<int>> fetchBytes(String url) async {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        return resp.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
      }

      final bytesA1 = await fetchBytes(urlA);
      final bytesA2 = await fetchBytes(urlA);
      final bytesB = await fetchBytes(urlB);

      expect(bytesA1.take(8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect(bytesA1, bytesA2);
      expect(bytesA1, isNot(equals(bytesB)));
    });
  });

  group('MockOfflineHttpClient', () {
    test('stubs GitHub releases as empty array and blocks external traffic', () async {
      final client = MockOfflineHttpClient();
      addTearDown(client.close);

      final ghResp = await client.get(
        Uri.parse('https://api.github.com/repos/example/flutify/releases'),
      );
      expect(ghResp.statusCode, 200);
      expect(ghResp.body, '[]');

      final extResp = await client.send(
        http.Request('GET', Uri.parse('https://api.spotify.com/v1/me')),
      );
      expect(extResp.statusCode, 503);
    });
  });

  group('MockAudioEngine', () {
    test('simulates play, seek, pause, and stop without audio driver', () async {
      final engine = MockAudioEngine();
      addTearDown(engine.dispose);

      await engine.playFile('mock://track_1');
      expect(engine.hasSource, isTrue);
      expect(engine.isPlaying, isTrue);
      expect(engine.duration, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(engine.position, greaterThan(Duration.zero));

      await engine.seek(const Duration(seconds: 45));
      expect(engine.position, const Duration(seconds: 45));

      await engine.pause();
      expect(engine.isPlaying, isFalse);

      await engine.stop();
      expect(engine.hasSource, isFalse);
      expect(engine.position, Duration.zero);
    });
  });

  group('MockBootstrap & MockSpotifyApiService', () {
    test('provides isolated session, catalog pagination, editable playlists & lyrics', () async {
      final bootstrap = await MockBootstrap.create();
      addTearDown(() async {
        bootstrap.audioEngine.dispose();
        await bootstrap.coverServer.close();
        if (await bootstrap.tempDir.exists()) {
          await bootstrap.tempDir.delete(recursive: true);
        }
      });

      final api = bootstrap.spotifyApiService;
      final catalog = bootstrap.catalog;

      expect(bootstrap.storageService.isLoggedIn, isTrue);
      expect(api.isConfigured, isTrue);
      expect(api.supportsConnect, isTrue);

      // Home feed chips
      final fullHome = await api.getHome();
      final musicHome = await api.getHome(facet: 'music-chip');
      final subHome = await api.getHome(facet: 'sub-electronic');
      final podcastHome = await api.getHome(facet: 'podcast-chip');
      expect(fullHome.chips, isNotEmpty);
      expect(musicHome.sections, isNotEmpty);
      expect(subHome.sections, isNotEmpty);
      expect(podcastHome.sections, isNotEmpty);

      // Deluxe 75-track album pagination
      final deluxe = catalog.albums[2];
      final page1 = await api.getAlbumTracksPage(deluxe, offset: 0, limit: 50);
      final page2 = await api.getAlbumTracksPage(deluxe, offset: 50, limit: 50);
      expect(page1.items.length, 50);
      expect(page1.hasMore, isTrue);
      expect(page2.items.length, 25);
      expect(page2.hasMore, isFalse);

      // Artist discography pagination
      final jayPage1 = await api.getArtistAlbumsPage(
        catalog.artists.first.id,
        offset: 0,
        limit: 20,
      );
      final jayPage2 = await api.getArtistAlbumsPage(
        catalog.artists.first.id,
        offset: 20,
        limit: 20,
      );
      expect(jayPage1.items.length, 20);
      expect(jayPage1.hasMore, isTrue);
      expect(jayPage2.items.length, greaterThanOrEqualTo(8));
      expect(jayPage2.hasMore, isFalse);

      // Editable account playlists
      final targetTrack = catalog.coreTracks.last;
      final editable = await api.library.fetchEditablePlaylists(targetTrack);
      expect(editable.length, 3);
      final targetPl = editable.first;
      final beforePl = await api.getPlaylist(targetPl.uri);
      await api.library.addTrackToPlaylist(targetPl.uri, targetTrack);
      final afterPl = await api.getPlaylist(targetPl.uri);
      expect(afterPl.totalTracks, beforePl.totalTracks + 1);

      // Bilingual synced lyrics & Connect devices
      final lyrics = await api.getLyrics(catalog.coreTracks.first.id);
      expect(lyrics.syncType, 'LINE_SYNCED');
      expect(lyrics.provider, LyricsProvider.spotify);
      expect(lyrics.lines, isNotEmpty);
      expect(lyrics.lines.any((line) => line.translation.isNotEmpty), isTrue);

      final devices = api.connect.current.devices;
      expect(devices.length, greaterThanOrEqualTo(2));
    });
  });
}
