import 'dart:math';

import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/protocol/audio_normalization.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

/// 实际下发给播放器的音量 = 用户音量 × 音量均衡倍率 × 淡入淡出倍率。
void main() {
  late StorageService storage;
  late FakeAudioPlayerService audio;
  late FakeTrackAudioSource loader;
  late PlaybackProvider playback;

  const a = SampleCatalog.track1;
  const b = SampleCatalog.track2;
  const ctx = PlaybackContext.playlist('Test', uri: 'spotify:playlist:test');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
    audio = FakeAudioPlayerService();
    loader = FakeTrackAudioSource();
    playback = PlaybackProvider(audio, storage.playback, random: Random(42), audioLoader: loader);
    playback.setVolume(0.8);
  });

  tearDown(() => playback.dispose());

  test('normalization scales loud tracks only while enabled, and persists', () async {
    loader.normalization[a.id] = const AudioNormalization(trackGainDb: -6.0206, trackPeak: 0.9);
    await playback.playTrack(a, contextQueue: const [a, b], context: ctx);
    expect(audio.lastVolume, closeTo(0.8, 1e-6), reason: '默认关闭');

    playback.setNormalizeVolume(true);
    expect(audio.lastVolume, closeTo(0.4, 1e-3));
    expect(storage.playback.normalizeVolume, isTrue);

    // 没有响度数据的曲目（旧缓存）按原音量播放
    await playback.nextTrack();
    expect(playback.currentTrack?.id, b.id);
    expect(audio.lastVolume, closeTo(0.8, 1e-6));

    playback.setNormalizeVolume(false);
    expect(storage.playback.normalizeVolume, isFalse);
  });

  test('fade ramps in at the start and out before the end', () async {
    playback.setFadeSeconds(4);
    expect(storage.playback.fadeSeconds, 4);

    await playback.playTrack(a, contextQueue: const [a, b], context: ctx);
    audio.durationController.add(const Duration(seconds: 100));
    expect(audio.lastVolume, 0, reason: '从静音开始淡入');

    // 淡入时长 = 4s / 2 = 2s；1s 处线性 0.5，平方曲线 0.25
    audio.positionController.add(const Duration(seconds: 1));
    expect(audio.lastVolume, closeTo(0.8 * 0.25, 1e-3));

    audio.positionController.add(const Duration(seconds: 50));
    expect(audio.lastVolume, closeTo(0.8, 1e-6));

    // 最后 4s 淡出；剩 2s 时线性 0.5，平方 0.25
    audio.positionController.add(const Duration(seconds: 98));
    expect(audio.lastVolume, closeTo(0.8 * 0.25, 1e-3));

    // 关闭后立即恢复原音量
    playback.setFadeSeconds(0);
    expect(audio.lastVolume, closeTo(0.8, 1e-6));
  });

  test('fade seconds are clamped to the supported range', () {
    playback.setFadeSeconds(99);
    expect(playback.fadeSeconds, PlaybackProvider.maxFadeSeconds);
    playback.setFadeSeconds(-5);
    expect(playback.fadeSeconds, 0);
  });
}
