import 'dart:convert';

import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/services/library/library_source.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_library_source.dart';
import 'fixtures/sample_catalog.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('本机行为（无账号来源）', () {
    test('liked songs persist across provider instances, newest first', () async {
      final storage = await StorageService.init();
      final library = LibraryProvider(storage.library);
      const track = SampleCatalog.track4;

      library.toggleLike(track);
      expect(library.likedTracks.first.id, track.id);

      final reloaded = LibraryProvider(storage.library);
      expect(reloaded.isLiked(track.id), isTrue);
      expect(reloaded.likedTracks.first.id, track.id);
      expect(reloaded.likedTracks.first.album?.coverUrl, track.album?.coverUrl);
    });

    test('初始状态是空的：没有任何示例歌单 / 艺人 / 专辑', () async {
      final library = LibraryProvider((await StorageService.init()).library);

      expect(library.likedTracks, isEmpty);
      expect(library.playlists, isEmpty);
      expect(library.artists, isEmpty);
      expect(library.albums, isEmpty);
    });

    test('lists keep identity until they change (safe for context.select)', () async {
      final library = LibraryProvider((await StorageService.init()).library);
      final before = library.playlists;
      final likedBefore = library.likedSongsPlaylist;

      library.toggleFollowArtist(SampleCatalog.artistA);
      expect(identical(library.playlists, before), isTrue);
      expect(identical(library.likedSongsPlaylist, likedBefore), isTrue);

      library.createPlaylist('Road Trip');
      expect(identical(library.playlists, before), isFalse);
    });

    test('own playlists accept tracks once and adopt the first cover', () async {
      final library = LibraryProvider((await StorageService.init()).library);
      final created = library.createPlaylist('Focus');
      const track = SampleCatalog.track2;

      expect(library.addTrackToPlaylist(created.id, track), isTrue);
      expect(library.addTrackToPlaylist(created.id, track), isFalse);

      final updated = library.findPlaylist(created.id)!;
      expect(updated.tracks.single.id, track.id);
      expect(updated.coverUrl, track.coverUrl);
      expect(library.ownPlaylists.map((p) => p.id), contains(created.id));
    });
  });

  group('账号媒体库', () {
    test('未登录：媒体库为空，不发任何读取请求', () async {
      final source = FakeLibrarySource(isSignedIn: false, likedTracks: [SampleCatalog.track1]);
      final library = LibraryProvider((await StorageService.init()).library, source: source);

      await library.refresh();

      expect(library.likedTracks, isEmpty);
      expect(library.playlists, isEmpty);
      expect(source.likedFetches, 0);
    });

    test('已登录：refresh 读取四类数据并标记加载完成', () async {
      final source = FakeLibrarySource(
        likedTracks: [SampleCatalog.track1, SampleCatalog.track2],
        playlists: [SampleCatalog.remotePlaylist],
        albums: [SampleCatalog.albumA],
        artists: [SampleCatalog.artistA],
      );
      final library = LibraryProvider((await StorageService.init()).library, source: source);

      final pending = library.refresh();
      expect(library.isLoading, isTrue);
      await pending;

      expect(library.isLoading, isFalse);
      expect(library.loadError, isNull);
      expect(library.likedTracks.map((t) => t.id), [SampleCatalog.track1.id, SampleCatalog.track2.id]);
      expect(library.isLiked(SampleCatalog.track1.id), isTrue);
      expect(library.playlists.map((p) => p.id), [SampleCatalog.remotePlaylist.id]);
      expect(library.isAlbumSaved(SampleCatalog.albumA.id), isTrue);
      expect(library.isFollowing(SampleCatalog.artistA.id), isTrue);
    });

    test('whenLoaded：没在读取时立即完成；读取中等到这次读取结束', () async {
      final source = FakeLibrarySource(likedTracks: [SampleCatalog.track1]);
      final library = LibraryProvider((await StorageService.init()).library, source: source);

      var idleDone = false;
      await library.whenLoaded().then((_) => idleDone = true);
      expect(idleDone, isTrue);

      final pending = library.refresh();
      var loaded = false;
      final waiting = library.whenLoaded().then((_) => loaded = true);
      expect(library.isLoading, isTrue);
      await waiting;
      expect(loaded, isTrue);
      expect(library.isLoading, isFalse);
      expect(library.likedTracks.map((t) => t.id), [SampleCatalog.track1.id]);
      await pending;
    });

    test('whenLoaded：读取失败也会结束等待，缓存照常保留', () async {
      final source = FakeLibrarySource(
        likedTracks: [SampleCatalog.track1],
      )..playlistsError = const LibrarySourceException('歌单读取失败', 500);
      final library = LibraryProvider((await StorageService.init()).library, source: source);

      final pending = library.refresh();
      await library.whenLoaded();
      expect(library.isLoading, isFalse);
      expect(library.loadError, contains('歌单读取失败'));
      await pending;
    });

    test('某一类读取失败：记录原因，其他类照常显示', () async {
      final source = FakeLibrarySource(
        likedTracks: [SampleCatalog.track1],
        artists: [SampleCatalog.artistA],
      )..playlistsError = const LibrarySourceException('歌单读取失败', 500);
      final library = LibraryProvider((await StorageService.init()).library, source: source);

      await library.refresh();

      expect(library.loadError, contains('歌单读取失败'));
      expect(library.likedTracks, hasLength(1));
      expect(library.artists, hasLength(1));
      expect(library.playlists, isEmpty);
    });

    test('点赞 / 收藏 / 关注乐观更新，并同步到账号', () async {
      final source = FakeLibrarySource();
      final library = LibraryProvider((await StorageService.init()).library, source: source);
      await library.refresh();

      library.toggleLike(SampleCatalog.track1);
      library.toggleAlbumSaved(SampleCatalog.albumA);
      library.toggleFollowArtist(SampleCatalog.artistB);
      library.toggleLike(SampleCatalog.track1);
      await Future<void>.delayed(Duration.zero);

      expect(source.writes, [
        'like:${SampleCatalog.track1.id}',
        'save:${SampleCatalog.albumA.id}',
        'follow:${SampleCatalog.artistB.id}',
        'unlike:${SampleCatalog.track1.id}',
      ]);
      expect(library.isLiked(SampleCatalog.track1.id), isFalse);
      expect(library.syncError, isNull);
    });

    test('同步失败：本地修改保留，错误记入 syncError 且可清除', () async {
      final source = FakeLibrarySource()..writeError = const LibrarySourceException('写入被拒绝', 403);
      final library = LibraryProvider((await StorageService.init()).library, source: source);
      await library.refresh();

      library.toggleLike(SampleCatalog.track1);
      await Future<void>.delayed(Duration.zero);

      expect(library.isLiked(SampleCatalog.track1.id), isTrue);
      expect(library.syncError, contains('写入被拒绝'));

      library.clearSyncError();
      expect(library.syncError, isNull);
    });

    test('登出后清空账号数据，但保留本机歌单', () async {
      final source = FakeLibrarySource(likedTracks: [SampleCatalog.track1]);
      final library = LibraryProvider((await StorageService.init()).library, source: source);
      await library.refresh();
      final local = library.createPlaylist('Mine');

      source.isSignedIn = false;
      await library.refresh();

      expect(library.likedTracks, isEmpty);
      expect(library.playlists.map((p) => p.id), [local.id]);
    });

    test('账号缓存按账号隔离：换号后不会短暂显示上一个账号的数据', () async {
      final storage = await StorageService.init();
      final first = FakeLibrarySource(accountId: 'alice', likedTracks: [SampleCatalog.track1]);
      final libraryA = LibraryProvider(storage.library, source: first);
      await libraryA.refresh();
      expect(libraryA.likedTracks, hasLength(1));

      // 同一账号重新打开：先用缓存
      final again = LibraryProvider(storage.library, source: FakeLibrarySource(accountId: 'alice'));
      expect(again.likedTracks, hasLength(1));

      // 换成另一个账号：缓存作废
      final other = LibraryProvider(storage.library, source: FakeLibrarySource(accountId: 'bob'));
      expect(other.likedTracks, isEmpty);
    });

    test('未登录时启动不会读到旧缓存', () async {
      final storage = await StorageService.init();
      final signedIn = LibraryProvider(storage.library, source: FakeLibrarySource(likedTracks: [SampleCatalog.track1]));
      await signedIn.refresh();

      final signedOut = LibraryProvider(storage.library, source: FakeLibrarySource(isSignedIn: false));
      expect(signedOut.likedTracks, isEmpty);
    });
  });

  group('旧版缓存迁移', () {
    test('丢弃旧版（含示例数据）缓存，只保留用户自建的 local_ 歌单', () async {
      const legacySample = SpotifyPlaylist(id: 'sample_top_hits', name: '旧示例歌单');
      const userMade = SpotifyPlaylist(id: 'local_123', name: '我的歌单');
      SharedPreferences.setMockInitialValues({
        // 没有 schema 标记 = 旧版写入的缓存（StringList，每项一个 JSON）
        LibraryCacheStore.keyLibraryPlaylists: [jsonEncode(legacySample.toJson()), jsonEncode(userMade.toJson())],
        LibraryCacheStore.keyLibraryLikedTracks: [jsonEncode(SampleCatalog.track1.toJson())],
      });

      final library = LibraryProvider((await StorageService.init()).library);

      expect(library.likedTracks, isEmpty);
      expect(library.playlists.map((p) => p.id), ['local_123']);
    });
  });
}
