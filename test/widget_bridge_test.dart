import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/media_controls/media_controls_sync.dart';
import 'package:flutify_app/services/media_controls/system_media_controls.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/services/widget/widget_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutify/widget_bridge');

  const track = MediaTrackInfo(
    id: 't1',
    title: 'Title',
    artist: 'Artist',
    album: 'Album',
    artUrl: 'https://example.test/cover.jpg',
    duration: Duration(seconds: 100),
  );
  const playing = MediaPlaybackInfo(
    playing: true,
    buffering: false,
    position: Duration.zero,
    canNext: true,
    canPrevious: true,
  );

  group('WidgetBridge', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('update 下发完整字段；封面解析成功带本地路径', () async {
      final bridge = WidgetBridge(
        artworkFile: (url) async {
          expect(url, 'https://example.test/cover.jpg');
          return '/tmp/flutify-cover.jpg';
        },
      );
      await bridge.update(track, playing);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'update');
      expect(calls.single.arguments, {
        'id': 't1',
        'title': 'Title',
        'artist': 'Artist',
        'album': 'Album',
        'durationMs': 100000,
        'isPlaying': isTrue,
        'isBuffering': isFalse,
        'coverPath': '/tmp/flutify-cover.jpg',
      });
    });

    test('封面解析超时回落 null，其余字段照常下发', () {
      fakeAsync((async) {
        final bridge = WidgetBridge(
          artworkFile: (url) => Future<String?>.delayed(
            const Duration(seconds: 10),
            () => '/tmp/late.jpg',
          ),
        );
        var done = false;
        bridge.update(track, playing).then((_) => done = true);
        async.elapse(const Duration(seconds: 10));
        expect(done, isTrue);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'update');
        final args = calls.single.arguments as Map;
        expect(args['coverPath'], isNull);
        expect(args['durationMs'], 100000);
        expect(args['isPlaying'], isTrue);
      });
    });

    test('封面稍晚就绪：先下发文字（coverPath 为 null），就绪后补发带封面的一帧', () {
      fakeAsync((async) {
        final bridge = WidgetBridge(
          artworkFile: (url) => Future<String?>.delayed(
            const Duration(seconds: 2),
            () => '/tmp/late.jpg',
          ),
        );
        bridge.update(track, playing);
        async.elapse(WidgetBridge.coverWait);
        expect(calls, hasLength(1));
        expect((calls.single.arguments as Map)['coverPath'], isNull);
        expect((calls.single.arguments as Map)['title'], 'Title');
        async.elapse(const Duration(seconds: 2));
        expect(calls, hasLength(2));
        expect((calls.last.arguments as Map)['coverPath'], '/tmp/late.jpg');
      });
    });

    test('同一封面只解析一次；被新推送取代的旧推送不再下发', () {
      fakeAsync((async) {
        var resolves = 0;
        final bridge = WidgetBridge(
          artworkFile: (url) {
            resolves++;
            return Future<String?>.delayed(
              const Duration(milliseconds: 300),
              () => '/tmp/cover.jpg',
            );
          },
        );
        const paused = MediaPlaybackInfo(
          playing: false,
          buffering: false,
          position: Duration.zero,
          canNext: true,
          canPrevious: true,
        );
        bridge.update(track, playing);
        async.elapse(const Duration(milliseconds: 100));
        bridge.update(track, paused);
        async.elapse(const Duration(seconds: 1));
        expect(resolves, 1);
        // 只有后一次（暂停）下发：旧的播放态不会晚到覆盖它
        expect(calls, hasLength(1));
        expect((calls.single.arguments as Map)['isPlaying'], isFalse);
        expect((calls.single.arguments as Map)['coverPath'], '/tmp/cover.jpg');
      });
    });

    test('封面解析失败或返回空路径时回落 null', () async {
      final failing = WidgetBridge(
        artworkFile: (url) async => throw StateError('下载失败'),
      );
      await failing.update(track, playing);
      expect((calls.single.arguments as Map)['coverPath'], isNull);

      final empty = WidgetBridge(artworkFile: (url) async => '');
      await empty.update(track, playing);
      expect((calls.last.arguments as Map)['coverPath'], isNull);
    });

    test('无封面时不解析，coverPath 为 null', () async {
      var resolved = false;
      final bridge = WidgetBridge(
        artworkFile: (url) async {
          resolved = true;
          return '/tmp/never.jpg';
        },
      );
      await bridge.update(
        const MediaTrackInfo(
          id: 't2',
          title: 'No art',
          artist: 'A',
          album: 'B',
          artUrl: '',
          duration: Duration(seconds: 1),
        ),
        playing,
      );
      expect(resolved, isFalse);
      expect((calls.single.arguments as Map)['coverPath'], isNull);
    });

    test('updateQueue 下发来源名与接下来的曲目', () async {
      final bridge = WidgetBridge(artworkFile: (url) async => null);
      await bridge.updateQueue('Mix', [track]);
      expect(calls.single.method, 'queue');
      expect(calls.single.arguments, {
        'context': 'Mix',
        'items': [
          {'id': 't1', 'title': 'Title', 'artist': 'Artist'},
        ],
      });
    });

    test('原生点按待播清单交给 onPlayQueueItem，参数不全或未接回调返回 false', () async {
      final bridge = WidgetBridge(artworkFile: (url) async => null);
      expect(
        await _nativeCall('playQueueItem', {'index': 1, 'id': 't2'}),
        isFalse,
      );

      final received = <Object>[];
      bridge.onPlayQueueItem = (index, id) async {
        received.addAll([index, id]);
        return true;
      };
      expect(
        await _nativeCall('playQueueItem', {'index': 1, 'id': 't2'}),
        isTrue,
      );
      expect(received, [1, 't2']);
      expect(await _nativeCall('playQueueItem', {'index': '1'}), isFalse);
    });

    test('requestPin 传款式 id，返回原生结果；原生缺失时为 false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.arguments == 'cover';
          });
      final bridge = WidgetBridge(artworkFile: (url) async => null);
      expect(await bridge.requestPin(HomeWidgetStyle.cover), isTrue);
      expect(await bridge.requestPin(HomeWidgetStyle.upNext), isFalse);
      expect(calls.map((c) => c.method), ['requestPin', 'requestPin']);
      expect(calls.map((c) => c.arguments), ['cover', 'upNext']);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await bridge.requestPin(HomeWidgetStyle.albumCard), isFalse);
    });

    test('syncLanguage 映射成语言标签，同值不重复下发', () async {
      final bridge = WidgetBridge(artworkFile: (url) async => null);
      await bridge.syncLanguage(AppLanguage.zh);
      await bridge.syncLanguage(AppLanguage.zh);
      await bridge.syncLanguage(AppLanguage.zhHant);
      await bridge.syncLanguage(AppLanguage.system);
      expect(calls.map((c) => c.method), everyElement('setLocale'));
      expect(calls.map((c) => c.arguments), ['zh-CN', 'zh-TW', '']);
    });

    test('clear 通知原生清空', () async {
      final bridge = WidgetBridge(artworkFile: (url) async => null);
      await bridge.clear();
      expect(calls.single.method, 'clear');
    });

    test('原生侧抛 PlatformException 时静默降级，update / clear 都不向上抛', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'unavailable', message: '原生失败');
          });
      final bridge = WidgetBridge(artworkFile: (url) async => '/tmp/cover.jpg');
      await bridge.update(track, playing);
      await bridge.clear();
    });

    test('原生未注册插件时静默降级（MissingPluginException）', () async {
      // 不设 handler 时 invokeMethod 抛 MissingPluginException
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final bridge = WidgetBridge(artworkFile: (url) async => '/tmp/cover.jpg');
      await bridge.update(track, playing);
      await bridge.clear();
    });
  });

  group('MediaControlsSync 挂载', () {
    late FakeAudioPlayerService audio;
    late PlaybackProvider playback;
    late MediaControlsSync sync;
    late List<MethodCall> calls;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      audio = FakeAudioPlayerService();
      playback = PlaybackProvider(
        audio,
        await StorageService.init(),
        random: Random(1),
        audioLoader: FakeTrackAudioSource(),
      );
      sync = MediaControlsSync(
        playback,
        _FakeControls(),
        widget: WidgetBridge(
          artworkFile: (url) async => url.isEmpty ? null : '/tmp/cover.jpg',
        ),
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      sync.dispose();
      playback.dispose();
    });

    Map<dynamic, dynamic> lastUpdate() =>
        calls.lastWhere((call) => call.method == 'update').arguments
            as Map<dynamic, dynamic>;

    test('曲目与播放态变化推给小组件；清空时 clear', () async {
      const a = SampleCatalog.track1;
      const b = SampleCatalog.track2;

      // 启动时没有可还原的会话：清掉小组件里上个进程留下的旧曲目
      expect(calls.map((c) => c.method), ['clear']);

      await playback.playTrack(a, contextQueue: [a, b]);
      await Future<void>.delayed(Duration.zero);
      var args = lastUpdate();
      expect(args['id'], a.id);
      expect(args['title'], a.name);
      expect(args['artist'], a.artistNames);
      expect(args['album'], 'Album A');
      expect(args['durationMs'], a.durationMs);
      expect(args['coverPath'], '/tmp/cover.jpg');

      audio.stateController.add(PlayerState(true, ProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      args = lastUpdate();
      expect(args['isPlaying'], isTrue);
      expect(args['isBuffering'], isFalse);

      audio.stateController.add(PlayerState(false, ProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      expect(lastUpdate()['isPlaying'], isFalse);

      await playback.nextTrack();
      await Future<void>.delayed(Duration.zero);
      expect(lastUpdate()['id'], b.id);

      await playback.discardSession();
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.method, 'clear');
      expect(calls.where((c) => c.method == 'clear'), hasLength(2));
    });

    test('待播清单：来源名 + 接下来的曲目，变化时才下发', () async {
      const a = SampleCatalog.track1;
      const b = SampleCatalog.track2;
      const c = SampleCatalog.track3;

      await playback.playTrack(
        a,
        contextQueue: [a, b, c],
        context: const PlaybackContext.playlist('Mix'),
      );
      await Future<void>.delayed(Duration.zero);
      final queues = calls.where((call) => call.method == 'queue').toList();
      expect(queues, hasLength(1));
      final args = queues.single.arguments as Map;
      expect(args['context'], 'Mix');
      expect(
        [for (final item in args['items'] as List) item['id']],
        [b.id, c.id],
      );

      // 只是播放态变化：清单不重复下发
      audio.stateController.add(PlayerState(true, ProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'queue'), hasLength(1));

      playback.addToQueue(c);
      await Future<void>.delayed(Duration.zero);
      final last =
          calls.lastWhere((call) => call.method == 'queue').arguments as Map;
      expect(
        [for (final item in last['items'] as List) item['id']],
        [c.id, b.id, c.id],
      );
    });

    test('小组件点按待播清单：校验曲目 id 后跳到那首', () async {
      const a = SampleCatalog.track1;
      const b = SampleCatalog.track2;
      const c = SampleCatalog.track3;
      await playback.playTrack(a, contextQueue: [a, b, c]);
      await Future<void>.delayed(Duration.zero);

      // 队列已变（id 对不上）：不动
      expect(
        await _nativeCall('playQueueItem', {'index': 1, 'id': b.id}),
        isFalse,
      );
      expect(playback.currentTrack?.id, a.id);

      expect(
        await _nativeCall('playQueueItem', {'index': 1, 'id': c.id}),
        isTrue,
      );
      expect(playback.currentTrack?.id, c.id);
    });
  });

  group('PlaybackProvider.upcomingTracks', () {
    test('用户队列在前、上下文在后，只取前 limit 首', () async {
      SharedPreferences.setMockInitialValues({});
      final playback = PlaybackProvider(
        FakeAudioPlayerService(),
        await StorageService.init(),
        random: Random(1),
        audioLoader: FakeTrackAudioSource(),
      );
      addTearDown(playback.dispose);
      const a = SampleCatalog.track1;
      const b = SampleCatalog.track2;
      const c = SampleCatalog.track3;
      await playback.playTrack(a, contextQueue: [a, b, c]);
      playback.addToQueue(a);
      expect(
        [for (final t in playback.upcomingTracks(6)) t.id],
        [a.id, b.id, c.id],
      );
      expect([for (final t in playback.upcomingTracks(2)) t.id], [a.id, b.id]);

      expect(await playback.playUpcoming(0, b.id), isFalse);
      expect(await playback.playUpcoming(9, a.id), isFalse);
      expect(await playback.playUpcoming(0, a.id), isTrue);
      expect(playback.userQueue, isEmpty);
    });
  });
}

/// 模拟原生侧经 `flutify/widget_bridge` 调 Dart，返回 Dart 的结果。
Future<Object?> _nativeCall(String method, Object? arguments) async {
  const codec = StandardMethodCodec();
  final completer = Completer<Object?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'flutify/widget_bridge',
        codec.encodeMethodCall(MethodCall(method, arguments)),
        (data) => completer.complete(
          data == null ? null : codec.decodeEnvelope(data),
        ),
      );
  return completer.future;
}

class _FakeControls implements SystemMediaControls {
  final StreamController<MediaControlEvent> controller =
      StreamController.broadcast(sync: true);

  @override
  Stream<MediaControlEvent> get events => controller.stream;

  @override
  bool get needsPeriodicTimeline => false;

  @override
  Future<void> setTrack(MediaTrackInfo? track) async {}

  @override
  Future<void> setPlayback(MediaPlaybackInfo info) async {}

  @override
  void dispose() => controller.close();
}
