import 'dart:convert';

import 'package:flutify_app/models/editable_playlist.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/services/library/desktop_library_source.dart';
import 'package:flutify_app/services/library/library_source.dart';
import 'package:flutify_app/services/pathfinder/desktop_data_source.dart';
import 'package:flutify_app/services/pathfinder/pathfinder_client.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_library_source.dart';
import 'fixtures/sample_catalog.dart';

Map<String, Object?> _playlist(String id, String name, {bool curates = false}) => {
  'curates': curates,
  'pinned': false,
  'item': {
    '__typename': 'PlaylistResponseWrapper',
    'data': {
      '__typename': 'Playlist',
      'uri': 'spotify:playlist:$id',
      'name': name,
      'images': {
        'items': [
          {
            'sources': [
              {'url': 'https://img/$id', 'width': 300, 'height': 300},
            ],
          },
        ],
      },
    },
  },
};

Map<String, Object?> _page(List<Object?> items) => {
  'data': {
    'me': {
      'editablePlaylists': {'items': items, 'totalCount': items.length},
    },
  },
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('账号歌单读写（issue #67，与 open.spotify.com 同一组操作）', () {
    test('列出可编辑歌单：展开文件夹，跳过「已点赞的歌曲」，带上是否已包含', () async {
      final requests = <Map<String, dynamic>>[];
      final source = DesktopDataSource(
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          final folder = (body['variables'] as Map)['folderUri'];
          final items = folder == null
              ? [
                  {
                    'curates': false,
                    'pinned': true,
                    'item': {
                      '__typename': 'LibraryPseudoPlaylistResponseWrapper',
                      'data': {
                        '__typename': 'PseudoPlaylist',
                        'uri': 'spotify:collection:tracks',
                        'name': '已点赞的歌曲',
                      },
                    },
                  },
                  _playlist('aaa', '通勤', curates: true),
                  {
                    'curates': false,
                    'pinned': false,
                    'item': {
                      '__typename': 'LibraryFolderResponseWrapper',
                      'data': {
                        '__typename': 'Folder',
                        'uri': 'spotify:user:me:folder:f1',
                        'name': '文件夹',
                      },
                    },
                  },
                ]
              : [_playlist('bbb', '文件夹里的')];
          return http.Response.bytes(
            utf8.encode(jsonEncode(_page(items))),
            200,
          );
        }),
        headers: () async => const {},
      );

      final playlists = await source.editablePlaylists('spotify:track:t1');

      expect(playlists.map((p) => p.uri), [
        'spotify:playlist:aaa',
        'spotify:playlist:bbb',
      ]);
      expect(playlists.first.name, '通勤');
      expect(playlists.first.containsTrack, isTrue);
      expect(playlists.first.coverUrl, 'https://img/aaa');
      expect(playlists.last.containsTrack, isFalse);
      expect(requests, hasLength(2));
      expect(requests.first['operationName'], 'editablePlaylists');
      expect((requests.first['variables'] as Map)['uris'], ['spotify:track:t1']);
      expect(
        (requests.last['variables'] as Map)['folderUri'],
        'spotify:user:me:folder:f1',
      );
    });

    test('添加：发出 addToPlaylist，加在歌单末尾', () async {
      late Map<String, dynamic> sent;
      final source = DesktopDataSource(
        MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"data":{"addItemsToPlaylist":{}}}', 200);
        }),
        headers: () async => const {},
      );

      await source.addToPlaylist('spotify:playlist:aaa', ['spotify:track:t1']);

      expect(sent['operationName'], 'addToPlaylist');
      expect(sent['variables'], {
        'playlistUri': 'spotify:playlist:aaa',
        'playlistItemUris': ['spotify:track:t1'],
        'newPosition': {'moveType': 'BOTTOM_OF_PLAYLIST', 'fromUid': null},
        'interactionId': null,
      });
    });

    test('添加：服务端报错时抛异常，即使响应里带着 data', () async {
      final source = DesktopDataSource(
        MockClient(
          (_) async => http.Response(
            '{"data":{"addItemsToPlaylist":null},'
            '"errors":[{"message":"Forbidden"}]}',
            200,
          ),
        ),
        headers: () async => const {},
      );

      await expectLater(
        source.addToPlaylist('spotify:playlist:aaa', ['spotify:track:t1']),
        throwsA(isA<PathfinderException>()),
      );
    });
  });

  group('歌单进出音乐库（rootlist/changes，与 open.spotify.com 一致）', () {
    late List<http.Request> requests;
    late DesktopLibrarySource source;

    setUp(() {
      requests = [];
      final client = MockClient((r) async {
        requests.add(r);
        if (r.url.path == '/playlist/v2/playlist') {
          return http.Response(jsonEncode({'uri': 'spotify:playlist:new1'}), 200);
        }
        if (r.url.path.endsWith('/pathfinder/v2/query') || r.url.path.contains('pathfinder')) {
          return http.Response(jsonEncode({'data': {}}), 200);
        }
        return http.Response('{}', 200);
      });
      source = DesktopLibrarySource(
        client: client,
        headers: () async => const {},
        data: DesktopDataSource(client, headers: () async => const {}),
        username: () => 'user1',
        signedIn: () => true,
      );
    });

    test('收藏：ADD 到 rootlist 最前；取消收藏：REM', () async {
      const p = SpotifyPlaylist(id: 'abc', name: 'x', uri: 'spotify:playlist:abc');
      await source.setPlaylistSaved(p, true);
      await source.setPlaylistSaved(p, false);

      expect(requests.map((r) => '${r.method} ${r.url.path}'), [
        'POST /playlist/v2/user/user1/rootlist/changes',
        'POST /playlist/v2/user/user1/rootlist/changes',
      ]);
      final add = (jsonDecode(requests[0].body)['deltas'] as List).single['ops'].single as Map;
      expect(add['kind'], 'ADD');
      expect(add['add']['addFirst'], isTrue);
      expect((add['add']['items'] as List).single['uri'], 'spotify:playlist:abc');
      final rem = (jsonDecode(requests[1].body)['deltas'] as List).single['ops'].single as Map;
      expect(rem['kind'], 'REM');
      expect(rem['rem'], {
        'itemsAsKey': true,
        'items': [
          {'uri': 'spotify:playlist:abc'},
        ],
      });
    });

    test('新建歌单：POST /playlist 设名称，再加进 rootlist，再写曲目', () async {
      final uri = await source.createPlaylist('本机歌单', [SampleCatalog.track4]);
      expect(uri, 'spotify:playlist:new1');
      expect(requests[0].url.path, '/playlist/v2/playlist');
      final create = jsonDecode(requests[0].body) as Map;
      final op = (create['ops'] as List).single as Map;
      expect(op['kind'], 'UPDATE_LIST_ATTRIBUTES');
      expect(op['updateListAttributes']['newAttributes']['values']['name'], '本机歌单');
      expect(requests[1].url.path, '/playlist/v2/user/user1/rootlist/changes');
      expect(
        ((jsonDecode(requests[1].body)['deltas'] as List).single['ops'].single as Map)['add']['items']
            .single['uri'],
        'spotify:playlist:new1',
      );
      expect(requests.length, 3, reason: '第三个请求写入曲目');
    });
  });

  group('LibraryProvider 账号歌单', () {
    const playlist = EditablePlaylist(
      uri: 'spotify:playlist:aaa',
      name: '通勤',
    );

    test('添加成功后写入账号，媒体库里的曲目数加一', () async {
      final source = FakeLibrarySource(
        playlists: const [
          SpotifyPlaylist(id: 'aaa', name: '通勤', totalTracks: 3),
        ],
      )..editable = const [playlist];
      final library = LibraryProvider((await StorageService.init()).library,
        source: source,
      );
      await library.refresh();

      expect(
        (await library.editablePlaylistsFor(SampleCatalog.track4)).single.uri,
        playlist.uri,
      );
      expect(
        await library.addTrackToAccountPlaylist(playlist, SampleCatalog.track4),
        isTrue,
      );
      expect(source.writes, ['add:spotify:playlist:aaa:${SampleCatalog.track4.id}']);
      expect(library.findPlaylist('aaa')?.totalTracks, 4);
    });

    test('读取或写入失败时不抛异常：列表为空 / 返回 false', () async {
      final source = FakeLibrarySource()
        ..editableError = StateError('offline')
        ..writeError = StateError('offline');
      final library = LibraryProvider((await StorageService.init()).library,
        source: source,
      );

      expect(await library.editablePlaylistsFor(SampleCatalog.track4), isEmpty);
      expect(
        await library.addTrackToAccountPlaylist(playlist, SampleCatalog.track4),
        isFalse,
      );
      expect(source.writes, isEmpty);
    });

    test('收藏 / 取消收藏别人的歌单同步到账号音乐库', () async {
      const other = SpotifyPlaylist(id: 'bbb', name: '别人的歌单');
      final source = FakeLibrarySource();
      final library = LibraryProvider((await StorageService.init()).library,
        source: source,
      );
      await library.refresh();

      library.togglePlaylistSaved(other);
      await Future<void>.delayed(Duration.zero);
      expect(library.isPlaylistSaved('bbb'), isTrue);
      expect(source.writes, ['savePlaylist:bbb']);

      // 账号里有了这张歌单后取消收藏：发 REM
      source.playlists = const [other];
      await library.refresh();
      library.togglePlaylistSaved(other);
      await Future<void>.delayed(Duration.zero);
      expect(library.isPlaylistSaved('bbb'), isFalse);
      expect(source.writes, ['savePlaylist:bbb', 'unsavePlaylist:bbb']);
    });

    test('只在本机的歌单不发 REM；本机新建歌单的收藏状态不同步', () async {
      final source = FakeLibrarySource();
      final library = LibraryProvider((await StorageService.init()).library,
        source: source,
      );
      await library.refresh();
      source.writeError = StateError('offline');
      library.togglePlaylistSaved(const SpotifyPlaylist(id: 'ccc', name: '旧收藏'));
      await Future<void>.delayed(Duration.zero);
      source.writeError = null;
      library.clearSyncError();

      library.togglePlaylistSaved(const SpotifyPlaylist(id: 'ccc', name: '旧收藏'));
      final own = library.createPlaylist('我的');
      library.togglePlaylistSaved(own);
      await Future<void>.delayed(Duration.zero);
      expect(source.writes, isEmpty);
    });

    test('未同步歌单：读到账号列表后才判断；同步后从列表里消失', () async {
      final source = FakeLibrarySource(
        playlists: const [SpotifyPlaylist(id: 'aaa', name: '通勤')],
      );
      final library = LibraryProvider((await StorageService.init()).library,
        source: source,
      );
      library.upsertLocalPlaylists([
        SpotifyPlaylist(id: 'bak', name: '备份歌单', tracks: [SampleCatalog.track4]),
      ]);
      final own = library.createPlaylist('本机歌单');
      library.addTrackToPlaylist(own.id, SampleCatalog.track4);
      expect(library.unsyncedPlaylists, isEmpty, reason: '还没读到账号歌单列表');

      await library.refresh();
      expect(library.unsyncedPlaylists.map((p) => p.name).toSet(), {'备份歌单', '本机歌单'});

      // 别人的歌单：加入音乐库，本机那份保留
      await library.syncPlaylistToAccount(
        library.unsyncedPlaylists.firstWhere((p) => p.id == 'bak'),
      );
      // 本机新建：在账号里新建同名歌单并写入曲目，本机那份换成账号歌单
      await library.syncPlaylistToAccount(
        library.unsyncedPlaylists.firstWhere((p) => p.id == own.id),
      );
      expect(source.writes, [
        'savePlaylist:bak',
        'create:本机歌单:${SampleCatalog.track4.id}',
      ]);
      expect(library.unsyncedPlaylists, isEmpty);
      expect(library.findPlaylist(own.id), isNull);
      expect(library.findPlaylist('created1')?.name, '本机歌单');
    });

    test('别人的歌单加不进音乐库且本机有曲目时，新建同名副本', () async {
      final source = FakeLibrarySource()
        ..playlistSaveError = const LibrarySourceException('forbidden', 403);
      final library = LibraryProvider((await StorageService.init()).library,
        source: source,
      );
      library.upsertLocalPlaylists([
        SpotifyPlaylist(id: 'priv', name: '私密歌单', tracks: [SampleCatalog.track4]),
      ]);
      await library.refresh();

      await library.syncPlaylistToAccount(library.unsyncedPlaylists.single);
      expect(source.writes, ['create:私密歌单:${SampleCatalog.track4.id}']);
      expect(library.unsyncedPlaylists, isEmpty);
    });

    test('未登录时不发请求', () async {
      final source = FakeLibrarySource(isSignedIn: false)
        ..editable = const [playlist];
      final library = LibraryProvider((await StorageService.init()).library,
        source: source,
      );

      expect(await library.editablePlaylistsFor(SampleCatalog.track4), isEmpty);
      expect(
        await library.addTrackToAccountPlaylist(playlist, SampleCatalog.track4),
        isFalse,
      );
    });
  });
}
