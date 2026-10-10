import 'dart:async';

import 'package:audio_service/audio_service.dart' as service;
import 'package:flutify_app/models/playback_state.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/media_controls/audio_service_media_controls.dart';
import 'package:flutify_app/services/media_controls/media_controls_sync.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

/// Deterministic boundary for network work or native source preparation.
class _Gate {
  final entered = Completer<void>();
  final _released = Completer<void>();

  Future<void> wait() {
    entered.complete();
    return _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

class _DelayedSource extends FakeTrackAudioSource {
  String? delayedTrackId;
  _Gate? gate;

  _Gate delayNext(String trackId) {
    delayedTrackId = trackId;
    return gate = _Gate();
  }

  @override
  Future<LoadedAudio> open(String id, {void Function(double)? progress}) async {
    if (id == delayedTrackId) {
      delayedTrackId = null;
      await gate!.wait();
    }
    return super.open(id, progress: progress);
  }
}

/// Unlike the basic fake, publishes the paused/loading/ready native events
/// emitted when replacing a source with autoplay disabled. These must not turn
/// an automatic transition into a pause in the Android media session.
class _PreparingAudio extends FakeAudioPlayerService {
  ProcessingState _processingState = ProcessingState.idle;
  _Gate? preparation;
  _Gate? pendingSeek;
  _Gate? pendingStart;
  int _startGeneration = 0;
  Object? startFailure;
  Object? pauseFailure;
  bool idempotentPlay = false;

  @override
  Future<void> playFile(
    String path, {
    Duration? initialPosition,
    bool autoplay = true,
  }) async {
    _processingState = ProcessingState.loading;
    stateController.add(PlayerState(false, _processingState));
    final pending = preparation;
    if (pending != null) {
      await pending.wait();
      preparation = null;
    }
    await super.playFile(
      path,
      initialPosition: initialPosition,
      autoplay: autoplay,
    );
    _processingState = ProcessingState.ready;
    stateController.add(PlayerState(isPlaying, _processingState));
  }

  @override
  Future<void> play() async {
    if (idempotentPlay && isPlaying) return;
    final generation = ++_startGeneration;
    final pending = pendingStart;
    if (pending != null) {
      await pending.wait();
      pendingStart = null;
    }
    if (generation != _startGeneration) return;
    final failure = startFailure;
    if (failure != null) {
      startFailure = null;
      throw failure;
    }
    await super.play();
    stateController.add(PlayerState(isPlaying, _processingState));
  }

  @override
  Future<void> pause() async {
    ++_startGeneration;
    final failure = pauseFailure;
    if (failure != null) {
      pauseFailure = null;
      throw failure;
    }
    await super.pause();
    stateController.add(PlayerState(isPlaying, _processingState));
  }

  @override
  Future<void> seek(Duration position) async {
    final pending = pendingSeek;
    if (pending != null) {
      await pending.wait();
      pendingSeek = null;
    }
    await super.seek(position);
    if (_processingState == ProcessingState.completed) {
      _processingState = ProcessingState.ready;
      stateController.add(PlayerState(isPlaying, _processingState));
    }
  }

  @override
  void emitCompleted() {
    _processingState = ProcessingState.completed;
    stateController.add(PlayerState(isPlaying, _processingState));
  }
}

Future<void> _drainEvents() async {
  for (var turn = 0; turn < 6; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _PreparingAudio audio;
  late _DelayedSource source;
  late PlaybackProvider playback;
  late FlutifyAudioHandler handler;
  late MediaControlsSync sync;
  late StreamSubscription<service.PlaybackState> subscription;
  late List<service.PlaybackState> states;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    audio = _PreparingAudio();
    source = _DelayedSource();
    playback = PlaybackProvider(
      audio,
      await StorageService.init(),
      audioLoader: source,
    );
    handler = FlutifyAudioHandler();
    sync = MediaControlsSync(
      playback,
      AudioServiceMediaControls.withHandler(handler),
    );
    states = [];
    subscription = handler.playbackState.listen(states.add);
  });

  tearDown(() async {
    // Cancel any transition before unblocking its fake I/O, including after a
    // failing assertion, so it cannot outlive the test or disposed providers.
    await playback.pause();
    source.gate?.release();
    audio.preparation?.release();
    audio.pendingSeek?.release();
    audio.pendingStart?.release();
    await _drainEvents();
    await subscription.cancel();
    sync.dispose();
    playback.dispose();
    await handler.events.close();
  });

  Future<void> start({
    SpotifyTrack track = SampleCatalog.track1,
    List<SpotifyTrack> queue = const [
      SampleCatalog.track1,
      SampleCatalog.track2,
    ],
  }) async {
    await playback.playTrack(track, contextQueue: queue);
    await _drainEvents();
    expect(audio.isPlaying, isTrue);
    expect(handler.playbackState.value.playing, isTrue);
    states.clear();
  }

  void expectContinuous(List<service.PlaybackState> transition) {
    expect(handler.playbackState.value.playing, isTrue);
    expect(
      transition.map((state) => state.playing),
      everyElement(isTrue),
      reason:
          'Automatic continuation must retain playing intent throughout '
          'source loading/preparation. A false Android media-session state '
          'can release the foreground service and CPU wake lock.',
    );
  }

  test(
    'auto-next keeps Android playback active through network and native preparation',
    () async {
      await start();
      final network = source.delayNext(SampleCatalog.track2.id);
      final preparation = audio.preparation = _Gate();

      audio.emitCompleted();
      await network.entered.future.timeout(const Duration(seconds: 2));
      await _drainEvents();
      final networkState = handler.playbackState.value;
      expect(playback.currentTrack?.id, SampleCatalog.track2.id);
      expect(playback.isLoadingTrack, isTrue);

      network.release();
      await preparation.entered.future.timeout(const Duration(seconds: 2));
      await _drainEvents();
      final preparationState = handler.playbackState.value;
      preparation.release();
      await _drainEvents();

      expect(audio.isPlaying, isTrue);
      expect(playback.isLoadingTrack, isFalse);
      expect(playback.playbackError, isNull);
      expect(handler.mediaItem.value?.id, SampleCatalog.track2.id);
      expectContinuous(states);
      for (final state in [networkState, preparationState]) {
        expect(state.playing, isTrue);
        expect(state.processingState, service.AudioProcessingState.buffering);
        expect(
          state.speed,
          0,
          reason: 'The timeline must not advance while loading.',
        );
      }
      expect(handler.playbackState.value.speed, 1);
    },
  );

  for (final duringPreparation in [false, true]) {
    for (final systemPause in [false, true]) {
      final phase = duringPreparation
          ? 'native preparation'
          : 'network loading';
      final control = systemPause ? 'lock-screen pause' : 'explicit pause';
      test(
        '$control cancels auto-next during $phase without a late restart',
        () async {
          await start();
          final pending = duringPreparation
              ? (audio.preparation = _Gate())
              : source.delayNext(SampleCatalog.track2.id);
          audio.emitCompleted();
          await pending.entered.future.timeout(const Duration(seconds: 2));
          await _drainEvents();

          if (systemPause) {
            await handler.pause();
          } else {
            await playback.pause();
          }
          await _drainEvents();
          final stillLoadingAfterPause = playback.isLoadingTrack;
          final afterPause = handler.playbackState.value;
          states.clear();
          pending.release();
          await _drainEvents();

          expect(
            stillLoadingAfterPause,
            isFalse,
            reason: 'Pause must cancel the pending playback request.',
          );
          expect(afterPause.playing, isFalse);
          expect(audio.isPlaying, isFalse);
          expect(playback.isPlaying, isFalse);
          expect(handler.playbackState.value.playing, isFalse);
          expect(
            states.where((state) => state.playing),
            isEmpty,
            reason: 'Completing old I/O must not undo an explicit pause.',
          );
        },
      );
    }
  }

  test(
    'repeat-one preserves playback intent when seeking back to the start',
    () async {
      await start(queue: const [SampleCatalog.track1]);
      playback.setRepeatMode(SpotifyRepeatMode.track);
      states.clear();

      audio.emitCompleted();
      await _drainEvents();

      expect(playback.currentTrack?.id, SampleCatalog.track1.id);
      expect(audio.isPlaying, isTrue);
      expect(audio.seeks.last, Duration.zero);
      expectContinuous(states);
    },
  );

  test(
    'explicit pause during repeat-one seek prevents a late restart',
    () async {
      await start(queue: const [SampleCatalog.track1]);
      playback.setRepeatMode(SpotifyRepeatMode.track);
      final pending = audio.pendingSeek = _Gate();

      audio.emitCompleted();
      await pending.entered.future.timeout(const Duration(seconds: 2));
      await playback.pause();
      await _drainEvents();
      states.clear();
      pending.release();
      await _drainEvents();

      expect(audio.isPlaying, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      expect(states.where((state) => state.playing), isEmpty);
    },
  );

  test(
    'repeat-one with an idempotent player still respects native pause',
    () async {
      await start(queue: const [SampleCatalog.track1]);
      audio.idempotentPlay = true;
      playback.setRepeatMode(SpotifyRepeatMode.track);
      audio.emitCompleted();
      await _drainEvents();
      expectContinuous(states);
      await audio.pause();
      await _drainEvents();
      expect(playback.isPlaybackActive, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  for (final onCompletion in [false, true]) {
    test(
      'pause from a ${onCompletion ? 'completion' : 'resume'} listener wins',
      () async {
        await start();
        if (!onCompletion) await playback.pause();
        var cancelled = false;
        void cancelPendingStart() {
          if (!cancelled && !playback.isPlaying && playback.isPlaybackActive) {
            cancelled = true;
            unawaited(playback.pause());
          }
        }

        playback.addListener(cancelPendingStart);
        if (onCompletion) {
          audio.emitCompleted();
        } else {
          await playback.togglePlayPause();
        }
        await _drainEvents();
        playback.removeListener(cancelPendingStart);
        expect(cancelled, isTrue);
        expect(playback.currentTrack?.id, SampleCatalog.track1.id);
        expect(audio.isPlaying, isFalse);
        expect(handler.playbackState.value.playing, isFalse);
      },
    );
  }

  test('a newer resume from a pause listener is not overwritten', () async {
    await start();
    audio.idempotentPlay = true;
    var resumed = false;
    void resumeAfterPause() {
      if (!resumed && !playback.isPlaybackActive) {
        resumed = true;
        unawaited(playback.togglePlayPause());
      }
    }

    playback.addListener(resumeAfterPause);
    await playback.pause();
    await _drainEvents();
    playback.removeListener(resumeAfterPause);
    expect(resumed, isTrue);
    expect(audio.isPlaying, isTrue);
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.speed, 1);
  });

  test(
    'terminal next-track failure releases the Android playback session',
    () async {
      await start();
      source.failures[SampleCatalog.track2.id] = const TrackPlaybackException(
        TrackPlaybackFailure.notSignedIn,
        'Test session expired',
      );

      audio.emitCompleted();
      await _drainEvents();

      expect(playback.currentTrack?.id, SampleCatalog.track2.id);
      expect(playback.playbackError, isNotNull);
      expect(playback.isLoadingTrack, isFalse);
      expect(audio.isPlaying, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.speed, 0);
    },
  );

  for (final cancel in [false, true]) {
    test('pending native start retains intent; cancel=$cancel', () async {
      await start();
      final pending = audio.pendingStart = _Gate();
      audio.emitCompleted();
      await pending.entered.future.timeout(const Duration(seconds: 2));
      await _drainEvents();
      expect(playback.isLoadingTrack, isFalse);
      expect(playback.isPlaying, isFalse);
      audio.stateController.add(PlayerState(false, ProcessingState.ready));
      await _drainEvents();
      expectContinuous(states);
      expect(handler.playbackState.value.speed, 0);

      if (cancel) {
        await handler.pause();
        await _drainEvents();
        expect(handler.playbackState.value.playing, isFalse);
      }
      states.clear();
      pending.release();
      await _drainEvents();
      expect(audio.isPlaying, !cancel);
      expect(handler.playbackState.value.playing, !cancel);
      if (cancel) expect(states.where((state) => state.playing), isEmpty);
    });
  }

  for (final duringPause in [false, true]) {
    test(
      'failed ${duringPause ? 'internal pause' : 'native start'} releases intent',
      () async {
        await start();
        if (duringPause) {
          audio.pauseFailure = StateError('Native pause failed');
        } else {
          audio.startFailure = StateError('Native start failed');
        }
        audio.emitCompleted();
        await _drainEvents();
        expect(playback.playbackError, isNotNull);
        expect(playback.isPlaybackActive, isFalse);
        expect(handler.playbackState.value.playing, isFalse);
      },
    );
  }

  test(
    'native pause after an accepted buffering start releases intent',
    () async {
      await start();
      final pending = audio.pendingStart = _Gate();
      audio.emitCompleted();
      await pending.entered.future.timeout(const Duration(seconds: 2));
      await _drainEvents();
      audio.stateController.add(PlayerState(true, ProcessingState.buffering));
      await _drainEvents();
      expect(handler.playbackState.value.playing, isTrue);
      audio.stateController.add(PlayerState(false, ProcessingState.buffering));
      await _drainEvents();
      expect(playback.isPlaybackActive, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test('discarding a loading session clears playback intent', () async {
    await start();
    final pending = source.delayNext(SampleCatalog.track2.id);
    audio.emitCompleted();
    await pending.entered.future.timeout(const Duration(seconds: 2));
    await playback.discardSession();
    pending.release();
    await _drainEvents();
    expect(playback.currentTrack, isNull);
    expect(playback.isPlaybackActive, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
  });

  for (final systemPause in [false, true]) {
    test(
      '${systemPause ? 'system' : 'native engine'} pause after auto-next releases playback',
      () async {
        await start();
        audio.emitCompleted();
        await _drainEvents();
        expect(playback.currentTrack?.id, SampleCatalog.track2.id);
        expect(audio.isPlaying, isTrue);

        if (systemPause) {
          await handler.pause();
        } else {
          // Native pause can be caused by focus loss/interruption rather than
          // an explicit command through PlaybackProvider.
          await audio.pause();
        }
        await _drainEvents();

        expect(playback.isPlaying, isFalse);
        expect(handler.playbackState.value.playing, isFalse);
        expect(handler.playbackState.value.speed, 0);
      },
    );
  }

  for (final singleTrack in [false, true]) {
    test(
      'context repeat retains playback intent on ${singleTrack ? 'one-track' : 'end-of-queue'} wrap',
      () async {
        await start(
          track: singleTrack ? SampleCatalog.track1 : SampleCatalog.track2,
          queue: singleTrack
              ? const [SampleCatalog.track1]
              : const [SampleCatalog.track1, SampleCatalog.track2],
        );
        playback.setRepeatMode(SpotifyRepeatMode.context);
        final pending = source.delayNext(SampleCatalog.track1.id);
        states.clear();

        audio.emitCompleted();
        await pending.entered.future.timeout(const Duration(seconds: 2));
        await _drainEvents();
        final whileLoading = handler.playbackState.value;
        pending.release();
        await _drainEvents();

        expect(playback.currentTrack?.id, SampleCatalog.track1.id);
        expect(audio.isPlaying, isTrue);
        expectContinuous(states);
        expect(
          whileLoading.processingState,
          service.AudioProcessingState.buffering,
        );
      },
    );
  }

  test(
    'stop-after-current releases playback even when repeat-one is enabled',
    () async {
      await start();
      playback.setRepeatMode(SpotifyRepeatMode.track);
      playback.stopAfterCurrent = true;

      audio.emitCompleted();
      await _drainEvents();

      expect(playback.currentTrack?.id, SampleCatalog.track1.id);
      expect(playback.stopAfterCurrent, isFalse);
      expect(playback.isLoadingTrack, isFalse);
      expect(audio.isPlaying, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.speed, 0);
      expect(playback.position, Duration.zero);
    },
  );

  test(
    'queue exhaustion releases playback instead of retaining background work',
    () async {
      await start(queue: const [SampleCatalog.track1]);

      audio.emitCompleted();
      await _drainEvents();

      expect(playback.currentTrack?.id, SampleCatalog.track1.id);
      expect(playback.isLoadingTrack, isFalse);
      expect(audio.isPlaying, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.speed, 0);
      expect(playback.position, Duration.zero);
    },
  );
}
