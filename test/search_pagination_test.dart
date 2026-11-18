import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/catalog_page.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/controlled_search_api.dart';
import 'fixtures/search_pages.dart';

void main() {
  late ControlledSearchApi api;
  late SpotifyProvider provider;
  var disposed = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    api = ControlledSearchApi(storage.auth);
    provider = SpotifyProvider(api, storage.library);
    disposed = false;
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() {
    if (!disposed) provider.dispose();
  });

  Future<void> search(String query, SearchPage result) async {
    provider.performSearch(query);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    api.requests.last.result.complete(result);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'search continues past ten results and keeps server offsets after dedup',
    () async {
      await search('music', page(tracks: tracks(0, 10), nextTracks: 10));

      final more = provider.loadMoreSearch(SearchResultType.tracks);
      expect(api.requests.last.offset, 10);
      api.requests.last.result.complete(
        page(tracks: tracks(9, 21), trackOffset: 10, nextTracks: 22),
      );
      await more;
      expect(
        provider.searchTracks.map((t) => t.id),
        tracks(0, 21).map((t) => t.id),
      );

      final last = provider.loadMoreSearch(SearchResultType.tracks);
      expect(
        api.requests.last.offset,
        22,
        reason: 'deduped length is not the API offset',
      );
      api.requests.last.result.complete(
        page(tracks: tracks(21, 28), trackOffset: 22),
      );
      await last;
      expect(provider.searchTracks, hasLength(28));
      expect(provider.searchHasMore(SearchResultType.tracks), isFalse);
      final requestCount = api.requests.length;
      await provider.loadMoreSearch(SearchResultType.tracks);
      expect(api.requests, hasLength(requestCount));
    },
  );

  test(
    'types load independently and repeated clicks do not duplicate a page',
    () async {
      await search(
        'music',
        page(
          tracks: tracks(0, 2),
          nextTracks: 4,
          artists: const [SpotifyArtist(id: 'a', name: 'Artist A')],
          nextArtists: 7,
          playlists: const [SpotifyPlaylist(id: 'p', name: 'Playlist A')],
          nextPlaylists: 9,
        ),
      );
      final artistMore = provider.loadMoreSearch(SearchResultType.artists);
      expect(api.requests.last.type, 'artists');
      expect(api.requests.last.offset, 7);
      expect(provider.isLoadingMoreSearch(SearchResultType.artists), isTrue);
      final requestCount = api.requests.length;
      await provider.loadMoreSearch(SearchResultType.artists);
      expect(api.requests, hasLength(requestCount));

      final playlistMore = provider.loadMoreSearch(SearchResultType.playlists);
      expect(api.requests.last.type, 'playlists');
      expect(api.requests.last.offset, 9);
      api.requests.last.result.complete(
        page(
          playlists: const [SpotifyPlaylist(id: 'q', name: 'Playlist B')],
        ),
      );
      api.requests[1].result.complete(
        page(
          artists: const [SpotifyArtist(id: 'b', name: 'Artist B')],
        ),
      );
      await Future.wait([artistMore, playlistMore]);
      expect(provider.searchArtists.map((a) => a.id), ['a', 'b']);
      expect(provider.searchPlaylists.map((p) => p.id), ['p', 'q']);
      expect(provider.searchTracks, hasLength(2));
      expect(provider.searchHasMore(SearchResultType.tracks), isTrue);
    },
  );

  test('page failures retain results and retry the same offset', () async {
    await search('music', page(tracks: tracks(0, 10), nextTracks: 10));
    final failed = provider.loadMoreSearch(SearchResultType.tracks);
    api.requests.last.result.completeError(StateError('offline'));
    await failed;
    expect(provider.searchTracks, hasLength(10));
    expect(provider.isLoadingMoreSearch(SearchResultType.tracks), isFalse);
    expect(provider.searchPageError(SearchResultType.tracks), isNotNull);
    expect(provider.searchHasMore(SearchResultType.tracks), isTrue);

    final retry = provider.loadMoreSearch(SearchResultType.tracks);
    expect(api.requests.last.offset, 10);
    expect(provider.searchPageError(SearchResultType.tracks), isNull);
    api.requests.last.result.complete(
      page(tracks: tracks(10, 12), trackOffset: 10),
    );
    await retry;
    expect(provider.searchTracks, hasLength(12));
    expect(provider.searchHasMore(SearchResultType.tracks), isFalse);
  });

  test(
    'an empty parsed page with continuation can still load later results',
    () async {
      await search('music', page(nextTracks: 20));
      expect(provider.searchTracks, isEmpty);
      expect(provider.searchHasMore(SearchResultType.tracks), isTrue);
      final next = provider.loadMoreSearch(SearchResultType.tracks);
      expect(api.requests.last.offset, 20);
      api.requests.last.result.complete(
        page(tracks: tracks(20, 21), trackOffset: 20),
      );
      await next;
      expect(provider.searchTracks.single.id, 'track-20');
    },
  );

  test('new queries discard old pagination successes and failures', () async {
    await search(
      'old',
      page(tracks: tracks(0, 10), nextTracks: 10, nextArtists: 10),
    );
    final oldTracks = provider.loadMoreSearch(SearchResultType.tracks);
    final oldArtists = provider.loadMoreSearch(SearchResultType.artists);
    final trackRequest = api.requests[1];
    final artistRequest = api.requests[2];
    await search('new', page(tracks: tracks(100, 102), nextTracks: 20));
    trackRequest.result.complete(page(tracks: tracks(10, 20), nextTracks: 20));
    artistRequest.result.completeError(StateError('old failure'));
    await Future.wait([oldTracks, oldArtists]);
    expect(provider.searchTracks.map((t) => t.id), ['track-100', 'track-101']);
    expect(provider.searchPageError(SearchResultType.artists), isNull);
    expect(provider.isLoadingMoreSearch(SearchResultType.tracks), isFalse);
    expect(provider.searchHasMore(SearchResultType.tracks), isTrue);
  });

  test('clearing a query invalidates pending requests immediately', () async {
    provider.performSearch('old');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    provider.performSearch('');
    api.requests.single.result.complete(
      page(tracks: tracks(0, 20), nextTracks: 20),
    );
    await Future<void>.delayed(Duration.zero);
    expect(provider.searchQuery, isEmpty);
    expect(provider.searchTracks, isEmpty);
    expect(provider.isSearching, isFalse);
    expect(provider.searchHasMore(SearchResultType.tracks), isFalse);
  });

  test(
    'initial errors remain distinguishable from empty results and retry',
    () async {
      provider.performSearch('music');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      api.requests.single.result.completeError(StateError('offline'));
      await Future<void>.delayed(Duration.zero);
      expect(provider.searchError, isNotNull);
      expect(provider.isSearching, isFalse);
      final retry = provider.retrySearch();
      expect(provider.isSearching, isTrue);
      api.requests.last.result.complete(page(tracks: tracks(0, 1)));
      await retry;
      expect(provider.searchError, isNull);
      expect(provider.searchTracks, hasLength(1));
    },
  );

  test('in-flight pages do not notify after disposal', () async {
    await search('music', page(tracks: tracks(0, 10), nextTracks: 10));
    final pending = provider.loadMoreSearch(SearchResultType.tracks);
    provider.dispose();
    disposed = true;
    api.requests.last.result.complete(page(tracks: tracks(10, 20)));
    await pending;
    expect(provider.searchTracks, hasLength(10));
  });

  test(
    'initial retry cannot invalidate a successfully loaded continuation',
    () async {
      await search('music', page(tracks: tracks(0, 10), nextTracks: 10));
      final pending = provider.loadMoreSearch(SearchResultType.tracks);
      final retry = provider.retrySearch();
      expect(
        api.requests,
        hasLength(2),
        reason: 'only an initial failure can be retried',
      );
      await retry;
      api.requests.last.result.complete(page(tracks: tracks(10, 12)));
      await pending;
      expect(provider.searchTracks, hasLength(12));
      expect(provider.isLoadingMoreSearch(SearchResultType.tracks), isFalse);
    },
  );
}
