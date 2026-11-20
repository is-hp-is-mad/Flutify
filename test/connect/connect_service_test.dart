import 'dart:async';
import 'dart:convert';

import 'package:flutify_app/models/connect_cluster.dart';
import 'package:flutify_app/services/connect/connect_service.dart';
import 'package:flutify_app/services/connect/dealer_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fakes/fake_dealer.dart';

const _deviceId = '0123456789abcdef0123456789abcdef01234567';
const _observerId = 'hobs_$_deviceId';
const _clusterUri = 'hm://connect-state/v1/cluster';

Map<String, Object?> _cluster({
  String active = 'dev-1',
  int devices = 2,
  int serverMs = 1700000000000,
}) => {
  'active_device_id': active,
  'server_timestamp_ms': '$serverMs',
  'devices': {
    for (var i = 1; i <= devices; i++)
      'dev-$i': {
        'device_id': 'dev-$i',
        'name': 'Synthetic $i',
        'device_type': 'SPEAKER',
        'capabilities': {'volume_steps': 16},
      },
  },
};

/// 一套完整的假环境：假 dealer 服务端 + 路由 spclient 请求的 MockClient。
class _Harness {
  final server = FakeDealerServer();
  final requests = <http.Request>[];

  /// 注册（PUT）要失败的次数。
  int failRegisterTimes = 0;

  /// 注销（DELETE）是否返回 500。
  bool failDelete = false;

  /// 控制命令（POST / 音量 PUT）的响应状态码。
  int commandStatus = 200;
  Future<http.Response> Function(http.Request)? command;
  Future<http.Response> Function()? registration;
  Map<String, Object?> registerBody = _cluster();

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    if (request.url.host == 'apresolve.test') {
      return http.Response(
        jsonEncode({
          'dealer': ['dealer.test:443'],
          'spclient': ['spclient.test:443'],
        }),
        200,
      );
    }
    if (request.method == 'PUT' &&
        request.url.path.startsWith('/connect-state/v1/devices/')) {
      if (registration != null) return registration!();
      if (failRegisterTimes > 0) {
        failRegisterTimes--;
        return http.Response('err', 500);
      }
      // 实测响应不带 content-type
      return http.Response.bytes(utf8.encode(jsonEncode(registerBody)), 200);
    }
    if (request.method == 'DELETE')
      return http.Response('', failDelete ? 500 : 204);
    return command?.call(request) ?? http.Response('', commandStatus);
  });

  late final ConnectService service = () {
    Future<Map<String, String>> headers() async => {
      'Authorization': 'Bearer test-token',
    };
    return ConnectService(
      client: client,
      headers: headers,
      deviceId: () => _deviceId,
      registerRetryDelay: const Duration(milliseconds: 10),
      confirmationTimeout: const Duration(milliseconds: 20),
      dealer: DealerClient(
        client: client,
        headers: headers,
        connector: server.connect,
        apresolve: Uri.parse('https://apresolve.test/'),
        initialBackoff: const Duration(milliseconds: 10),
        maxBackoff: const Duration(milliseconds: 50),
      ),
    );
  }();

  Iterable<http.Request> where(String method, [String? pathPart]) =>
      requests.where(
        (r) =>
            r.method == method &&
            (pathPart == null || r.url.path.contains(pathPart)),
      );
}

void main() {
  late _Harness h;

  setUp(() => h = _Harness());
  tearDown(() => h.service.dispose());

  group('start / stop', () {
    test('start：连接 → 用连接 id 注册观察者 → 发出 cluster 并 online', () async {
      final clusters = <ConnectCluster>[];
      final statuses = <ConnectStatus>[];
      h.service.clusters.listen(clusters.add);
      h.service.statusChanges.listen(statuses.add);
      expect(h.service.status, ConnectStatus.idle);
      expect(h.service.current, same(ConnectCluster.empty));

      await h.service.start();

      expect(h.service.status, ConnectStatus.online);
      final put = h.where('PUT').single;
      expect(
        put.url.toString(),
        'https://spclient.test/connect-state/v1/devices/$_observerId',
      );
      expect(put.headers['X-Spotify-Connection-Id'], 'conn-id-1');
      expect(h.service.current.activeDeviceId, 'dev-1');
      expect(h.service.current.devices, hasLength(2));
      await until(() => clusters.isNotEmpty);
      expect(clusters.single.devices, hasLength(2));
      expect(statuses, [ConnectStatus.connecting, ConnectStatus.online]);
    });

    test('start 幂等：重复调用只连接 / 注册一次', () async {
      await Future.wait([h.service.start(), h.service.start()]);
      await h.service.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(h.server.channels, hasLength(1));
      expect(h.where('PUT'), hasLength(1));
    });

    test('stop：注销观察者、关闭 dealer、状态回 idle、快照清空，且不再重连', () async {
      await h.service.start();
      final clusters = <ConnectCluster>[];
      h.service.clusters.listen(clusters.add);

      await h.service.stop();

      final delete = h.where('DELETE').single;
      expect(delete.url.path, '/connect-state/v1/devices/$_observerId');
      expect(delete.headers['X-Spotify-Connection-Id'], 'conn-id-1');
      expect(h.server.channels.single.closed, isTrue);
      expect(h.service.status, ConnectStatus.idle);
      expect(h.service.current.devices, isEmpty);
      await until(() => clusters.isNotEmpty);
      expect(clusters.single.devices, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.server.channels, hasLength(1));
    });

    test('stop 后可再次 start', () async {
      await h.service.start();
      await h.service.stop();
      await h.service.start();

      expect(h.service.status, ConnectStatus.online);
      expect(h.server.channels, hasLength(2));
      expect(h.where('PUT'), hasLength(2));
    });

    test('stop 时注销失败也不抛，照常关闭', () async {
      await h.service.start();
      h.failDelete = true;

      await h.service.stop();

      expect(h.where('DELETE'), hasLength(1));
      expect(h.service.status, ConnectStatus.idle);
      expect(h.server.channels.single.closed, isTrue);
    });

    test('observerId：设备 id 是 40 位 hex 时派生，否则随机但本次固定', () {
      expect(h.service.observerId, _observerId);

      final random = ConnectService(
        client: h.client,
        headers: () async => {},
        deviceId: () => 'not-hex',
      );
      addTearDown(random.dispose);
      expect(random.observerId, matches(RegExp(r'^hobs_[0-9a-f]{40}$')));
      expect(random.observerId, random.observerId);
      expect(random.observerId, isNot(_observerId));
    });
  });

  group('推送', () {
    test('cluster 推送更新 current 并通过 clusters 发出', () async {
      await h.service.start();
      final clusters = <ConnectCluster>[];
      h.service.clusters.listen(clusters.add);

      h.server.channels.single.pushJson(_clusterUri, {
        'cluster': _cluster(active: 'dev-3', devices: 3),
        'update_reason': 'DEVICE_STATE_CHANGED',
      });
      await until(() => clusters.isNotEmpty);

      expect(h.service.current.activeDeviceId, 'dev-3');
      expect(h.service.current.devices, hasLength(3));
      expect(clusters.single, same(h.service.current));
    });

    test('无法解析的推送与其他 uri 被忽略', () async {
      await h.service.start();
      final before = h.service.current;
      final channel = h.server.channels.single;

      channel.push(
        jsonEncode({
          'type': 'message',
          'uri': _clusterUri,
          'payloads': <Object?>[],
        }),
      );
      channel.push(
        jsonEncode({
          'type': 'message',
          'uri': _clusterUri,
          'payloads': ['bm90IGpzb24='],
        }),
      );
      channel.push(
        jsonEncode({
          'type': 'message',
          'uri': _clusterUri,
          'payloads': [
            [1, 2],
          ],
        }),
      );
      channel.push('not json at all');
      channel.pushJson('hm://other/topic', {
        'cluster': _cluster(active: 'ignored'),
      });
      // 最后一条有效推送用来确认前面的都已被处理
      channel.pushJson(_clusterUri, {'cluster': _cluster(active: 'dev-2')});
      await until(() => h.service.current.activeDeviceId == 'dev-2');

      expect(identical(h.service.current, before), isFalse);
    });

    test('serverNowMs：快照服务端时间 + 本地流逝', () async {
      h.registerBody = _cluster(serverMs: 5000000);
      await h.service.start();

      final first = h.service.serverNowMs;
      expect(first, inInclusiveRange(5000000, 5000000 + 2000));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(h.service.serverNowMs - first, greaterThanOrEqualTo(50));
    });

    test('refresh：重新 PUT 并发出新快照', () async {
      await h.service.start();
      h.registerBody = _cluster(active: 'dev-2');

      await h.service.refresh();

      expect(h.where('PUT'), hasLength(2));
      expect(h.service.current.activeDeviceId, 'dev-2');
    });
  });

  group('重连与重试', () {
    test('dealer 重连拿到新连接 id 后自动重新注册', () async {
      await h.service.start();
      final statuses = <ConnectStatus>[];
      h.service.statusChanges.listen(statuses.add);

      h.server.channels.first.drop();
      await until(
        () =>
            h.where('PUT').length == 2 &&
            h.service.status == ConnectStatus.online,
      );

      expect(
        h.where('PUT').last.headers['X-Spotify-Connection-Id'],
        'conn-id-2',
      );
      expect(statuses.first, ConnectStatus.offline);
      expect(statuses.last, ConnectStatus.online);
    });

    test('注册失败：offline 并退避重试，成功后 online', () async {
      h.failRegisterTimes = 2;

      await h.service.start();
      expect(h.service.status, ConnectStatus.offline);

      await until(() => h.service.status == ConnectStatus.online);
      expect(h.where('PUT'), hasLength(3));
      // 全程只用同一条 dealer 连接
      expect(h.server.channels, hasLength(1));
    });

    test('网络不可用：start 不抛，status 为 offline 并持续重试', () async {
      h.server.failConnect = true;

      await h.service.start();
      expect(h.service.status, ConnectStatus.offline);
      await until(() => h.server.attemptTimes.length >= 3);

      h.server.failConnect = false;
      await until(() => h.service.status == ConnectStatus.online);
    });
  });

  group('控制命令', () {
    test(
      '200 without a state change retries once and confirms the target',
      () async {
        await h.service.start();
        var commands = 0;
        h.command = (_) async {
          if (++commands == 2) {
            h.server.channels.single.pushJson(
              _clusterUri,
              _cluster(active: 'dev-2'),
            );
          }
          return http.Response('', 200);
        };
        await h.service.transfer('dev-2', confirm: true);
        expect(commands, 2);
        expect(h.service.current.activeDeviceId, 'dev-2');
      },
    );

    test(
      'confirmation push arriving before HTTP response is retained',
      () async {
        await h.service.start();
        h.command = (_) async {
          h.server.channels.single.pushJson(
            _clusterUri,
            _cluster(active: 'dev-2'),
          );
          await until(() => h.service.current.activeDeviceId == 'dev-2');
          return http.Response('', 200);
        };
        await h.service.transfer('dev-2', confirm: true);
        expect(h.where('POST'), hasLength(1));
      },
    );

    test(
      'refresh recovers a lost confirmation push without resending',
      () async {
        await h.service.start();
        h.command = (_) async {
          h.registerBody = _cluster(active: 'dev-2');
          return http.Response('', 200);
        };
        await h.service.transfer('dev-2', confirm: true);
        expect(h.where('POST'), hasLength(1));
        expect(h.service.current.activeDeviceId, 'dev-2');
      },
    );

    test(
      'new intent supersedes old retries, serializes sends and drops queued stale play',
      () async {
        await h.service.start();
        final first = Completer<http.Response>();
        h.command = (_) => first.future;
        final old = h.service.play(
          'dev-1',
          trackUri: 'spotify:track:old',
          confirm: true,
        );
        await until(() => h.where('POST').length == 1);
        final middle = h.service.play(
          'dev-1',
          trackUri: 'spotify:track:middle',
          confirm: true,
        );
        final latest = h.service.play(
          'dev-2',
          trackUri: 'spotify:track:new',
          confirm: true,
        );
        expect(h.where('POST'), hasLength(1));
        h.command = (_) async {
          h.server.channels.single.pushJson(_clusterUri, {
            ..._cluster(active: 'dev-2'),
            'player_state': {
              'track': {'uri': 'spotify:track:new'},
              'is_playing': true,
              'is_paused': false,
            },
          });
          return http.Response('', 200);
        };
        first.complete(http.Response('', 500));
        await Future.wait([old, middle, latest]);
        expect(h.where('POST'), hasLength(2));
        expect(
          jsonDecode(
            h.where('POST').last.body,
          )['command']['options']['skip_to']['track_uri'],
          'spotify:track:new',
        );
      },
    );

    test(
      'pause cancels an unconfirmed play retry and follows its send',
      () async {
        await h.service.start();
        final first = Completer<http.Response>();
        h.command = (_) => first.future;
        final play = h.service.play(
          'dev-1',
          trackUri: 'spotify:track:a',
          confirm: true,
        );
        await until(() => h.where('POST').length == 1);
        final pause = h.service.pause('dev-1');
        h.command = (_) async => http.Response('', 200);
        first.complete(http.Response('', 200));
        await Future.wait([play, pause]);
        expect(h.where('POST'), hasLength(2));
        expect(
          jsonDecode(h.where('POST').last.body)['command']['endpoint'],
          'pause',
        );
      },
    );

    test(
      'unconfirmed command fails after two attempts; 403 never retries',
      () async {
        await h.service.start();
        await expectLater(
          h.service.transfer('dev-2', confirm: true),
          throwsA(isA<ConnectException>()),
        );
        expect(h.where('POST'), hasLength(2));
        h.requests.clear();
        h.commandStatus = 403;
        await expectLater(
          h.service.transfer('dev-2', confirm: true),
          throwsA(
            isA<ConnectException>().having((e) => e.statusCode, 'status', 403),
          ),
        );
        expect(h.where('POST'), hasLength(1));
      },
    );

    test(
      'late refresh and older timestamp cannot overwrite a newer push',
      () async {
        await h.service.start();
        final response = Completer<http.Response>();
        h.registration = () => response.future;
        final refresh = h.service.refresh();
        await until(() => h.where('PUT').length == 2);
        h.server.channels.single.pushJson(
          _clusterUri,
          _cluster(active: 'dev-2', serverMs: 1700000000010),
        );
        await until(() => h.service.current.activeDeviceId == 'dev-2');
        response.complete(http.Response(jsonEncode(_cluster()), 200));
        await refresh;
        h.server.channels.single.pushJson(_clusterUri, _cluster());
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(h.service.current.activeDeviceId, 'dev-2');
      },
    );

    test('未 online 时抛 ConnectException，不发请求', () async {
      await expectLater(
        h.service.pause('dev-1'),
        throwsA(isA<ConnectException>()),
      );
      await expectLater(
        h.service.transfer('dev-1'),
        throwsA(isA<ConnectException>()),
      );
      await expectLater(h.service.refresh(), throwsA(isA<ConnectException>()));
      expect(h.requests, isEmpty);
    });

    test('命令路径 / 方法 / 连接 id / body', () async {
      await h.service.start();
      h.requests.clear();

      await h.service.transfer('dev-2');
      await h.service.transfer('dev-2', play: false);
      await h.service.pause('dev-1');
      await h.service.resume('dev-1');
      await h.service.skipNext('dev-1');
      await h.service.skipPrevious('dev-1');
      await h.service.seekTo('dev-1', 12345);
      await h.service.setShuffle('dev-1', true);
      await h.service.setRepeat('dev-1', context: true, track: false);
      await h.service.setVolume('dev-1', 0.5);
      await h.service.setVolume('dev-1', 2);

      expect(
        h.requests.every(
          (r) => r.headers['X-Spotify-Connection-Id'] == 'conn-id-1',
        ),
        isTrue,
      );
      expect(h.requests[0].method, 'POST');
      expect(
        h.requests[0].url.path,
        '/connect-state/v1/connect/transfer/from/$_observerId/to/dev-2',
      );
      expect(jsonDecode(h.requests[0].body), {
        'transfer_options': {'restore_paused': 'restore'},
      });
      expect(jsonDecode(h.requests[1].body), {
        'transfer_options': {'restore_paused': 'pause'},
      });

      final commands = h.requests.skip(2).take(7).toList();
      for (final r in commands) {
        expect(r.method, 'POST');
        expect(
          r.url.path,
          '/connect-state/v1/player/command/from/$_observerId/to/dev-1',
        );
      }
      expect(commands.map((r) => jsonDecode(r.body)['command']), [
        {'endpoint': 'pause'},
        {'endpoint': 'resume'},
        {'endpoint': 'skip_next'},
        {'endpoint': 'skip_prev'},
        {'endpoint': 'seek_to', 'value': 12345},
        {'endpoint': 'set_shuffling_context', 'value': true},
        {
          'endpoint': 'set_options',
          'repeating_context': true,
          'repeating_track': false,
        },
      ]);

      final volumes = h.requests.skip(9).toList();
      expect(volumes.map((r) => r.method).toSet(), {'PUT'});
      expect(
        volumes.first.url.path,
        '/connect-state/v1/connect/volume/from/$_observerId/to/dev-1',
      );
      expect(volumes.map((r) => jsonDecode(r.body)['volume']), [32768, 65535]);
    });

    test('play：上下文 / 临时列表两种 body', () async {
      await h.service.start();
      h.requests.clear();

      await h.service.play(
        'dev-1',
        contextUri: 'spotify:album:a1',
        trackUri: 'spotify:track:t2',
      );
      await h.service.play(
        'dev-1',
        trackUris: ['spotify:track:t1', 'spotify:track:t2'],
        trackIndex: 1,
      );

      expect(h.requests.map((r) => r.url.path).toSet(), {
        '/connect-state/v1/player/command/from/$_observerId/to/dev-1',
      });
      final withContext =
          jsonDecode(h.requests[0].body)['command'] as Map<String, dynamic>;
      expect(withContext['endpoint'], 'play');
      expect(withContext['play_origin'], isEmpty);
      expect(withContext['context'], {
        'uri': 'spotify:album:a1',
        'url': 'context://spotify:album:a1',
        'metadata': {},
      });
      expect(withContext['options'], {
        'license': 'on-demand',
        'skip_to': {'track_uri': 'spotify:track:t2'},
        'player_options_override': {},
      });
      final adHoc =
          jsonDecode(h.requests[1].body)['command'] as Map<String, dynamic>;
      expect(adHoc['play_origin'], isEmpty);
      expect(adHoc['context'], {
        'uri': '',
        'url': '',
        'metadata': {},
        'pages': [
          {
            'tracks': [
              {'uri': 'spotify:track:t1'},
              {'uri': 'spotify:track:t2'},
            ],
          },
        ],
      });
      expect((adHoc['options'] as Map)['skip_to'], {'track_index': 1});
    });

    test('play：随机 / 循环随命令下发，不沿用服务端旧状态', () async {
      await h.service.start();
      h.requests.clear();

      await h.service.play(
        'dev-1',
        contextUri: 'spotify:playlist:p1',
        trackUri: 'spotify:track:t2',
        repeatingContext: true,
        repeatingTrack: false,
        shufflingContext: false,
      );

      final command =
          jsonDecode(h.requests.first.body)['command'] as Map<String, dynamic>;
      expect((command['options'] as Map)['player_options_override'], {
        'repeating_context': true,
        'repeating_track': false,
        'shuffling_context': false,
      });
    });

    test('服务端拒绝（403）→ ConnectException 带状态码', () async {
      await h.service.start();
      h.commandStatus = 403;

      await expectLater(
        h.service.pause('dev-1'),
        throwsA(
          isA<ConnectException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      await expectLater(
        h.service.transfer('dev-2'),
        throwsA(isA<ConnectException>()),
      );
      // 命令失败不影响连接状态
      expect(h.service.status, ConnectStatus.online);
    });
  });
}
