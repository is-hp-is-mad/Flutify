import 'dart:async';
import 'dart:math';

import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/media_controls/media_controls_sync.dart';
import 'package:flutify_app/services/media_controls/system_media_controls.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

class _FakeControls implements SystemMediaControls {
  final StreamController<MediaControlEvent> controller =
      StreamController.broadcast(sync: true);
  final List<MediaTrackInfo?> tracks = [];
  final List<MediaPlaybackInfo> playbacks = [];

  @override
  Stream<MediaControlEvent> get events => controller.stream;

  @override
  bool get needsPeriodicTimeline => true;

  @override
  Future<void> setTrack(MediaTrackInfo? track) async => tracks.add(track);

  @override
  Future<void> setPlayback(MediaPlaybackInfo info) async => playbacks.add(info);

  @override
  void dispose() => controller.close();
}

/// 替代来源：手动切换是否接管，记录收到的按键。
class _FakeOverride extends ChangeNotifier implements MediaSourceOverride {
  bool _active = false;
  final List<MediaControlEvent> handled = [];

  void set({required bool active}) {
    _active = active;
    notifyListeners();
  }

  @override
  Listenable get changes => this;

  @override
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  @override
  bool get active => _active;

  @override
  MediaTrackInfo? get track => const MediaTrackInfo(
    id: 'r1',
    title: 'Remote Song',
    artist: 'R',
    album: 'R',
    artUrl: '',
    duration: Duration(minutes: 3),
  );

  @override
  MediaPlaybackInfo get playbackInfo => const MediaPlaybackInfo(
    playing: true,
    buffering: false,
    position: Duration.zero,
    canNext: true,
    canPrevious: true,
  );

  @override
  bool handle(MediaControlEvent event) {
    if (!_active) return false;
    handled.add(event);
    return true;
  }
}

void main() {
  const a = SampleCatalog.track1;
  const b = SampleCatalog.track2;

  late FakeAudioPlayerService audio;
  late PlaybackProvider playback;
  late _FakeControls controls;
  late MediaControlsSync sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    audio = FakeAudioPlayerService();
    playback = PlaybackProvider(
      audio,
      storage,
      random: Random(1),
      audioLoader: FakeTrackAudioSource(),
    );
    controls = _FakeControls();
    sync = MediaControlsSync(playback, controls);
  });

  tearDown(() {
    sync.dispose();
    playback.dispose();
  });

  test('曲目变化才下发曲目信息；播放状态变化才下发状态', () async {
    expect(controls.tracks, isEmpty);
    await playback.playTrack(a, contextQueue: [a, b]);
    expect(controls.tracks.whereType<MediaTrackInfo>().map((t) => t.title), [
      a.name,
    ]);
    expect(controls.tracks.last!.artist, a.artistNames);
    expect(controls.playbacks.last.canNext, isTrue);

    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    expect(controls.playbacks.last.playing, isTrue);
    final count = controls.playbacks.length;

    // 小幅进度推进不下发（系统端由周期更新处理）
    audio.positionController.add(const Duration(milliseconds: 500));
    expect(controls.playbacks.length, count);

    // 跳转立即下发
    audio.positionController.add(const Duration(seconds: 90));
    expect(controls.playbacks.length, count + 1);
    expect(controls.playbacks.last.position, const Duration(seconds: 90));
  });

  test('替代来源接管时卡片显示它的曲目，按键交给它；退出后回到本机', () async {
    await playback.playTrack(a, contextQueue: [a, b]);
    final remote = _FakeOverride();
    sync.override = remote;
    expect(controls.tracks.last?.title, a.name); // 未接管：仍是本机

    remote.set(active: true);
    expect(controls.tracks.last?.title, 'Remote Song');
    expect(controls.playbacks.last.playing, isTrue);

    controls.controller.add(const MediaButtonEvent(MediaButton.next));
    await Future<void>.delayed(Duration.zero);
    expect(remote.handled, hasLength(1));
    expect(playback.currentTrack?.id, a.id);

    remote.set(active: false);
    expect(controls.tracks.last?.title, a.name);
  });

  test('系统按键转给播放器', () async {
    await playback.playTrack(a, contextQueue: [a, b]);
    audio.stateController.add(PlayerState(true, ProcessingState.ready));

    // 已在播放时再收到「播放」不应切成暂停
    controls.controller.add(const MediaButtonEvent(MediaButton.play));
    await Future<void>.delayed(Duration.zero);
    expect(audio.isPlaying, isTrue);

    controls.controller.add(const MediaButtonEvent(MediaButton.next));
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.id, b.id);

    controls.controller.add(const MediaSeekEvent(Duration(seconds: 30)));
    await Future<void>.delayed(Duration.zero);
    expect(audio.seeks.last, const Duration(seconds: 30));
  });

  test('引擎补全同一首歌的时长后重新下发媒体元数据', () async {
    await playback.playTrack(a, contextQueue: [a, b]);
    final count = controls.tracks.length;
    const actualDuration = Duration(minutes: 4, seconds: 12);
    audio.durationController.add(actualDuration);
    expect(controls.tracks.length, count + 1);
    expect(controls.tracks.last!.id, a.id);
    expect(controls.tracks.last!.duration, actualDuration);
    audio.durationController.add(actualDuration);
    expect(controls.tracks.length, count + 1);
  });

  test('发现流激活时接管系统媒体按键，关闭后恢复给播放器', () async {
    await playback.playTrack(a, contextQueue: [a, b]);
    final owner = Object();
    final handled = <MediaButton>[];
    MediaControlsSync.setWatchFeedHandler(owner, (event) {
      if (event is MediaButtonEvent) {
        handled.add(event.button);
        return true;
      }
      return false;
    });

    controls.controller.add(const MediaButtonEvent(MediaButton.next));
    controls.controller.add(const MediaButtonEvent(MediaButton.toggle));
    await Future<void>.delayed(Duration.zero);
    expect(handled, [MediaButton.next, MediaButton.toggle]);
    expect(playback.currentTrack?.id, a.id);

    // 非当前 owner 清除不生效
    MediaControlsSync.setWatchFeedHandler(Object(), null);
    controls.controller.add(const MediaButtonEvent(MediaButton.previous));
    await Future<void>.delayed(Duration.zero);
    expect(handled, [MediaButton.next, MediaButton.toggle, MediaButton.previous]);

    // 同一 owner 清除后恢复默认路由
    MediaControlsSync.setWatchFeedHandler(owner, null);
    controls.controller.add(const MediaButtonEvent(MediaButton.next));
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.id, b.id);
  });
}
