import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as service;
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/media_controls/audio_service_media_controls.dart';
import 'package:flutify_app/services/media_controls/media_controls_sync.dart';
import 'package:flutify_app/services/media_controls/system_media_controls.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAudioPlayerService audio;
  late PlaybackProvider playback;
  late FlutifyAudioHandler handler;
  late MediaControlsSync sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    audio = FakeAudioPlayerService();
    playback = PlaybackProvider(
      audio, (await StorageService.init()).playback,
      random: Random(1),
      audioLoader: FakeTrackAudioSource(),
    );
    handler = FlutifyAudioHandler();
    sync = MediaControlsSync(
      playback,
      AudioServiceMediaControls.withHandler(handler),
    );
  });

  tearDown(() async {
    sync.dispose();
    playback.dispose();
    await handler.events.close();
  });

  test('MediaSession 和旧版通知都提供切歌与播放暂停；按钮连接实际播放器', () async {
    const a = SampleCatalog.track1;
    const b = SampleCatalog.track2;
    await playback.playTrack(a, contextQueue: [a, b]);
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    var state = handler.playbackState.value;
    expect(state.controls.map((c) => c.action), [
      service.MediaAction.skipToPrevious,
      service.MediaAction.pause,
      service.MediaAction.skipToNext,
    ]);
    expect(state.androidCompactActionIndices, [0, 1, 2]);
    expect(
      state.systemActions,
      containsAll([
        service.MediaAction.play,
        service.MediaAction.pause,
        service.MediaAction.playPause,
        service.MediaAction.skipToPrevious,
        service.MediaAction.skipToNext,
        service.MediaAction.seek,
      ]),
    );

    await handler.pause();
    await Future<void>.delayed(Duration.zero);
    expect(audio.isPlaying, isFalse);
    audio.stateController.add(PlayerState(false, ProcessingState.ready));
    state = handler.playbackState.value;
    expect(state.playing, isFalse);
    expect(state.speed, 0);
    expect(state.controls[1], service.MediaControl.play);

    await handler.click();
    await Future<void>.delayed(Duration.zero);
    expect(audio.isPlaying, isTrue);
    await handler.skipToNext();
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.id, b.id);
    // 到列表末尾时系统能力与实际队列一致，不暴露无效的下一首。
    expect(
      handler.playbackState.value.systemActions,
      isNot(contains(service.MediaAction.skipToNext)),
    );
    await handler.skipToPrevious();
    await Future<void>.delayed(Duration.zero);
    expect(playback.currentTrack?.id, a.id);
  });

  test('未知时长补全后可显示时间线，系统拖动被转发且限制在曲目范围内', () async {
    const track = SpotifyTrack(
      id: 'unknown-duration',
      name: 'Unknown duration',
    );
    await playback.playTrack(track, contextQueue: [track]);
    expect(handler.mediaItem.value!.duration, Duration.zero);
    const duration = Duration(minutes: 3);
    audio.durationController.add(duration);
    expect(handler.mediaItem.value!.duration, duration);
    expect(
      handler.playbackState.value.systemActions,
      contains(service.MediaAction.seek),
    );

    await handler.seek(const Duration(seconds: 42));
    await Future<void>.delayed(Duration.zero);
    expect(audio.seeks.last, const Duration(seconds: 42));
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 42),
    );
    await handler.seek(const Duration(minutes: 10));
    await Future<void>.delayed(Duration.zero);
    expect(audio.seeks.last, duration);
    audio.stateController.add(PlayerState(true, ProcessingState.buffering));
    expect(handler.playbackState.value.speed, 0);
    audio.stateController.add(PlayerState(true, ProcessingState.ready));
    expect(handler.playbackState.value.speed, 1);
  });

  MediaTrackInfo info({String id = 't1', String artUrl = ''}) => MediaTrackInfo(
    id: id,
    title: 'Title',
    artist: 'Artist',
    album: 'Album',
    artUrl: artUrl,
    duration: const Duration(seconds: 100),
  );

  test('封面本地化：解析到本地文件时首次即下发 file:// 封面', () async {
    final controls = AudioServiceMediaControls.withHandler(
      handler,
      (url) async {
        expect(url, 'https://i.scdn.co/image/abc');
        return '/tmp/flutify-cover.jpg';
      },
    );
    await controls.setTrack(
      info(artUrl: 'https://i.scdn.co/image/abc'),
    );
    expect(handler.mediaItem.value!.artUri, Uri.file('/tmp/flutify-cover.jpg'));
    controls.dispose();
  });

  test('封面本地化失败或没有解析器时回退远程 URL', () async {
    final fallback = AudioServiceMediaControls.withHandler(handler, (url) async {
      throw StateError('下载失败');
    });
    await fallback.setTrack(info(artUrl: 'https://example.test/cover.jpg'));
    expect(
      handler.mediaItem.value!.artUri,
      Uri.parse('https://example.test/cover.jpg'),
    );

    final plain = AudioServiceMediaControls.withHandler(handler);
    await plain.setTrack(info(artUrl: 'https://example.test/cover.jpg'));
    expect(
      handler.mediaItem.value!.artUri,
      Uri.parse('https://example.test/cover.jpg'),
    );
    fallback.dispose();
    plain.dispose();
  });

  test('无封面时不设置 artUri', () async {
    final controls = AudioServiceMediaControls.withHandler(
      handler,
      (url) async => '/tmp/never.jpg',
    );
    await controls.setTrack(info());
    expect(handler.mediaItem.value!.artUri, isNull);
    controls.dispose();
  });

  test('换曲期间旧封面解析完成不会覆盖新曲目', () async {
    final first = Completer<String?>();
    final second = Completer<String?>();
    var calls = 0;
    final controls = AudioServiceMediaControls.withHandler(handler, (url) {
      calls++;
      return calls == 1 ? first.future : second.future;
    });
    final old = controls.setTrack(
      info(id: 'old', artUrl: 'https://example.test/old.jpg'),
    );
    final fresh = controls.setTrack(
      info(id: 'new', artUrl: 'https://example.test/new.jpg'),
    );
    second.complete('/tmp/new.jpg');
    await fresh;
    first.complete('/tmp/old.jpg');
    await old;
    expect(handler.mediaItem.value!.id, 'new');
    expect(handler.mediaItem.value!.artUri, Uri.file('/tmp/new.jpg'));
    controls.dispose();
  });
}
