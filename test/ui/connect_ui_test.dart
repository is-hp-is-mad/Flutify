import 'dart:async';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/connect_cluster.dart';
import 'package:flutify_app/providers/connect_provider.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/connect/connect_service.dart';
import 'package:flutify_app/services/connect/connect_play_request.dart';
import 'package:flutify_app/ui/widgets/connect/connect_actions.dart';
import 'package:flutify_app/services/media_controls/connect_media_source.dart';
import 'package:flutify_app/services/media_controls/system_media_controls.dart';
import 'package:flutify_app/ui/widgets/connect/playback_shortcuts.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/device_picker_sheet.dart';
import 'package:flutify_app/ui/screens/player/immersive_lyrics_screen.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutify_app/ui/shell/desktop/desktop_window.dart';
import 'package:flutify_app/ui/widgets/connect/remote_mini_player.dart';
import 'package:flutify_app/ui/widgets/connect/remote_player_bar.dart';
import 'package:flutify_app/ui/widgets/desktop_player_bar.dart';
import 'package:flutify_app/ui/widgets/mini_player.dart';
import 'package:flutify_app/ui/widgets/marquee_text.dart';
import 'package:flutify_app/ui/widgets/cover_image.dart';
import 'package:flutify_app/ui/screens/player/lyrics/lyrics_view.dart';
import 'package:flutify_app/ui/screens/player/queue_list.dart';
import 'package:flutify_app/ui/widgets/track_tile.dart';
import 'package:flutify_app/ui/widgets/waveform_visualizer.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_track_audio_source.dart';

/// 假 Connect 服务：手动推送 cluster，记录收到的命令；[fail] 为 true 时命令全部失败。
class FakeConnectService implements ConnectService {
  final _clusters = StreamController<ConnectCluster>.broadcast();
  final _statuses = StreamController<ConnectStatus>.broadcast();
  final List<String> commands = [];
  bool fail = false;
  Completer<void>? transferGate;

  @override
  ConnectStatus status = ConnectStatus.idle;

  @override
  ConnectCluster current = ConnectCluster.empty;

  @override
  Stream<ConnectCluster> get clusters => _clusters.stream;

  @override
  Stream<ConnectStatus> get statusChanges => _statuses.stream;

  @override
  int get serverNowMs => current.serverTimestampMs;

  void push(ConnectCluster cluster) {
    current = cluster;
    _clusters.add(cluster);
  }

  void setStatus(ConnectStatus s) {
    status = s;
    _statuses.add(s);
  }

  Future<void> _record(String command) async {
    if (fail) throw const ConnectException(403, 'synthetic failure');
    commands.add(command);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> transfer(
    String toDeviceId, {
    bool play = true,
    bool confirm = false,
  }) async {
    await _record('transfer:$toDeviceId');
    await transferGate?.future;
  }

  @override
  Future<void> play(
    String deviceId, {
    String contextUri = '',
    List<String> trackUris = const [],
    String? trackUri,
    int? trackIndex,
    int? seekToMs,
    bool paused = false,
    bool? repeatingContext,
    bool? repeatingTrack,
    bool confirm = false,
  }) => _record('play:$deviceId');

  @override
  Future<void> pause(String deviceId) => _record('pause:$deviceId');

  @override
  Future<void> resume(String deviceId) => _record('resume:$deviceId');

  @override
  Future<void> skipNext(String deviceId) => _record('next:$deviceId');

  @override
  Future<void> skipPrevious(String deviceId) => _record('prev:$deviceId');

  @override
  Future<void> seekTo(String deviceId, int positionMs) =>
      _record('seek:$deviceId');

  @override
  Future<void> setShuffle(String deviceId, bool value) =>
      _record('shuffle:$value');

  @override
  Future<void> setRepeat(
    String deviceId, {
    required bool context,
    required bool track,
  }) => _record('repeat:$context:$track');

  @override
  Future<void> setVolume(String deviceId, double volume) =>
      _record('volume:$deviceId');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 只使用合成数据的 cluster：一台正在播放的音箱 + 一台空闲手机。
ConnectCluster syntheticCluster({
  bool playing = true,
  bool withActive = true,
  bool withOthers = true,
  int volumeSteps = 64,
}) {
  final speaker = ConnectDevice(
    id: 'synthetic-speaker',
    name: 'Synthetic Living Room Speaker With A Long Name',
    type: ConnectDeviceType.speaker,
    volume: 0.4,
    volumeSteps: volumeSteps,
  );
  const phone = ConnectDevice(
    id: 'synthetic-phone',
    name: 'Synthetic Phone',
    type: ConnectDeviceType.smartphone,
  );
  return ConnectCluster(
    activeDeviceId: withActive ? speaker.id : '',
    devices: [if (withActive) speaker, if (withOthers) phone],
    serverTimestampMs: 1000000,
    player: withActive
        ? ConnectPlayerState(
            trackUri: 'spotify:track:synthetic0000000000000a',
            title: 'A Synthetic Remote Track With A Fairly Long Title',
            albumTitle: 'Synthetic Album',
            isPlaying: true,
            isPaused: !playing,
            positionMs: 30000,
            timestampMs: 1000000,
            durationMs: 200000,
          )
        : ConnectPlayerState.idle,
  );
}

void main() {
  late FakeConnectService service;
  late AppLocalizations zh;
  late StorageService storage;

  setUp(() {
    service = FakeConnectService();
    zh = lookupAppLocalizations(const Locale('zh'));
    ArtworkPalette.enabled = false;
  });

  Future<void> pumpHost(
    WidgetTester tester,
    Size size,
    Widget child, {
    ConnectCluster? cluster,
    bool available = true,
    double fontScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          // 未登录：歌词请求直接返回空，不联网
          ChangeNotifierProvider(
            create: (_) => SpotifyProvider(SpotifyApiService(storage), storage),
          ),
          ChangeNotifierProvider(create: (_) => LibraryProvider(storage)),
          ChangeNotifierProvider(
            create: (_) => PlaybackProvider(
              FakeAudioPlayerService(),
              storage,
              audioLoader: FakeTrackAudioSource(),
            ),
          ),
          ChangeNotifierProvider(
            create: (_) => ConnectProvider(
              service,
              available: () => available,
              resolveTrack: (_) async => null,
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(fontScale)),
            child: c!,
          ),
          home: Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: child),
          ),
        ),
      ),
    );
    if (cluster != null) {
      service.setStatus(ConnectStatus.online);
      service.push(cluster);
    }
    // 音柱持续动画：只推进固定时长，不等 settle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 卸载组件树，让进度定时器与动画随之释放。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  group('desktop player bar', () {
    for (final width in const [900.0, 1280.0, 1920.0]) {
      testWidgets('remote mode at ${width.round()} wide: strip, no overflow', (
        tester,
      ) async {
        await pumpHost(
          tester,
          Size(width, 700),
          const DesktopPlayerBar(),
          cluster: syntheticCluster(),
        );
        expect(find.byType(RemotePlayerBar), findsOneWidget);
        expect(
          find.text(
            zh.connectPlayingOn(
              'Synthetic Living Room Speaker With A Long Name',
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await unmount(tester);
      });
    }

    testWidgets('local mode when there is no remote session', (tester) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        const DesktopPlayerBar(),
        cluster: syntheticCluster(withActive: false),
      );
      expect(find.byType(RemotePlayerBar), findsNothing);
      expect(find.text(zh.playerIdleHint), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('transport buttons send commands to the active device', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        const DesktopPlayerBar(),
        cluster: syntheticCluster(),
      );
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.tap(find.byIcon(Icons.skip_next_rounded));
      await tester.tap(find.byIcon(Icons.shuffle_rounded));
      await tester.pump();
      expect(service.commands, [
        'pause:synthetic-speaker',
        'next:synthetic-speaker',
        'shuffle:true',
      ]);
      await unmount(tester);
    });

    testWidgets('failed command shows a snackbar', (tester) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        const DesktopPlayerBar(),
        cluster: syntheticCluster(),
      );
      service.fail = true;
      await tester.tap(find.byIcon(Icons.skip_next_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(zh.connectCommandFailed), findsOneWidget);
      await unmount(tester);
    });
  });

  group('mobile mini player', () {
    for (final fontScale in const [1.0, 1.3]) {
      for (final width in const [320.0, 390.0]) {
        testWidgets(
          'remote capsule at ${width.round()} wide, font ${(fontScale * 100).round()}%',
          (tester) async {
            await pumpHost(
              tester,
              Size(width, 700),
              const MiniPlayer(),
              cluster: syntheticCluster(playing: false),
              fontScale: fontScale,
            );
            expect(find.byType(RemoteMiniPlayer), findsOneWidget);
            expect(tester.takeException(), isNull);

            await tester.tap(find.byIcon(Icons.play_arrow_rounded));
            await tester.pump();
            expect(service.commands, ['resume:synthetic-speaker']);
            await unmount(tester);
          },
        );
      }
    }
  });

  group('keyboard shortcuts and media keys', () {
    // 与主窗口一致：Ctrl 组合键走 CallbackShortcuts，空格走 Focus.onKeyEvent（见 PlaybackShortcuts.onSpaceKey）
    final host = Builder(
      builder: (context) => CallbackShortcuts(
        bindings: PlaybackShortcuts.bindings(context),
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) =>
              PlaybackShortcuts.onSpaceKey(node.context!, event),
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );

    Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    testWidgets('control the remote device while it is playing', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        host,
        cluster: syntheticCluster(),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await ctrl(tester, LogicalKeyboardKey.arrowRight);
      await ctrl(tester, LogicalKeyboardKey.arrowLeft);
      await ctrl(tester, LogicalKeyboardKey.keyS);
      await ctrl(tester, LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 200)); // 音量请求节流 150ms
      expect(service.commands, [
        'pause:synthetic-speaker',
        'next:synthetic-speaker',
        'prev:synthetic-speaker',
        'shuffle:true',
        'volume:synthetic-speaker',
      ]);
      await unmount(tester);
    });

    testWidgets('volume keys explain when the remote device has fixed volume', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        host,
        cluster: syntheticCluster(volumeSteps: 0),
      );
      await ctrl(tester, LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 200));
      expect(service.commands, isEmpty);
      expect(
        find.text(
          zh.connectVolumeUnsupported(
            'Synthetic Living Room Speaker With A Long Name',
          ),
        ),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('control this device when nothing plays elsewhere', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        host,
        cluster: syntheticCluster(withActive: false),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await ctrl(tester, LogicalKeyboardKey.arrowRight);
      expect(service.commands, isEmpty);
      await unmount(tester);
    });

    test(
      'remote keeps control while local is silent; local playback takes over',
      () async {
        final connect = ConnectProvider(
          service,
          available: () => true,
          resolveTrack: (_) async => null,
        );

        service.push(syntheticCluster());
        await Future<void>.delayed(Duration.zero);
        // 远程出声、本机静默 → 远程
        expect(
          connect.controlsRemote(localPlaying: false, localHasTrack: true),
          isTrue,
        );

        // 远程被暂停：集群里仍有活动设备和曲目，控制权留在远程
        service.push(syntheticCluster(playing: false));
        await Future<void>.delayed(Duration.zero);
        expect(
          connect.controlsRemote(localPlaying: false, localHasTrack: true),
          isTrue,
        );

        // 本机正在出声 → 本机优先；本机停下后回到远程
        expect(
          connect.controlsRemote(localPlaying: true, localHasTrack: true),
          isFalse,
        );
        expect(
          connect.controlsRemote(localPlaying: false, localHasTrack: true),
          isTrue,
        );

        // 远程会话结束（无活动设备）→ 本机
        service.push(syntheticCluster(withActive: false));
        await Future<void>.delayed(Duration.zero);
        expect(
          connect.controlsRemote(localPlaying: false, localHasTrack: true),
          isFalse,
        );
        connect.dispose();
      },
    );

    testWidgets(
      'media card shows and controls the remote device only in remote mode',
      (tester) async {
        await pumpHost(
          tester,
          const Size(1280, 700),
          host,
          cluster: syntheticCluster(),
        );
        final context = tester.element(find.byType(SizedBox).last);
        final source = ConnectMediaSource(
          context.read<ConnectProvider>(),
          context.read<PlaybackProvider>(),
        );

        expect(source.active, isTrue);
        expect(
          source.track?.title,
          'A Synthetic Remote Track With A Fairly Long Title',
        );
        expect(source.playbackInfo.playing, isTrue);

        expect(
          source.handle(const MediaButtonEvent(MediaButton.toggle)),
          isTrue,
        );
        expect(
          source.handle(const MediaButtonEvent(MediaButton.play)),
          isTrue,
        ); // 已在播放：不重复发送
        expect(source.handle(const MediaButtonEvent(MediaButton.next)), isTrue);
        await tester.pump();
        expect(service.commands, [
          'pause:synthetic-speaker',
          'next:synthetic-speaker',
        ]);

        service.push(syntheticCluster(withActive: false));
        await tester.pump();
        expect(source.active, isFalse);
        expect(
          source.handle(const MediaButtonEvent(MediaButton.toggle)),
          isFalse,
        );
        await unmount(tester);
      },
    );
  });

  group('track list', () {
    const remote = SpotifyTrack(
      id: 'synthetic0000000000000a',
      name: 'Remote Row',
      durationMs: 200000,
    );
    const other = SpotifyTrack(
      id: 'synthetic0000000000000b',
      name: 'Other Row',
      durationMs: 180000,
    );
    const list = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TrackTile(track: remote),
        TrackTile(track: other),
      ],
    );

    Color? titleColor(WidgetTester tester, String name) =>
        tester.widget<Text>(find.text(name)).style?.color;

    testWidgets('TrackTile actions strictly align on narrow screens across long titles', (
      tester,
    ) async {
      const longTrack = SpotifyTrack(
        id: 'synthetic0000000000000c',
        name: 'Ignite - Different Heaven Remix With Very Long Title',
        durationMs: 191000,
      );
      const testList = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TrackTile(track: remote),
          TrackTile(track: longTrack),
        ],
      );
      await pumpHost(
        tester,
        const Size(420, 700),
        testList,
      );
      final buttons = find.byType(IconButton);
      expect(buttons, findsNWidgets(4));
      final heart1 = tester.getRect(buttons.at(0));
      final heart2 = tester.getRect(buttons.at(2));
      expect(heart1.left, equals(heart2.left));
      expect(heart1.width, equals(heart2.width));
      expect(heart1.center.dx, equals(heart2.center.dx));

      final more1 = tester.getRect(buttons.at(1));
      final more2 = tester.getRect(buttons.at(3));
      expect(more1.left, equals(more2.left));
      expect(more1.center.dx, equals(more2.center.dx));
      await unmount(tester);
    });

    testWidgets('highlights the remote track, not the local one', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        list,
        cluster: syntheticCluster(),
      );
      final primary = Theme.of(
        tester.element(find.text('Remote Row')),
      ).colorScheme.primary;
      expect(titleColor(tester, 'Remote Row'), primary);
      expect(titleColor(tester, 'Other Row'), isNot(primary));
      expect(find.byType(WaveformVisualizer), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('hover pause on the remote row pauses the remote device', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        list,
        cluster: syntheticCluster(),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(CoverImage).first));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      expect(service.commands, ['pause:synthetic-speaker']);
      await unmount(tester);
    });

    testWidgets('no highlight once the remote session ends', (tester) async {
      await pumpHost(
        tester,
        const Size(1280, 700),
        list,
        cluster: syntheticCluster(),
      );
      service.push(syntheticCluster(withActive: false));
      await tester.pump();
      expect(find.byType(WaveformVisualizer), findsNothing);
      await unmount(tester);
    });
  });

  group('device picker', () {
    testWidgets(
      'local takeover bypasses remote hook and preserves position with unresolved metadata',
      (tester) async {
        await pumpHost(
          tester,
          const Size(390, 844),
          const SizedBox(),
          cluster: syntheticCluster(),
        );
        final context = tester.element(find.byType(Scaffold));
        final playback = context.read<PlaybackProvider>();
        var forwarded = 0;
        playback.remotePlay = (_, _, _) async {
          forwarded++;
          return true;
        };
        await ConnectActions.takeOver(context);
        expect(forwarded, 0);
        expect(
          playback.currentTrack?.uri,
          'spotify:track:synthetic0000000000000a',
        );
        expect(playback.position, const Duration(seconds: 30));
        expect(service.commands, ['pause:synthetic-speaker']);
        await unmount(tester);
      },
    );

    testWidgets(
      'pending receiver takeover routes new songs locally and deduplicates taps',
      (tester) async {
        await pumpHost(
          tester,
          const Size(390, 844),
          const SizedBox(),
          cluster: syntheticCluster(),
        );
        final connect = tester
            .element(find.byType(Scaffold))
            .read<ConnectProvider>();
        connect.receiverDeviceId = 'synthetic-phone';
        service.transferGate = Completer<void>();
        final first = connect.transferToReceiver();
        final second = connect.transferToReceiver();
        expect(identical(first, second), isTrue);
        expect(connect.activeDevice, isNull);
        await connect.playOnReceiver(
          const ConnectPlayRequest(
            trackUris: ['spotify:track:new'],
            trackUri: 'spotify:track:new',
          ),
        );
        service.transferGate!.complete();
        await first;
        expect(service.commands, [
          'transfer:synthetic-phone',
          'play:synthetic-phone',
        ]);
        await unmount(tester);
      },
    );

    Widget opener() => Builder(
      builder: (context) => TextButton(
        onPressed: () => DevicePickerSheet.show(context),
        child: const Text('open'),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(1280, 800),
    ]) {
      testWidgets(
        'lists devices without overflow at ${size.width.round()} wide',
        (tester) async {
          await pumpHost(
            tester,
            size,
            opener(),
            cluster: syntheticCluster(),
            fontScale: 1.3,
          );
          await open(tester);
          expect(find.byType(DevicePickerSheet), findsOneWidget);
          expect(find.text('Synthetic Phone'), findsOneWidget);
          expect(find.text(zh.connectThisDevice), findsOneWidget);
          expect(find.byType(Slider), findsOneWidget);
          expect(tester.takeException(), isNull);
          await unmount(tester);
        },
      );
    }

    testWidgets('tapping another device transfers playback and closes', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(1280, 800),
        opener(),
        cluster: syntheticCluster(),
      );
      await open(tester);
      await tester.tap(find.text('Synthetic Phone'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(service.commands, ['transfer:synthetic-phone']);
      expect(find.byType(DevicePickerSheet), findsNothing);
      await unmount(tester);
    });

    testWidgets('empty state when no other device is online', (tester) async {
      await pumpHost(
        tester,
        const Size(390, 844),
        opener(),
        cluster: const ConnectCluster(serverTimestampMs: 1),
      );
      await open(tester);
      expect(find.text(zh.connectNoDevices), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('unavailable for non-desktop sessions', (tester) async {
      await pumpHost(tester, const Size(390, 844), opener(), available: false);
      await open(tester);
      expect(find.text(zh.connectUnavailable), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('connecting status line', (tester) async {
      await pumpHost(tester, const Size(390, 844), opener());
      service.setStatus(ConnectStatus.connecting);
      await open(tester);
      expect(find.text(zh.connectConnecting), findsOneWidget);
      await unmount(tester);
    });
  });

  group('remote lyrics', () {
    const remoteTitle = 'A Synthetic Remote Track With A Fairly Long Title';

    testWidgets('remote mini title restarts after closing the full player', (
      tester,
    ) async {
      await pumpHost(
        tester,
        const Size(390, 844),
        const MiniPlayer(),
        cluster: syntheticCluster(playing: false),
      );
      double titleOffset() {
        final title = find.descendant(
          of: find.byType(RemoteMiniPlayer),
          matching: find.byType(MarqueeText),
        );
        final scroll = find.descendant(
          of: title,
          matching: find.byType(SingleChildScrollView),
        );
        return tester.widget<SingleChildScrollView>(scroll).controller!.offset;
      }

      await tester.pump(const Duration(milliseconds: 4500));
      expect(titleOffset(), greaterThan(0));
      await tester.tap(find.byType(RemoteMiniPlayer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await tester.pump();
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(FullPlayerSheet), findsNothing);
      expect(titleOffset(), 0);
      await tester.pump(const Duration(seconds: 3));
      expect(titleOffset(), 0);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(titleOffset(), greaterThan(0));
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets(
      'tapping the remote capsule opens the full player with remote controls',
      (tester) async {
        await pumpHost(
          tester,
          const Size(390, 844),
          const MiniPlayer(),
          cluster: syntheticCluster(playing: false),
        );
        await tester.tap(find.byType(RemoteMiniPlayer));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 650));

        final player = find.byType(FullPlayerSheet);
        expect(player, findsOneWidget);
        expect(
          find.descendant(
            of: player,
            matching: find.byWidgetPredicate(
              (widget) => widget is MarqueeText && widget.text == remoteTitle,
            ),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        // 全屏播放器的播放键发给远程设备，而不是本机
        await tester.tap(
          find.descendant(
            of: player,
            matching: find.byIcon(Icons.play_arrow_rounded),
          ),
        );
        await tester.pump();
        expect(service.commands, ['resume:synthetic-speaker']);
        await unmount(tester);
      },
    );

    testWidgets('remote position drives the lyrics clock', (tester) async {
      await pumpHost(
        tester,
        const Size(390, 844),
        const SizedBox(),
        cluster: syntheticCluster(),
      );
      final connect = Provider.of<ConnectProvider>(
        tester.element(find.byType(Scaffold)),
        listen: false,
      );
      // 快照：30s @ 服务端 1000000；服务端时间以快照为准，推算结果即快照进度
      expect(connect.position.value, const Duration(seconds: 30));
      expect(connect.displayTrack?.name, remoteTitle);
      await unmount(tester);
    });
  });

  group('immersive lyrics', () {
    Widget opener() => Builder(
      builder: (context) => TextButton(
        onPressed: () => ImmersiveLyricsScreen.open(context),
        child: const Text('immersive'),
      ),
    );

    testWidgets(
      'opens fitted to the window; F11 switches to the whole screen and is remembered',
      (tester) async {
        await pumpHost(
          tester,
          const Size(1280, 800),
          opener(),
          cluster: syntheticCluster(),
        );
        await tester.tap(find.text('immersive'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(find.byType(ImmersiveLyricsScreen), findsOneWidget);
        expect(
          find.text('A Synthetic Remote Track With A Fairly Long Title'),
          findsWidgets,
        );
        expect(DesktopWindow.immersiveWindow.value, isTrue);
        expect(storage.immersiveScreenFullscreen, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        await tester.pump();
        expect(DesktopWindow.immersiveWindow.value, isFalse);
        expect(storage.immersiveScreenFullscreen, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(ImmersiveLyricsScreen), findsNothing);
        expect(DesktopWindow.immersiveWindow.value, isFalse);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      },
    );

    testWidgets(
      'lyrics / queue buttons switch the shared scene view; closing both returns to the artwork',
      (tester) async {
        await pumpHost(
          tester,
          const Size(1280, 800),
          opener(),
          cluster: syntheticCluster(),
        );
        await tester.tap(find.text('immersive'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        final screen = find.byType(ImmersiveLyricsScreen);
        expect(
          find.descendant(of: screen, matching: find.byType(LyricsView)),
          findsOneWidget,
        );

        // 切到播放队列
        await tester.tap(
          find.descendant(
            of: screen,
            matching: find.byIcon(Icons.queue_music_rounded),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(
          find.descendant(of: screen, matching: find.byType(LyricsView)),
          findsNothing,
        );
        expect(
          find.descendant(of: screen, matching: find.byType(QueueList)),
          findsOneWidget,
        );

        // 打开队列后控制卡片会自动收起。悬停和滚轮不再展开，要点卡片本身。
        await tester.tap(find.byKey(const ValueKey('lyrics-control-card')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        // 再点一次回到封面
        await tester.tap(
          find.descendant(
            of: screen,
            matching: find.byIcon(Icons.queue_music_rounded),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(
          find.descendant(of: screen, matching: find.byType(QueueList)),
          findsNothing,
        );
        final card = tester.getRect(
          find.byKey(const ValueKey('lyrics-control-card')),
        );
        final art = tester.getCenter(
          find.descendant(of: screen, matching: find.byType(CoverImage)).first,
        );
        // 沉浸页控制卡片在左，大封面在右侧内容区居中（与卡片间隔 48）
        expect(art.dx, greaterThan(card.right));
        expect(art.dx, closeTo((card.right + 48 + 1280) / 2, 2));
        expect(tester.takeException(), isNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await unmount(tester);
      },
    );
  });
}
