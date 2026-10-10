import 'dart:async';
import 'dart:math';

import 'package:flutify_app/models/playback_state.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

class _ControlledSource extends FakeTrackAudioSource {
  final downloads = <String, Completer<void>>{};
  final drmDownloads = <String, Completer<void>>{};
  final prefetches = <String, Completer<void>>{};

  @override
  Future<LoadedAudio> open(
    String trackIdOrUri, {
    void Function(double)? progress,
  }) async {
    final audio = await super.open(trackIdOrUri, progress: progress);
    final download = downloads[trackIdOrUri];
    final drmDownload = drmDownloads[trackIdOrUri];
    if (download == null && drmDownload == null) return audio;
    return LoadedAudio(
      file: audio.file,
      source: audio.source,
      durationMs: audio.durationMs,
      trackId: audio.trackId,
      stream: download == null ? null : _Download(download.future),
      downloadComplete: drmDownload?.future,
    );
  }

  @override
  Future<void> prefetch(String trackIdOrUri) async {
    prefetched.add(trackIdOrUri);
    await prefetches[trackIdOrUri]?.future;
  }
}

class _Download implements ProgressiveAudio {
  _Download(this.done);
  @override
  final Future<void> done;
  @override
  int get length => 100;
  @override
  String get contentType => 'audio/ogg';
  @override
  double get progress => 0.5;
  @override
  Stream<List<int>> read(int start, [int? end]) => const Stream.empty();
}

void main() {
  const a = SampleCatalog.track1;
  const b = SampleCatalog.track2;
  const c = SampleCatalog.track3;
  const x = SampleCatalog.track4;
  late _ControlledSource loader;
  late FakeAudioPlayerService audio;
  late PlaybackProvider playback;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    audio = FakeAudioPlayerService();
    loader = _ControlledSource();
    playback = PlaybackProvider(
      audio,
      await StorageService.init(),
      random: Random(42),
      audioLoader: loader,
    );
  });
  tearDown(() => playback.dispose());

  test(
    'prefetch waits for the current download, then uses the latest queue',
    () async {
      final download = loader.downloads[a.id] = Completer<void>();
      await playback.playTrack(a, contextQueue: [a, b, c]);
      playback.addToQueue(x);
      expect(loader.prefetched, isEmpty);
      download.complete();
      await settle();
      expect(loader.prefetched, [x.id]);
      expect(playback.currentTrack, a);
      expect(audio.isPlaying, isTrue);
    },
  );

  test(
    'queue edits retarget prefetch without reloading the current track',
    () async {
      await playback.playTrack(a, contextQueue: [a, b, c]);
      await settle();
      playback.addToQueue(x);
      await settle();
      expect(loader.prefetched.last, x.id);
      playback.clearUserQueue();
      await settle();
      expect(loader.prefetched.last, b.id);
      playback.reorderUpNext(1, 0);
      await settle();
      expect(loader.prefetched.last, c.id);
      expect(loader.loaded, [a.id]);
    },
  );

  test('DRM readiness is not mistaken for a completed download', () async {
    final download = loader.drmDownloads[a.id] = Completer<void>();
    await playback.playTrack(a, contextQueue: [a, b]);
    expect(audio.isPlaying, isTrue);
    expect(loader.prefetched, isEmpty);
    download.complete();
    await settle();
    expect(loader.prefetched, [b.id]);
  });

  test(
    'a ready listener cannot transfer old download readiness to a new song',
    () async {
      final download = loader.drmDownloads[b.id] = Completer<void>();
      Future<void>? replacement;
      var sawLoading = false;
      void listener() {
        if (playback.currentTrack != a) return;
        if (playback.isLoadingTrack) sawLoading = true;
        if (sawLoading && !playback.isLoadingTrack && replacement == null) {
          replacement = playback.playTrack(b, contextQueue: [b, c]);
        }
      }

      playback.addListener(listener);
      await playback.playTrack(a, contextQueue: [a, c]);
      expect(replacement, isNotNull);
      await replacement;
      playback.removeListener(listener);
      playback.addToQueue(x);
      await settle();
      expect(playback.currentTrack, b);
      expect(
        loader.prefetched,
        isEmpty,
        reason: 'B is still downloading even though cached A was ready',
      );
      download.complete();
      await settle();
      expect(loader.prefetched, [x.id]);
    },
  );

  test('failed DRM downloads never trigger prefetch', () async {
    final download = loader.drmDownloads[a.id] = Completer<void>();
    await playback.playTrack(a, contextQueue: [a, b]);
    download.completeError(StateError('download interrupted'));
    await settle();
    playback.addToQueue(x);
    expect(loader.prefetched, isEmpty);
  });

  test(
    'only one prefetch runs at a time and obsolete queued targets are skipped',
    () async {
      final pending = loader.prefetches[b.id] = Completer<void>();
      await playback.playTrack(a, contextQueue: [a, b, c]);
      playback.addToQueue(x);
      playback.clearUserQueue();
      playback.reorderUpNext(1, 0);
      await settle();
      expect(loader.prefetched, [b.id]);
      pending.complete();
      await settle();
      expect(loader.prefetched, [b.id, c.id]);
    },
  );

  test('receiver queue changes refresh the next prefetch', () async {
    await playback.playTrack(a, contextQueue: [a, b]);
    await settle();
    playback.updateReceiverQueue([a, c, x]);
    await settle();
    expect(loader.prefetched, [b.id, c.id]);
    expect(loader.loaded, [a.id]);
  });

  test(
    'unrelated queue edits do not prefetch the same next song again',
    () async {
      await playback.playTrack(a, contextQueue: [a, b, c]);
      await settle();
      playback.addToQueue(b);
      playback.addToQueue(x);
      playback.removeFromUpNext(1);
      await settle();
      expect(loader.prefetched, [b.id]);
    },
  );

  test(
    'repeat context prefetches and plays the same wraparound track',
    () async {
      playback.setRepeatMode(SpotifyRepeatMode.context);
      await playback.playTrack(c, contextQueue: [a, b, c]);
      expect(loader.prefetched, [a.id]);
      await playback.nextTrack();
      expect(playback.currentTrack, a);
    },
  );

  test('shuffle wraparound consumes the order chosen for prefetch', () async {
    playback.setShuffle(true);
    playback.setRepeatMode(SpotifyRepeatMode.context);
    await playback.playTrack(a, contextQueue: [a, b, c, x]);
    await playback.playFromUpNext(2);
    await settle();
    final prepared = loader.prefetched.last;
    await playback.nextTrack();
    expect(playback.currentTrack?.id, prepared);
  });

  test(
    'single repeat and stop-after-current do not fetch a different song',
    () async {
      playback.setRepeatMode(SpotifyRepeatMode.track);
      await playback.playTrack(a, contextQueue: [a, b]);
      expect(loader.prefetched, isEmpty);
      playback.stopAfterCurrent = true;
      playback.setRepeatMode(SpotifyRepeatMode.off);
      expect(loader.prefetched, isEmpty);
      playback.stopAfterCurrent = false;
      await settle();
      expect(loader.prefetched, [b.id]);
    },
  );

  test(
    'an old download cannot schedule prefetch after skipping to a new download',
    () async {
      final old = loader.downloads[a.id] = Completer<void>();
      final current = loader.downloads[b.id] = Completer<void>();
      await playback.playTrack(a, contextQueue: [a, b, c]);
      await playback.nextTrack();
      old.complete();
      await settle();
      expect(loader.prefetched, isEmpty);
      current.complete();
      await settle();
      expect(loader.prefetched, [c.id]);
    },
  );

  test('pause during download does not lose the completion signal', () async {
    final download = loader.downloads[a.id] = Completer<void>();
    await playback.playTrack(a, contextQueue: [a, b]);
    await playback.pause();
    download.complete();
    await settle();
    await playback.togglePlayPause();
    await settle();
    expect(loader.prefetched, [b.id]);
  });

  test(
    'prefetch failure does not change playback or prevent normal next-track loading',
    () async {
      final pending = loader.prefetches[b.id] = Completer<void>();
      await playback.playTrack(a, contextQueue: [a, b]);
      pending.completeError(StateError('prefetch offline'));
      await settle();
      expect(playback.playbackError, isNull);
      expect(playback.currentTrack, a);
      expect(audio.isPlaying, isTrue);
      await playback.nextTrack();
      expect(playback.currentTrack, b);
    },
  );

  test(
    'discarding the session prevents late downloads from starting a prefetch',
    () async {
      final download = loader.downloads[a.id] = Completer<void>();
      await playback.playTrack(a, contextQueue: [a, b]);
      await playback.discardSession();
      download.complete();
      await settle();
      expect(loader.prefetched, isEmpty);
    },
  );
}
