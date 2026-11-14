import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/core/utils/pinyin_sort.dart';
import 'package:flutify_app/models/shortcut_settings.dart';
import 'package:flutify_app/services/auth/proto_codec.dart';
import 'package:flutify_app/services/library/desktop_library_source.dart';
import 'package:flutify_app/services/library/web_api_library_source.dart';
import 'package:flutify_app/services/pathfinder/desktop_data_source.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_integration.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('全局快捷键的系统键码（issue #48）', () {
    test('默认键位都有系统键码', () {
      for (final combo in const ShortcutSettings().effectiveGlobal.values) {
        expect(GlobalHotkeys.systemKeyOf(combo), isNotNull);
      }
    });

    test('系统没有键码的按键不交给插件注册', () {
      // 物理键不在映射表里（Windows 插件拿到 null 键码会让进程直接退出）
      final unknownPhysical = KeyCombo(
        LogicalKeyboardKey.keyA.keyId,
        physicalId: 0x000700ff,
        control: true,
      );
      expect(GlobalHotkeys.systemKeyOf(unknownPhysical), isNull);
      // 没记下物理键、逻辑键也反查不到
      final unknownLogical = KeyCombo(0x00100000fff, control: true);
      expect(GlobalHotkeys.systemKeyOf(unknownLogical), isNull);
    }, skip: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux));
  });

  test('拼音排序：缓存排序键后结果不变', () {
    final titles = ['周杰伦', 'Adele', '陈奕迅', 'beyond', '阿信', '123'];
    final first = sortByPinyin(titles, (t) => t);
    expect(sortByPinyin(titles, (t) => t), first);
    expect(first, ['123', 'Adele', '阿信', 'beyond', '陈奕迅', '周杰伦']);
  });

  test('音频缓存淘汰：超额时先删最久未用的，连同响度旁路文件', () async {
    final root = await Directory.systemTemp.createTemp('flutify_trim_');
    addTearDown(() => root.delete(recursive: true));
    final audio = Directory('${root.path}${Platform.pathSeparator}audio')
      ..createSync();
    File make(String name, int bytes, int ageMinutes) {
      final file = File('${audio.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(List.filled(bytes, 0));
      file.setLastModifiedSync(
        DateTime.now().subtract(Duration(minutes: ageMinutes)),
      );
      return file;
    }

    final oldest = make('a.ogg', 10, 30);
    final sidecar = AudioNormalization.sidecarFor(oldest)
      ..writeAsBytesSync([1, 2, 3]);
    final middle = make('b.ogg', 10, 20);
    final newest = make('c.ogg', 10, 10);
    final partial = make('d.ogg.part', 100, 40);

    final loader = TrackAudioLoader(
      accessToken: () async => '',
      cacheDirectory: root.path,
    );
    loader.maxCacheBytes = 20;
    await loader.trimCache();

    expect(oldest.existsSync(), isFalse);
    expect(sidecar.existsSync(), isFalse);
    expect(middle.existsSync(), isTrue);
    expect(newest.existsSync(), isTrue);
    expect(partial.existsSync(), isTrue, reason: '下载中的文件不参与淘汰');
  });

  group('已点赞歌曲分页不受 500 首截断（issue #68）', () {
    Uint8List encodeCollectionPage(List<(String uri, int addedAt)> items, String nextToken) {
      final w = ProtoWriter();
      for (final (uri, addedAt) in items) {
        w.message(
          1,
          ProtoWriter()
            ..string(1, uri)
            ..int32(2, addedAt),
        );
      }
      if (nextToken.isNotEmpty) w.string(2, nextToken);
      return w.toBytes();
    }

    test('DesktopLibrarySource 默认读取超过 500 首的全部已点赞歌曲', () async {
      const total = 1350;
      const pageSize = 300;
      final client = MockClient((request) async {
        if (request.url.path == '/collection/v2/paging') {
          var token = '';
          ProtoReader(request.bodyBytes).forEach((f) {
            if (f.number == 3 && f.wireType == 2) token = f.asString;
          });
          final start = token.isEmpty ? 0 : int.parse(token);
          final end = (start + pageSize).clamp(0, total);
          final items = [
            for (var i = start; i < end; i++)
              ('spotify:track:track${i.toString().padLeft(5, '0')}', 1700000000 + total - i),
          ];
          final next = end < total ? '$end' : '';
          return http.Response.bytes(encodeCollectionPage(items, next), 200);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final uris = List<String>.from((body['variables'] as Map)['uris'] as List);
        return http.Response(
          jsonEncode({
            'data': {
              'tracks': [
                for (final uri in uris)
                  {
                    '__typename': 'TrackResponseWrapper',
                    'data': {
                      'uri': uri,
                      'name': 'Track ${uri.split(':').last}',
                      'duration': {'totalMilliseconds': 180000},
                      'artists': {
                        'items': [
                          {
                            'uri': 'spotify:artist:a1',
                            'profile': {'name': 'Artist'},
                          },
                        ],
                      },
                      'albumOfTrack': {'uri': 'spotify:album:al1', 'name': 'Album'},
                    },
                  },
              ],
            },
          }),
          200,
        );
      });

      final data = DesktopDataSource(
        client,
        headers: () async => const {},
      );
      final source = DesktopLibrarySource(
        client: client,
        headers: () async => const {},
        data: data,
        username: () => 'user1',
        signedIn: () => true,
      );

      final tracks = await source.fetchLikedTracks();
      expect(tracks.length, total);
      expect(tracks.first.id, 'track00000');
      expect(tracks.last.id, 'track01349');
    });

    test('WebApiLibrarySource 默认 maxPages 允许超过 500 首', () {
      final source = WebApiLibrarySource(
        client: MockClient((_) async => http.Response('{}', 200)),
        headers: () async => const {},
        baseUrl: () => 'https://api.spotify.com/v1',
        username: () => 'user1',
        signedIn: () => true,
      );
      expect(source.maxPages, greaterThanOrEqualTo(300));
    });
  });
}
