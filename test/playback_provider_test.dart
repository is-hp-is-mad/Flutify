import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/playback_retry.dart';
import 'package:flutify_app/models/playback_state.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/auth/login_region_check.dart';
import 'package:flutify_app/services/playback/playback_region_gate.dart';
import 'package:flutify_app/services/protocol/track_playback_exception.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

void main() {
  late FakeAudioPlayerService audio;
  late FakeTrackAudioSource loader;
  late PlaybackProvider playback;

  const a = SampleCatalog.track1;
  const b = SampleCatalog.track2;
  const c = SampleCatalog.track3;
  const x = SampleCatalog.track4;
  const ctx = PlaybackContext.playlist('Test', uri: 'spotify:playlist:test');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    audio = FakeAudioPlayerService();
    loader = FakeTrackAudioSource();
    playback = PlaybackProvider(
      audio,
      storage,
      random: Random(42),
      audioLoader: loader,
    );
  });

  tearDown(() => playback.dispose());

  test('position updates do not trigger ChangeNotifier rebuilds', () {
    var notifications = 0;
    var positionUpdates = 0;
    playback.addListener(() => notifications++);
    playback.positionNotifier.addListener(() => positionUpdates++);

    for (var i = 1; i <= 20; i++) {
      audio.positionController.add(Duration(milliseconds: i * 200));
    }

    expect(notifications, 0);
    expect(positionUpdates, 20);
    expect(playback.position, const Duration(milliseconds: 4000));
  });

  test('user queue plays before the rest of the context', () async {
    await playback.playTrack(a, contextQueue: [a, b, c], context: ctx);
    playback.addToQueue(x);

    expect(playback.userQueue.map((e) => e.track.id), [x.id]);
    expect(playback.upNext.map((e) => e.track.id), [b.id, c.id]);

    await playback.nextTrack();
    expect(playback.currentTrack?.id, x.id);
    expect(playback.userQueue, isEmpty);

    await playback.nextTrack();
    expect(playback.currentTrack?.id, b.id);
  });

  group('remotePlay hook', () {
    test(
      'late remote failure cannot override a newer local track or pause',
      () async {
        final response = Completer<bool>();
        playback.remotePlay = (_, _, _) => response.future;
        final pending = playback.playTrack(a);
        await playback.playLocal(b);
        response.complete(false);
        await pending;
        expect(playback.currentTrack?.id, b.id);
        expect(loader.loaded, [b.id]);

        final contextResponse = Completer<bool>();
        playback.remotePlay = (_, _, _) => contextResponse.future;
        final pendingContext = playback.playContext([a, c], ctx);
        await playback.pause();
        contextResponse.complete(false);
        await pendingContext;
        expect(loader.loaded, [b.id]);
        expect(audio.isPlaying, isFalse);
      },
    );

    test('handled remotely: nothing is loaded or played locally', () async {
      final calls = <(PlaybackContext, String, String?)>[];
      playback.remotePlay = (context, tracks, start) async {
        calls.add((context, tracks.map((t) => t.id).join(','), start?.id));
        return true;
      };

      await playback.playTrack(b, contextQueue: [a, b, c], context: ctx);
      await playback.playContext([a, b, c], ctx);

      final ids = [a.id, b.id, c.id].join(',');
      expect(calls, [(ctx, ids, b.id), (ctx, ids, null)]);
      expect(loader.loaded, isEmpty);
      expect(playback.currentTrack, isNull);
    });

    test('经 Connect 点歌时随请求带上默认循环方式（切换歌单 / 从头播放），同一歌单内点歌沿用当前', () async {
      playback.updateDefaultRepeatMode(SpotifyRepeatMode.context);
      playback.setRepeatMode(SpotifyRepeatMode.off); // 例如被服务端上一次的状态改掉
      final seen = <SpotifyRepeatMode>[];
      playback.remotePlay = (_, _, _) async {
        seen.add(playback.repeatModeForNextPlay);
        return true;
      };

      await playback.playTrack(b, contextQueue: [a, b, c], context: ctx);
      await playback.playContext([a, b, c], ctx);
      expect(seen, [SpotifyRepeatMode.context, SpotifyRepeatMode.context]);
      // 交给远程后不残留：之后读到的是当前循环方式
      expect(playback.repeatModeForNextPlay, SpotifyRepeatMode.off);

      // 同一歌单内换歌（本机在播 ctx）不重置为默认
      playback.remotePlay = null;
      await playback.playTrack(a, contextQueue: [a, b, c], context: ctx);
      playback.setRepeatMode(SpotifyRepeatMode.track);
      playback.remotePlay = (_, _, _) async {
        seen.add(playback.repeatModeForNextPlay);
        return true;
      };
      await playback.playTrack(b, contextQueue: [a, b, c], context: ctx);
      expect(seen.last, SpotifyRepeatMode.track);
    });

    test('declined: plays locally as usual', () async {
      playback.remotePlay = (_, _, _) async => false;

      await playback.playTrack(b, contextQueue: [a, b, c], context: ctx);

      expect(playback.currentTrack?.id, b.id);
      expect(playback.upNext.map((e) => e.track.id), [c.id]);
    });
  });

  test('previous selects the previous track even after 3 seconds', () async {
    await playback.playTrack(b, contextQueue: [a, b, c], context: ctx);
    audio.positionController.add(const Duration(seconds: 10));

    await playback.previousTrack();
    expect(playback.currentTrack?.id, a.id);
  });

  test(
    'receiver queue expands without reloading and retains history and local tail',
    () async {
      await playback.playLocal(b, contextQueue: [a, b]);
      audio.positionController.add(const Duration(seconds: 10));
      playback.setRepeatMode(SpotifyRepeatMode.context);
      playback.updateReceiverQueue([b, c, x]);
      playback.updateReceiverQueue([b, c]);
      expect(playback.upNext.map((e) => e.track.id), [c.id, x.id]);
      expect(loader.loaded, [b.id]);
      expect(playback.position, const Duration(seconds: 10));
      expect(playback.repeatMode, SpotifyRepeatMode.context);
      await playback.previousTrack();
      expect(playback.currentTrack?.id, a.id);
    },
  );

  test(
    'receiver queue end continues with the state machine instead of wrapping',
    () async {
      await playback.playLocal(a, contextQueue: [a, b]);
      playback.setRepeatMode(SpotifyRepeatMode.context);
      await playback.nextTrack();
      expect(playback.currentTrack?.id, b.id);
      playback.receiverWindow = () => [b, c, x];

      await playback.nextTrack();

      expect(playback.currentTrack?.id, c.id);
      expect(playback.upNext.map((e) => e.track.id), [x.id]);
    },
  );

  test('receiver context is remembered, unknown URIs are ignored', () async {
    await playback.playLocal(a, contextQueue: [a, b]);
    expect(playback.playbackContext.uri, isEmpty);
    playback.adoptReceiverContext('spotify:internal:temp');
    expect(playback.playbackContext.uri, isEmpty);
    playback.adoptReceiverContext('spotify:user:me:collection');
    expect(playback.playbackContext.uri, 'spotify:user:me:collection');
  });

  test('without a receiver window the queue end still wraps', () async {
    await playback.playLocal(a, contextQueue: [a, b]);
    playback.setRepeatMode(SpotifyRepeatMode.context);
    await playback.nextTrack();
    playback.receiverWindow = () => const [];

    await playback.nextTrack();

    expect(playback.currentTrack?.id, a.id);
  });

  test(
    'receiver update ignores stale current tracks and replaces a changed future',
    () async {
      await playback.playLocal(a, contextQueue: [a, b, c]);
      playback.updateReceiverQueue([b, x]);
      expect(playback.upNext.map((e) => e.track.id), [b.id, c.id]);
      playback.addToQueue(b);
      playback.updateReceiverQueue([a, x]);
      expect(playback.upNext.map((e) => e.track.id), [x.id]);
      expect(playback.userQueue.single.track.id, b.id);
    },
  );

  test(
    'receiver update during a queued song keeps history and context tail',
    () async {
      await playback.playLocal(a, contextQueue: [a, b, c]);
      playback.addToQueue(x);
      await playback.nextTrack();
      playback.updateReceiverQueue([x, b]);

      expect(playback.currentTrack?.id, x.id);
      expect(playback.upNext.map((e) => e.track.id), [b.id, c.id]);
      expect(loader.loaded, [a.id, x.id]);
      await playback.previousTrack();
      expect(playback.currentTrack?.id, a.id);
    },
  );

  test(
    'shuffle keeps the current track and queues every other track once',
    () async {
      await playback.playTrack(b, contextQueue: [a, b, c, x], context: ctx);
      playback.toggleShuffle();

      expect(playback.currentTrack?.id, b.id);
      final upNextIds = playback.upNext.map((e) => e.track.id).toSet();
      expect(upNextIds, {a.id, c.id, x.id});

      playback.toggleShuffle();
      expect(playback.upNext.map((e) => e.track.id), [c.id, x.id]);
    },
  );

  test('repeat context wraps around, repeat off stops at the end', () async {
    await playback.playTrack(c, contextQueue: [a, b, c], context: ctx);
    expect(playback.canSkipNext, isFalse);

    await playback.nextTrack();
    expect(
      playback.currentTrack?.id,
      c.id,
      reason: 'repeat off: stays on last track',
    );

    playback.cycleRepeatMode();
    expect(playback.repeatMode, SpotifyRepeatMode.context);
    expect(
      playback.canSkipNext,
      isTrue,
      reason: 'SMTC must enable next when context repeat can wrap',
    );
    await playback.nextTrack();
    expect(playback.currentTrack?.id, a.id);
  });

  group('autoplay', () {
    const radio = PlaybackContext.playlist(
      'Radio',
      uri: 'spotify:playlist:radio',
    );
    final seeds = <String>[];

    setUp(() {
      seeds.clear();
      playback.autoplaySource = (seed) async {
        seeds.add(seed.id);
        // 电台里常带种子曲目本身，应被去掉
        return (tracks: [seed, x, a], context: radio);
      };
    });

    test('列表播完后以最后一首为种子播放相似歌曲', () async {
      expect(playback.autoplay, isTrue);
      await playback.playTrack(c, contextQueue: [a, b, c], context: ctx);

      await playback.nextTrack();

      expect(seeds, [c.id]);
      expect(playback.currentTrack?.id, x.id);
      expect(playback.upNext.map((e) => e.track.id), [a.id]);
    });

    test('关闭后停在最后一首，且设置持久化', () async {
      playback.setAutoplay(false);
      expect((await StorageService.init()).autoplay, isFalse);
      await playback.playTrack(c, contextQueue: [a, b, c], context: ctx);

      await playback.nextTrack();

      expect(seeds, isEmpty);
      expect(playback.currentTrack?.id, c.id);
    });

    test('循环模式不触发；未到末尾不触发', () async {
      await playback.playTrack(b, contextQueue: [a, b, c], context: ctx);
      await playback.nextTrack();
      expect(playback.currentTrack?.id, c.id);

      playback.cycleRepeatMode();
      await playback.nextTrack();
      expect(playback.currentTrack?.id, a.id);
      expect(seeds, isEmpty);
    });

    test('取不到相似歌曲时照旧停在最后一首', () async {
      playback.autoplaySource = (_) async => throw Exception('offline');
      await playback.playTrack(c, contextQueue: [a, b, c], context: ctx);

      await playback.nextTrack();

      expect(playback.currentTrack?.id, c.id);
    });

    test('等待期间用户点了别的歌：不覆盖', () async {
      final pending = Completer<void>();
      playback.autoplaySource = (seed) async {
        await pending.future;
        return (tracks: [x], context: radio);
      };
      await playback.playTrack(c, contextQueue: [a, b, c], context: ctx);

      final ending = playback.nextTrack();
      await playback.playTrack(a, contextQueue: [a, b], context: ctx);
      pending.complete();
      await ending;

      expect(playback.currentTrack?.id, a.id);
    });
  });

  test('duplicate completed events only advance once', () async {
    await playback.playTrack(a, contextQueue: [a, b, c], context: ctx);
    audio.emitCompleted();
    audio.emitCompleted();
    await Future<void>.delayed(Duration.zero);

    expect(playback.currentTrack?.id, b.id);
  });

  test(
    'up next can be reordered and trimmed without touching the context',
    () async {
      await playback.playTrack(a, contextQueue: [a, b, c, x], context: ctx);

      playback.reorderUpNext(2, 0);
      expect(playback.upNext.map((e) => e.track.id), [x.id, b.id, c.id]);

      playback.removeFromUpNext(1);
      expect(playback.upNext.map((e) => e.track.id), [x.id, c.id]);

      await playback.playFromUpNext(1);
      expect(playback.currentTrack?.id, c.id);
      expect(playback.upNext, isEmpty);
    },
  );

  test('isPlayingContext reflects the active context uri', () async {
    await playback.playTrack(a, contextQueue: [a, b], context: ctx);
    audio.stateController.add(PlayerState(true, ProcessingState.ready));

    expect(playback.isPlayingContext(ctx.uri), isTrue);
    expect(playback.isPlayingContext('spotify:album:other'), isFalse);
  });

  test('switching playlists applies defaultRepeatMode even after manual repeat change', () async {
    const otherCtx = PlaybackContext.playlist(
      'Other',
      uri: 'spotify:playlist:other',
    );
    playback.updateDefaultRepeatMode(SpotifyRepeatMode.context);
    await playback.playTrack(a, contextQueue: [a, b], context: ctx);
    expect(playback.repeatMode, SpotifyRepeatMode.context);

    // 在当前歌单内手动切到单曲循环：同歌单内点歌保留单曲循环
    playback.cycleRepeatMode();
    expect(playback.repeatMode, SpotifyRepeatMode.track);
    await playback.playTrack(b, contextQueue: [a, b], context: ctx);
    expect(playback.repeatMode, SpotifyRepeatMode.track);

    // 切换到新歌单：默认循环方式重新生效
    await playback.playTrack(c, contextQueue: [c, x], context: otherCtx);
    expect(playback.repeatMode, SpotifyRepeatMode.context);
  });

  group('播放错误', () {
    testWidgets('offline backs off, replays once, then stops', (tester) async {
      loader.failures[a.id] = const SocketException('Network is unreachable');
      final attempts = <int>[];
      playback.retryNotifier.addListener(() {
        final retry = playback.retryNotifier.value;
        if (retry != null && !retry.waiting) attempts.add(retry.attempt);
      });
      final pending = playback.playTrack(a, contextQueue: [a, b], context: ctx);
      await tester.pump();
      expect(loader.loaded, [a.id]);

      // 第一轮：退避等待逐次加长（1+2+…+limit 秒）。
      for (var i = 1; i <= PlaybackRetry.limit; i++) {
        expect(playback.retryNotifier.value?.attempt, i);
        expect(playback.retryNotifier.value?.delay, Duration(seconds: i));
        await tester.pump(Duration(milliseconds: i * 1000 - 1));
        expect(loader.loaded.length, i);
        await tester.pump(const Duration(milliseconds: 1));
      }
      // 预算用光：整首歌重放一次（第 limit+2 次加载），它接着的那次退避
      // 也已经开始计时（此时读到的 attempt 是第二轮退避的第 1 拍）。
      expect(loader.loaded.length, PlaybackRetry.limit + 2);
      expect(playback.retryNotifier.value?.attempt, 1);
      expect(playback.retryNotifier.value?.waiting, isTrue);
      expect(playback.currentTrack?.id, a.id);

      // 第二轮：重放的这一轮退避（1+2+…+limit 秒）。
      for (var i = 1; i <= PlaybackRetry.limit; i++) {
        expect(playback.retryNotifier.value?.attempt, i);
        expect(playback.retryNotifier.value?.delay, Duration(seconds: i));
        await tester.pump(Duration(milliseconds: i * 1000 - 1));
        expect(loader.loaded.length, PlaybackRetry.limit + 1 + i);
        await tester.pump(const Duration(milliseconds: 1));
      }
      await pending;

      // 两轮后收手（每轮 1 次首载 + limit 次退避重试）：不再自己重放，把预算留给用户点「重试」。
      expect(
        loader.loaded.length,
        (1 + PlaybackRetry.limit) * 2,
        reason: '退避重试一轮后重放，重放一轮后收手，不能越挫越勇',
      );
      expect(playback.currentTrack?.id, a.id);
      expect(playback.playbackError?.kind, TrackPlaybackFailure.network);
      expect(playback.retryNotifier.value, isNull);
      expect(playback.isBuffering, isFalse);
      expect(
        attempts,
        List.generate(
          PlaybackRetry.limit * 2,
          (i) => i % PlaybackRetry.limit + 1,
        ),
      );
      await tester.pump(const Duration(minutes: 1));
      expect(
        loader.loaded.length,
        (1 + PlaybackRetry.limit) * 2,
        reason: '报错之后再等多久也不会自己再来一轮',
      );
    });

    testWidgets(
      'connection recovery plays the same song at the requested position',
      (tester) async {
        loader.failures[a.id] = const SocketException('Failed host lookup');
        final pending = playback.playTrack(a);
        await tester.pump();
        await playback.seekTo(const Duration(seconds: 12));
        loader.failures.clear();
        await tester.pump(const Duration(seconds: 1));
        await pending;
        expect(loader.loaded, [a.id, a.id]);
        expect(audio.playedFiles, hasLength(1));
        expect(playback.position, const Duration(seconds: 12));
        expect(playback.retryNotifier.value, isNull);
        expect(playback.playbackError, isNull);
      },
    );

    testWidgets('pause and changing track cancel a pending retry', (
      tester,
    ) async {
      loader.failures[a.id] = const SocketException('Network is unreachable');
      final pending = playback.playTrack(a);
      await tester.pump();
      await playback.togglePlayPause();
      await pending;
      await tester.pump(const Duration(seconds: 20));
      expect(loader.loaded, [a.id]);
      expect(playback.retryNotifier.value, isNull);
      expect(playback.isBuffering, isFalse);

      final again = playback.togglePlayPause();
      await tester.pump();
      await playback.playTrack(b);
      await again;
      await tester.pump(const Duration(seconds: 20));
      expect(loader.loaded, [a.id, a.id, b.id]);
      expect(playback.currentTrack?.id, b.id);
    });

    testWidgets('sign out cancels offline retry and clears playback', (
      tester,
    ) async {
      loader.failures[a.id] = const SocketException('Network is unreachable');
      final pending = playback.playTrack(a);
      await tester.pump();
      await playback.discardSession();
      await pending;
      await tester.pump(const Duration(seconds: 20));
      expect(loader.loaded, [a.id]);
      expect(playback.currentTrack, isNull);
      expect(playback.retryNotifier.value, isNull);
      expect(audio.isPlaying, isFalse);
    });

    const unavailable = TrackPlaybackException(
      TrackPlaybackFailure.unavailable,
      '这首歌仅提供 DRM 加密格式',
    );

    test('成功加载后播放本地文件，无错误', () async {
      await playback.playTrack(a, contextQueue: [a, b], context: ctx);

      expect(loader.loaded, [a.id]);
      expect(audio.playedFiles, hasLength(1));
      expect(playback.playbackError, isNull);
      expect(playback.isBuffering, isFalse);
      expect(loader.prefetched, [b.id], reason: '开始播放后预取下一首');
    });

    test('不可播放的曲目：暴露错误并自动跳到下一首', () async {
      loader.failures[a.id] = unavailable;
      final events = <PlaybackError>[];
      final sub = playback.playbackErrors.listen(events.add);

      await playback.playTrack(a, contextQueue: [a, b, c], context: ctx);
      await Future<void>.delayed(Duration.zero);

      expect(playback.currentTrack?.id, b.id);
      expect(audio.playedFiles, hasLength(1));
      // 自动跳过时保留错误，UI 能读到「哪首被跳过、为什么」
      final error = playback.playbackError!;
      expect(error.track.id, a.id);
      expect(error.kind, TrackPlaybackFailure.unavailable);
      expect(error.skipped, isTrue);
      expect(error.messageWithTrack, contains(a.name));
      expect(events.map((e) => e.track.id), [a.id]);
      await sub.cancel();
    });

    test('最后一首不可播放时不再跳，错误保留', () async {
      loader.failures[b.id] = unavailable;

      await playback.playTrack(b, contextQueue: [a, b], context: ctx);

      expect(playback.currentTrack?.id, b.id);
      expect(playback.playbackError?.skipped, isFalse);
      expect(audio.playedFiles, isEmpty);
      expect(playback.isBuffering, isFalse);
    });

    test('连续多首都不可播放：跳过次数有上限，不会死循环', () async {
      for (final t in [a, b, c]) {
        loader.failures[t.id] = unavailable;
      }
      playback.cycleRepeatMode(); // 循环播放上下文：本可以无限绕圈

      await playback.playTrack(a, contextQueue: [a, b, c], context: ctx);

      expect(loader.loaded.length, lessThanOrEqualTo(4));
      expect(playback.playbackError, isNotNull);
      expect(playback.isBuffering, isFalse);
    });

    test('连续 3 首不可播放：停在第 3 首并标记自动暂停；「下一首」可继续', () async {
      for (final t in [a, b, c]) {
        loader.failures[t.id] = unavailable;
      }
      final events = <PlaybackError>[];
      final sub = playback.playbackErrors.listen(events.add);

      await playback.playTrack(a, contextQueue: [a, b, c, x], context: ctx);
      await Future<void>.delayed(Duration.zero);

      expect(playback.pauseAfterFailures, isTrue, reason: '默认开启');
      expect(playback.currentTrack?.id, c.id, reason: '第 3 首失败后不再跳到第 4 首');
      expect(audio.playedFiles, isEmpty);
      expect(
        events.map((e) => (e.skipped, e.autoPaused, e.consecutiveFailures)),
        [(true, false, 1), (true, false, 2), (false, true, 3)],
      );

      await playback.nextTrack();
      expect(playback.currentTrack?.id, x.id);
      expect(audio.playedFiles, hasLength(1));
      await sub.cancel();
    });

    test('关闭「连续无法播放时暂停」：继续跳过直到可播放的曲目，并持久化', () async {
      for (final t in [a, b, c]) {
        loader.failures[t.id] = unavailable;
      }
      playback.setPauseAfterFailures(false);

      await playback.playTrack(a, contextQueue: [a, b, c, x], context: ctx);
      await Future<void>.delayed(Duration.zero);

      expect(playback.currentTrack?.id, x.id);
      expect(audio.playedFiles, hasLength(1));
      final reloaded = PlaybackProvider(
        audio,
        await StorageService.init(),
        audioLoader: loader,
      );
      addTearDown(reloaded.dispose);
      expect(reloaded.pauseAfterFailures, isFalse);
    });

    test('未登录（无加载器）：提示请先登录，不跳歌', () async {
      SharedPreferences.setMockInitialValues({});
      final bare = PlaybackProvider(audio, await StorageService.init());
      addTearDown(bare.dispose);

      await bare.playTrack(a, contextQueue: [a, b], context: ctx);

      expect(bare.currentTrack?.id, a.id);
      expect(bare.playbackError?.kind, TrackPlaybackFailure.notSignedIn);
      expect(bare.playbackError?.skipped, isFalse);
    });

    test('网络错误不跳歌；再点播放会重试并清除错误', () async {
      loader.failures[a.id] = const TrackPlaybackException(
        TrackPlaybackFailure.network,
        '网络异常',
      );

      await playback.playTrack(a, contextQueue: [a, b], context: ctx);
      expect(playback.currentTrack?.id, a.id);
      expect(playback.playbackError?.kind, TrackPlaybackFailure.network);

      loader.failures.clear();
      await playback.togglePlayPause();

      expect(playback.playbackError, isNull);
      expect(audio.playedFiles, hasLength(1));
    });

    test('非 TrackPlaybackException 的意外错误被归为网络类提示', () async {
      loader.failures[a.id] = StateError('boom');

      await playback.playTrack(a, contextQueue: [a], context: ctx);

      expect(playback.playbackError?.kind, TrackPlaybackFailure.network);
    });

    test('clearPlaybackError 清除错误并通知', () async {
      loader.failures[a.id] = unavailable;
      await playback.playTrack(a, contextQueue: [a], context: ctx);
      var notified = 0;
      playback.addListener(() => notified++);

      playback.clearPlaybackError();

      expect(playback.playbackError, isNull);
      expect(notified, 1);
    });

    test('用户主动换歌会清除上一首的错误', () async {
      loader.failures[a.id] = unavailable;
      await playback.playTrack(a, contextQueue: [a], context: ctx);
      expect(playback.playbackError, isNotNull);

      await playback.playTrack(b, contextQueue: [b], context: ctx);
      expect(playback.playbackError, isNull);
    });

    test('不可用标记的曲目（isPlayable=false）直接判为不可播放', () async {
      final blocked = a.copyWith(isPlayable: false);

      await playback.playTrack(blocked, contextQueue: [blocked], context: ctx);

      expect(loader.loaded, isEmpty, reason: '不应为不可播放曲目发起下载');
      expect(playback.playbackError?.kind, TrackPlaybackFailure.unavailable);
    });

    test('出口在中国大陆时拦截起播，网络变动切回大陆时暂停正在播放的曲目', () async {
      LoginRegionCheck.resetForTest();
      addTearDown(LoginRegionCheck.resetForTest);
      var code = 'CN';
      final gate = PlaybackRegionGate(
        probe: () async => LoginRegion(code),
      );
      final gated = PlaybackProvider(
        audio,
        await StorageService.init(),
        audioLoader: loader,
        regionGate: gate,
      );
      addTearDown(gated.dispose);

      await gated.playTrack(a, contextQueue: [a, b], context: ctx);
      expect(loader.loaded, isEmpty, reason: '出口在 CN 时不加载音频');
      expect(gated.currentTrack?.id, a.id);
      expect(gated.playbackError?.kind, TrackPlaybackFailure.regionBlocked);
      expect(gated.isPlaybackActive, isFalse);

      // 切换节点到海外：点播放正常加载并出声
      code = 'JP';
      gate.markNetworkChanged();
      await gated.togglePlayPause();
      expect(loader.loaded, [a.id]);
      expect(gated.playbackError, isNull);
      expect(gated.isPlaybackActive, isTrue);

      // 播放中途网络变动切回 CN：实时复检并自动暂停
      code = 'CN';
      gate.markNetworkChanged();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(gated.playbackError?.kind, TrackPlaybackFailure.regionBlocked);
      expect(gated.isPlaybackActive, isFalse);
      expect(audio.isPlaying, isFalse);
    });
  });
}
