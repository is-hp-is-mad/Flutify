import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/sleep_timer_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

/// 睡眠定时器：按时长到点暂停、本首结束时停在曲目末尾不接下一首、取消。
void main() {
  const a = SampleCatalog.track1;
  const b = SampleCatalog.track2;

  late FakeAudioPlayerService audio;
  late PlaybackProvider playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    audio = FakeAudioPlayerService();
    playback = PlaybackProvider(audio, storage.playback, random: Random(1), audioLoader: FakeTrackAudioSource());
    await playback.playTrack(a, contextQueue: [a, b]);
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
  });

  tearDown(() => playback.dispose());

  test('duration preset pauses when it expires and counts down meanwhile', () {
    fakeAsync((async) {
      final timer = SleepTimerProvider(playback, now: () => DateTime(2026).add(async.elapsed));
      timer.start(SleepTimerPreset.minutes5);
      expect(timer.remaining, const Duration(minutes: 5));

      async.elapse(const Duration(minutes: 2));
      expect(timer.remaining, const Duration(minutes: 3));
      expect(audio.isPlaying, isTrue);

      async.elapse(const Duration(minutes: 3));
      expect(audio.isPlaying, isFalse);
      expect(timer.active, isFalse);
      timer.dispose();
    });
  });

  test('end of track stops at the end instead of advancing, then turns itself off', () async {
    final timer = SleepTimerProvider(playback);
    timer.start(SleepTimerPreset.endOfTrack);
    expect(playback.stopAfterCurrent, isTrue);
    expect(timer.remaining, isNull);

    audio.emitCompleted();
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.id, a.id);
    expect(audio.isPlaying, isFalse);
    expect(audio.seeks.last, Duration.zero);
    expect(timer.active, isFalse);

    // 之后正常播完会接下一首（真实播放器回到开头后先进入 ready）
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    audio.emitCompleted();
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.id, b.id);
    timer.dispose();
  });

  test('cancel and switching presets', () {
    fakeAsync((async) {
      final timer = SleepTimerProvider(playback, now: () => DateTime(2026).add(async.elapsed));
      timer.start(SleepTimerPreset.endOfTrack);
      timer.start(SleepTimerPreset.minutes10);
      expect(playback.stopAfterCurrent, isFalse);
      expect(timer.preset, SleepTimerPreset.minutes10);

      timer.cancel();
      async.elapse(const Duration(minutes: 11));
      expect(audio.isPlaying, isTrue);
      expect(timer.active, isFalse);
      timer.dispose();
    });
  });
}
