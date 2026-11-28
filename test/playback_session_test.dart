import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/playback_session.dart';
import 'package:flutify_app/models/playback_state.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/playback_session_store.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

void main() {
  const a = SampleCatalog.track1;
  const b = SampleCatalog.track2;
  const c = SampleCatalog.track3;
  const x = SampleCatalog.track4;
  const ctx = PlaybackContext.playlist('Test', uri: 'spotify:playlist:test');

  late StorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.init();
  });

  PlaybackProvider create(PlaybackSessionStore store, {FakeAudioPlayerService? audio, FakeTrackAudioSource? loader}) {
    return PlaybackProvider(audio ?? FakeAudioPlayerService(), storage.playback,
      random: Random(1),
      audioLoader: loader ?? FakeTrackAudioSource(),
      sessionStore: store,
    );
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('播放、排队、随机 / 循环后重启：曲目、队列、进度、来源都还原', () async {
    final store = MemoryPlaybackSessionStore();
    final first = create(store);
    await first.playTrack(b, contextQueue: [a, b, c], context: ctx);
    first.addToQueue(x);
    first.cycleRepeatMode();
    await first.seekTo(const Duration(seconds: 42));
    await settle();
    first.dispose();

    final audio = FakeAudioPlayerService();
    final restored = create(store, audio: audio);
    expect(restored.currentTrack?.id, b.id);
    expect(restored.isPlaying, isFalse);
    expect(restored.position, const Duration(seconds: 42));
    expect(restored.playbackContext.uri, ctx.uri);
    expect(restored.repeatMode, SpotifyRepeatMode.context);
    expect(restored.userQueue.map((e) => e.track.id), [x.id]);
    expect(restored.upNext.map((e) => e.track.id), [c.id]);
    // 启动时不加载音频
    expect(audio.playedFiles, isEmpty);

    // 点播放：从记下的进度开始
    await restored.togglePlayPause();
    expect(audio.initialPositions.single, const Duration(seconds: 42));

    // 上一首仍然可用（播放顺序里当前曲目之前的部分也保存了）
    await restored.seekTo(Duration.zero);
    await restored.previousTrack();
    expect(restored.currentTrack?.id, a.id);
    restored.dispose();
  });

  test('还原后先拖动进度再点播放：从拖到的位置开始', () async {
    final store = MemoryPlaybackSessionStore(
      PlaybackSession(tracks: const [a, b], index: 0, current: a, position: const Duration(seconds: 10)),
    );
    final audio = FakeAudioPlayerService();
    final playback = create(store, audio: audio);
    await playback.seekTo(const Duration(seconds: 70));
    expect(audio.seeks, isEmpty); // 还没有音源，不下发给播放器
    await playback.togglePlayPause();
    expect(audio.initialPositions.single, const Duration(seconds: 70));
    playback.dispose();
  });

  test('新点播一首歌从头开始，不沿用还原的进度', () async {
    final store = MemoryPlaybackSessionStore(
      PlaybackSession(tracks: const [a], index: 0, current: a, position: const Duration(seconds: 30)),
    );
    final audio = FakeAudioPlayerService();
    final playback = create(store, audio: audio);
    await playback.playTrack(c, contextQueue: [c]);
    expect(audio.initialPositions.single, isNull);
    playback.dispose();
  });

  test('超长上下文只保存当前曲目附近的一段', () async {
    final store = MemoryPlaybackSessionStore();
    final playback = create(store);
    final tracks = [
      for (var i = 0; i < 1000; i++) SpotifyTrack(id: 't$i', name: 'Track $i', uri: 'spotify:track:t$i', durationMs: 1000),
    ];
    await playback.playTrack(tracks[500], contextQueue: tracks);
    await settle();
    final saved = store.session!;
    expect(saved.tracks.length, PlaybackSession.maxBefore + 1 + PlaybackSession.maxAfter);
    expect(saved.tracks[saved.index].id, 't500');
    playback.dispose();
  });

  test('排过序的上下文：重启后仍记得「排过序」，交接给 Connect 时不按歌单原顺序展开', () {
    final sorted = ctx.withReordered(true);
    final saved = PlaybackSession(tracks: const [c, a, b], index: 0, current: c, context: sorted);
    final restored = PlaybackSession.fromJson(jsonDecode(jsonEncode(saved.toJson())))!;
    expect(restored.context.uri, sorted.uri);
    expect(restored.context.reordered, isTrue);

    // 没排过序的不写这个字段，旧会话文件读回也是 false
    final plain = PlaybackSession(tracks: const [a, b], index: 0, current: a, context: ctx);
    expect((plain.toJson()['context'] as Map).containsKey('reordered'), isFalse);
    expect(PlaybackSession.fromJson(jsonDecode(jsonEncode(plain.toJson())))!.context.reordered, isFalse);
  });

  test('文件存储：写入后可读回；损坏的文件按没有会话处理', () async {
    final dir = await Directory.systemTemp.createTemp('flutify_session_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}session.json');
    final store = FilePlaybackSessionStore(file);

    await store.write(
      PlaybackSession(tracks: const [a, b], index: 1, current: b, position: const Duration(seconds: 5), shuffle: true),
    );
    final read = FilePlaybackSessionStore(file).read()!;
    expect(read.current.id, b.id);
    expect(read.index, 1);
    expect(read.shuffle, isTrue);
    expect(read.position, const Duration(seconds: 5));

    file.writeAsStringSync('{not json');
    expect(FilePlaybackSessionStore(file).read(), isNull);
    file.writeAsStringSync(jsonEncode({'v': 1}));
    expect(FilePlaybackSessionStore(file).read(), isNull);
  });

  test('登出 / 切换账号：清除上次播放会话（内存 + 磁盘），重启不再还原', () async {
    final store = MemoryPlaybackSessionStore();
    final playback = create(store);
    await playback.playTrack(b, contextQueue: [a, b, c], context: ctx);
    playback.addToQueue(x);
    await playback.seekTo(const Duration(seconds: 20));
    await settle();
    expect(store.session, isNotNull);

    await playback.discardSession();
    expect(store.session, isNull);
    expect(playback.currentTrack, isNull);
    expect(playback.userQueue, isEmpty);
    expect(playback.position, Duration.zero);

    // 重启也不再还原旧账号的会话
    final restored = create(store);
    expect(restored.currentTrack, isNull);
    restored.dispose();
    playback.dispose();
  });
}
