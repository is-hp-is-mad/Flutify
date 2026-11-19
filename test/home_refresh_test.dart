import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/controlled_home_api.dart';
import 'fixtures/sample_home.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledHomeApi api;
  late SpotifyProvider provider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    api = ControlledHomeApi(storage.auth);
    provider = SpotifyProvider(api, storage.library);
    api.requests.single.result.complete(SampleHome.feed);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() => provider.dispose());

  test(
    'refresh keeps facet, coalesces requests and preserves data on failure',
    () async {
      final select = provider.selectHomeFacet('music');
      api.requests.last.result.complete(SampleHome.feed);
      await select;
      final refresh = provider.refreshHome();
      expect(provider.refreshHome(), same(refresh));
      expect(api.requests, hasLength(3));
      expect(api.requests.last.facet, 'music');
      expect(api.userRequests, 1);
      expect(provider.isLoadingFeed, isTrue);
      expect(provider.home, same(SampleHome.feed));
      api.requests.last.result.completeError(StateError('offline'));
      await refresh;
      expect(provider.home, same(SampleHome.feed));
      expect(provider.homeError, contains('offline'));
      expect(provider.isLoadingFeed, isFalse);
      final retry = provider.refreshHome();
      api.requests.last.result.complete(HomeFeed.empty);
      await retry;
      expect(provider.home, same(HomeFeed.empty));
      expect(provider.homeError, isNull);
    },
  );

  test(
    'late refresh success or failure cannot overwrite a new facet',
    () async {
      for (final fails in [false, true]) {
        final refresh = provider.refreshHome();
        final old = api.requests.last.result;
        final change = provider.selectHomeFacet(fails ? 'podcast' : 'music');
        api.requests.last.result.complete(SampleHome.feed);
        await change;
        if (fails) {
          old.completeError(StateError('stale failure'));
        } else {
          old.complete(HomeFeed.empty);
        }
        await refresh;
        expect(provider.home, same(SampleHome.feed));
        expect(provider.homeError, isNull);
        expect(provider.isLoadingFeed, isFalse);
      }
    },
  );

  test(
    'initial load error arriving after refresh cannot overwrite it',
    () async {
      final initial = provider.loadInitialData();
      final old = api.requests.last.result;
      final refresh = provider.refreshHome();
      api.requests.last.result.complete(SampleHome.feed);
      await refresh;
      old.completeError(StateError('old login response'));
      await initial;
      expect(provider.home, same(SampleHome.feed));
      expect(provider.homeError, isNull);
      expect(provider.isLoadingFeed, isFalse);
    },
  );

  test('refresh completion after dispose does not notify', () async {
    final disposed = SpotifyProvider(api, (await StorageService.init()).library);
    api.requests.last.result.complete(HomeFeed.empty);
    await Future<void>.delayed(Duration.zero);
    final refresh = disposed.refreshHome();
    var notifications = 0;
    disposed.addListener(() => notifications++);
    disposed.dispose();
    api.requests.last.result.complete(HomeFeed.empty);
    await refresh;
    expect(notifications, 0);
  });
}
