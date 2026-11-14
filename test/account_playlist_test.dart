import 'dart:convert';

import 'package:flutify_app/models/editable_playlist.dart';
import 'package:flutify_app/models/playlist.dart';
import 'package:flutify_app/providers/library_provider.dart';
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
      final library = LibraryProvider(
        await StorageService.init(),
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
      final library = LibraryProvider(
        await StorageService.init(),
        source: source,
      );

      expect(await library.editablePlaylistsFor(SampleCatalog.track4), isEmpty);
      expect(
        await library.addTrackToAccountPlaylist(playlist, SampleCatalog.track4),
        isFalse,
      );
      expect(source.writes, isEmpty);
    });

    test('未登录时不发请求', () async {
      final source = FakeLibrarySource(isSignedIn: false)
        ..editable = const [playlist];
      final library = LibraryProvider(
        await StorageService.init(),
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
