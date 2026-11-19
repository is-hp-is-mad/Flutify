import 'dart:convert';

import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/catalog_page.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _track(int id, {String artist = 'artist'}) => {
  'id': '$id',
  'name': 'Track $id',
  'artists': [
    {'id': artist, 'name': artist},
  ],
};

Map<String, dynamic> _album(int id) => {
  'id': '$id',
  'name': 'Album $id',
  'release_date': '2025-01-01',
  'images': [
    {'url': 'https://example.test/$id.jpg'},
  ],
  'artists': [
    {'id': 'artist', 'name': 'Artist'},
  ],
};

http.Response _json(Object value) => http.Response(jsonEncode(value), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'sp_access_token': 'test-token'});
    storage = await StorageService.init();
  });

  test('Web search paginates individual types after the initial ten', () async {
    final offsets = <int>[];
    final api = SpotifyApiService(storage.auth,
      MockClient((request) async {
        final query = request.url.queryParameters;
        expect(query['type'], 'track');
        expect(query['q'], 'a & b');
        final offset = int.parse(query['offset']!);
        offsets.add(offset);
        return _json({
          'tracks': {
            'total': 13,
            'offset': offset,
            'items': [
              for (var i = offset; i < offset + 10 && i < 13; i++)
                if (i == 4) null else _track(i),
            ],
            'next': offset == 0
                ? 'https://api.spotify.com/v1/search?offset=10'
                : null,
          },
        });
      }),
    );
    final first = await api.searchPage(' a & b ', limit: 10, type: 'tracks');
    expect(first.tracks.items, hasLength(9));
    expect(first.tracks.nextOffset, 10);
    final last = await api.searchPage(
      'a & b',
      offset: first.tracks.nextOffset!,
      limit: 10,
      type: 'tracks',
    );
    expect(offsets, [0, 10]);
    expect(last.tracks.items.last.id, '12');
    expect(last.tracks.hasMore, isFalse);
  });

  test(
    'Web discography includes compilation and appearance groups and follows short pages',
    () async {
      final api = SpotifyApiService(storage.auth,
        MockClient((request) async {
          expect(
            request.url.queryParameters['include_groups'],
            'album,single,compilation,appears_on',
          );
          expect(request.url.queryParameters['limit'], '10');
          final offset = int.parse(request.url.queryParameters['offset']!);
          return _json({
            'total': 22,
            'items': [
              for (var i = offset; i < offset + 3 && i < 22; i++) _album(i),
            ],
          });
        }),
      );
      final first = await api.getArtistAlbumsPage('artist');
      expect(first.nextOffset, 3);
      final second = await api.getArtistAlbumsPage('artist', offset: 3);
      expect(second.items.first.id, '3');
      expect(second.nextOffset, 6);
    },
  );

  test(
    'Web search respects its ten-item limit and maximum supported offset',
    () async {
      final api = SpotifyApiService(storage.auth,
        MockClient((request) async {
          expect(request.url.queryParameters['limit'], '10');
          expect(request.url.queryParameters['offset'], '1000');
          return _json({
            'tracks': {
              'total': 2000,
              'items': [for (var i = 1000; i < 1010; i++) _track(i)],
            },
          });
        }),
      );
      final page = await api.searchPage('query', offset: 1000, type: 'tracks');
      expect(page.tracks.items, hasLength(10));
      expect(page.tracks.hasMore, isFalse);
    },
  );

  test(
    'search tolerates omitted optional sections but rejects an absent result',
    () async {
      var missing = false;
      final api = SpotifyApiService(storage.auth,
        MockClient(
          (_) async => _json(
            missing
                ? {}
                : {
                    'tracks': {
                      'items': [_track(1)],
                    },
                  },
          ),
        ),
      );
      final page = await api.searchPage('query');
      expect(page.tracks.items.single.id, '1');
      expect(page.artists.items, isEmpty);
      expect(page.playlists.items, isEmpty);
      missing = true;
      await expectLater(
        api.searchPage('query'),
        throwsA(isA<SpotifyDataException>()),
      );
    },
  );

  test(
    'missing song credits are retained only for an artist-owned non-compilation',
    () async {
      final api = SpotifyApiService(storage.auth,
        MockClient(
          (_) async => _json({
            'total': 2,
            'items': [
              {'id': 'unknown', 'name': 'Unknown credit'},
              _track(1),
            ],
          }),
        ),
      );
      final artist = SpotifyAlbum.fromJson(_album(1)).artists.single;
      for (final album in [
        SpotifyAlbum(
          id: 'compilation',
          name: 'Compilation',
          albumType: 'compilation',
          artists: [artist],
        ),
        const SpotifyAlbum(id: 'appearance', name: 'Someone else album'),
      ]) {
        final page = await api.getArtistTracksPage(
          'artist',
          cursor: ArtistTracksCursor(
            artistId: 'artist',
            pendingAlbums: [album],
            nextAlbumOffset: null,
          ),
        );
        expect(page.items.map((track) => track.id), ['1']);
      }
      final own = await api.getArtistTracksPage(
        'artist',
        cursor: ArtistTracksCursor(
          artistId: 'artist',
          pendingAlbums: [
            SpotifyAlbum(id: 'own', name: 'Own album', artists: [artist]),
          ],
          nextAlbumOffset: null,
        ),
      );
      expect(own.items.map((track) => track.id), ['unknown', '1']);
    },
  );

  test(
    'song catalog performs bounded requests and exhausts albums over fifty tracks',
    () async {
      final requests = <String>[];
      final api = SpotifyApiService(storage.auth,
        MockClient((request) async {
          requests.add(request.url.path);
          final offset = int.parse(request.url.queryParameters['offset']!);
          if (request.url.path.endsWith('/artists/artist/albums')) {
            return _json({
              'total': 2,
              'items': [_album(0), _album(1)],
            });
          }
          if (request.url.path.endsWith('/albums/0/tracks')) {
            return _json({
              'total': 51,
              'items': [
                for (var i = offset; i < offset + 50 && i < 51; i++)
                  _track(i, artist: i == 2 ? 'someone-else' : 'artist'),
              ],
            });
          }
          expect(request.url.path, endsWith('/albums/1/tracks'));
          return _json({
            'total': 1,
            'items': [_track(51)],
          });
        }),
      );
      final first = await api.getArtistTracksPage('artist');
      expect(
        requests,
        hasLength(2),
        reason: 'one discography and one track page only',
      );
      expect(first.items, hasLength(49));
      expect(first.items.map((t) => t.id), isNot(contains('2')));
      expect(first.items.first.album?.releaseYear, '2025');
      expect(first.items.first.coverUrl, 'https://example.test/0.jpg');
      final second = await api.getArtistTracksPage(
        'artist',
        cursor: first.nextCursor,
      );
      expect(second.items.single.id, '50');
      expect(requests, hasLength(3));
      final last = await api.getArtistTracksPage(
        'artist',
        cursor: second.nextCursor,
      );
      expect(last.items.single.id, '51');
      expect(last.hasMore, isFalse);
      expect(requests, hasLength(4));
    },
  );

  test(
    'song catalog reaches the next discography page rather than stopping at first batch',
    () async {
      final offsets = <int>[];
      final api = SpotifyApiService(storage.auth,
        MockClient((request) async {
          if (request.url.path.endsWith('/artists/artist/albums')) {
            final offset = int.parse(request.url.queryParameters['offset']!);
            offsets.add(offset);
            return _json({
              'total': 2,
              'items': [_album(offset)],
            });
          }
          final albumId = int.parse(request.url.pathSegments[2]);
          return _json({
            'total': 1,
            'items': [_track(albumId)],
          });
        }),
      );
      final first = await api.getArtistTracksPage('artist');
      final last = await api.getArtistTracksPage(
        'artist',
        cursor: first.nextCursor,
      );
      expect(offsets, [0, 1]);
      expect(last.items.single.id, '1');
      expect(last.hasMore, isFalse);
    },
  );

  test('song catalog failure preserves the cursor for retry', () async {
    var attempts = 0;
    final api = SpotifyApiService(storage.auth,
      MockClient((request) async {
        attempts++;
        if (attempts == 1) return http.Response('', 503);
        return _json({
          'total': 1,
          'items': [_track(1)],
        });
      }),
    );
    const cursor = ArtistTracksCursor(
      artistId: 'artist',
      pendingAlbums: [SpotifyAlbum(id: 'album', name: 'Album')],
      nextAlbumOffset: null,
    );
    await expectLater(
      api.getArtistTracksPage('artist', cursor: cursor),
      throwsA(isA<SpotifyDataException>()),
    );
    expect(cursor.pendingAlbums.single.id, 'album');
    expect(cursor.trackOffset, 0);
    final retry = await api.getArtistTracksPage('artist', cursor: cursor);
    expect(retry.items.single.id, '1');
    expect(retry.hasMore, isFalse);
  });

  test(
    'pagination failures and malformed pages are not empty catalogues',
    () async {
      var fail = true;
      final api = SpotifyApiService(storage.auth,
        MockClient((_) async {
          if (fail) return http.Response('secret body must not surface', 500);
          return _json({'wrong': []});
        }),
      );
      await expectLater(
        api.getArtistAlbumsPage('artist'),
        throwsA(
          isA<SpotifyDataException>().having(
            (e) => e.statusCode,
            'HTTP status',
            500,
          ),
        ),
      );
      fail = false;
      await expectLater(
        api.getArtistAlbumsPage('artist'),
        throwsA(isA<SpotifyDataException>()),
      );
    },
  );
}
