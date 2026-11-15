import 'dart:async';
import 'dart:typed_data';

import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/services/media_controls/multi_media_controls.dart';
import 'package:flutify_app/services/media_controls/system_media_controls.dart';
import 'package:flutify_app/services/taskbar_lyrics/taskbar_lyrics_channel.dart';
import 'package:flutify_app/services/taskbar_lyrics/taskbar_lyrics_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 记录所有调用的内存版原生端。
class _FakePlatform implements TaskbarLyricsPlatform {
  final List<String> calls = [];
  String? lastArtist;
  final StreamController<TaskbarLyricsEvent> controller =
      StreamController.broadcast();
  List<LyricLine>? lyrics;

  @override
  Stream<TaskbarLyricsEvent> get events => controller.stream;

  @override
  Future<void> setEnabled(bool enabled) async => calls.add('enabled:$enabled');

  @override
  Future<void> setStyle(TaskbarLyricsStyle style) async =>
      calls.add('style:${style.mode.name}');

  @override
  Future<void> setTrack(({String title, String artist})? track) async {
    lastArtist = track?.artist;
    calls.add('track:${track?.title}');
  }

  @override
  Future<void> setArt(Uint8List? bytes) async =>
      calls.add('art:${bytes?.length}');

  @override
  Future<void> setLyrics(List<LyricLine>? lines) async {
    lyrics = lines;
    calls.add('lyrics:${lines?.length}');
  }

  @override
  Future<void> setPlayback({
    required bool playing,
    required Duration position,
    bool muteButton = false,
    bool muted = false,
  }) async => calls.add(
    muteButton ? 'playback:$playing:mute=$muted' : 'playback:$playing',
  );
}

/// 只记录调用的系统媒体控制端（测 MultiMediaControls）。
class _RecordingControls implements SystemMediaControls {
  final StreamController<MediaControlEvent> controller =
      StreamController.broadcast();
  final List<String> calls = [];
  bool disposed = false;
  final bool periodic;

  _RecordingControls({this.periodic = false});

  @override
  Stream<MediaControlEvent> get events => controller.stream;

  @override
  bool get needsPeriodicTimeline => periodic;

  @override
  Future<void> setTrack(MediaTrackInfo? track) async =>
      calls.add('track:${track?.id}');

  @override
  Future<void> setPlayback(MediaPlaybackInfo info) async =>
      calls.add('playback:${info.playing}');

  @override
  void dispose() => disposed = true;
}

void main() {
  const track = MediaTrackInfo(
    id: 'id1',
    title: 'Song',
    artist: 'Singer',
    album: 'Album',
    artUrl: 'https://example.invalid/art.jpg',
    duration: Duration(minutes: 3),
  );
  const style = TaskbarLyricsStyle(mode: TaskbarLyricsColor.accent);
  const syncedLyrics = SpotifyLyrics(
    lines: [
      LyricLine(startTimeMs: 0, words: 'a'),
      LyricLine(startTimeMs: 1000, words: 'b'),
    ],
  );

  late _FakePlatform platform;
  late TaskbarLyricsControls controls;
  late List<LyricsQuery> loaded;
  late List<LyricsQuery> reloaded;
  var result = syncedLyrics;

  setUp(() {
    platform = _FakePlatform();
    loaded = [];
    reloaded = [];
    result = syncedLyrics;
    controls =
        TaskbarLyricsControls(
            platform,
            client: MockClient(
              (_) async => http.Response.bytes([1, 2, 3], 200),
            ),
          )
          ..lyricsLoader = (q) async {
            loaded.add(q);
            return result;
          }
          ..lyricsReloader = (q) async {
            reloaded.add(q);
            return result;
          };
  });

  tearDown(() => controls.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('关闭时不向原生推送曲目', () async {
    await controls.setTrack(track);
    await controls.setPlayback(
      const MediaPlaybackInfo(
        playing: true,
        buffering: false,
        position: Duration.zero,
        canNext: true,
        canPrevious: true,
      ),
    );
    expect(platform.calls, isEmpty);
    expect(loaded, isEmpty);
  });

  test('开启后补推样式、曲目、封面、同步歌词与进度', () async {
    await controls.setTrack(track);
    await controls.setPlayback(
      const MediaPlaybackInfo(
        playing: true,
        buffering: false,
        position: Duration.zero,
        canNext: true,
        canPrevious: true,
      ),
    );
    controls.configure(enabled: true, style: style);
    await settle();
    await settle();

    expect(platform.calls.first, 'enabled:true');
    expect(
      platform.calls,
      containsAllInOrder(['style:accent', 'track:Song', 'lyrics:null']),
    );
    expect(platform.calls, contains('art:3'));
    expect(platform.calls, contains('lyrics:2'));
    expect(platform.calls.last, 'playback:true');
    expect(loaded.single.trackId, 'id1');
    expect(loaded.single.durationMs, 180000);
  });

  test('未同步歌词不推给原生（显示控制条）', () async {
    result = const SpotifyLyrics(
      syncType: 'UNSYNCED',
      lines: [LyricLine(startTimeMs: 0, words: 'x')],
    );
    controls.configure(enabled: true, style: style);
    await controls.setTrack(track);
    await settle();
    expect(platform.lyrics, isNull);
  });

  test('样式不变时不重复推送', () async {
    controls.configure(enabled: true, style: style);
    await settle();
    platform.calls.clear();
    controls.configure(enabled: true, style: style);
    expect(platform.calls, isEmpty);
    controls.configure(
      enabled: true,
      style: const TaskbarLyricsStyle(opacity: 50),
    );
    expect(platform.calls, ['style:auto']);
  });

  test('原生事件：按键转成媒体事件，菜单走回调 / 重新获取', () async {
    var opened = 0, disabled = 0;
    controls.onOpen = () => opened++;
    controls.onDisable = () => disabled++;
    controls.configure(enabled: true, style: style);
    await controls.setTrack(track);
    final events = <MediaControlEvent>[];
    final sub = controls.events.listen(events.add);

    platform.controller
      ..add(TaskbarLyricsEvent.toggle)
      ..add(TaskbarLyricsEvent.next)
      ..add(TaskbarLyricsEvent.open)
      ..add(TaskbarLyricsEvent.disable)
      ..add(TaskbarLyricsEvent.refetch);
    await settle();
    await settle();

    expect(events.map((e) => (e as MediaButtonEvent).button), [
      MediaButton.toggle,
      MediaButton.next,
    ]);
    expect((opened, disabled), (1, 1));
    expect(reloaded.single.title, 'Song');
    await sub.cancel();
  });

  test('切歌后丢弃上一首迟到的歌词', () async {
    final slow = Completer<SpotifyLyrics>();
    controls.lyricsLoader = (q) =>
        q.trackId == 'id1' ? slow.future : Future.value(syncedLyrics);
    controls.configure(enabled: true, style: style);
    await settle();
    unawaited(controls.setTrack(track));
    await settle();
    await controls.setTrack(
      const MediaTrackInfo(
        id: 'id2',
        title: 'Next',
        artist: '',
        album: '',
        artUrl: '',
        duration: Duration.zero,
      ),
    );
    platform.calls.clear();
    slow.complete(
      const SpotifyLyrics(lines: [LyricLine(startTimeMs: 0, words: 'stale')]),
    );
    await settle();
    expect(platform.calls, isNot(contains('lyrics:1')));
  });

  group('没取到歌词时补推', () {
    late TaskbarLyricsControls retrying;
    late List<SpotifyLyrics> answers;

    setUp(() {
      answers = [const SpotifyLyrics(lines: []), syncedLyrics];
      retrying =
          TaskbarLyricsControls(
              platform,
              client: MockClient((_) async => http.Response('', 404)),
              retryDelays: const [Duration(milliseconds: 20)],
            )
            ..lyricsLoader = (_) async =>
                answers.length > 1 ? answers.removeAt(0) : answers.first;
    });

    tearDown(() => retrying.dispose());

    test('第一次没取到，按间隔重试后补上', () async {
      await retrying.setTrack(track);
      retrying.configure(enabled: true, style: style);
      await settle();
      await settle();
      expect(platform.lyrics, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(platform.lyrics, hasLength(2));
    });

    test('App 内取到同一首的歌词时立即补上；别的歌不理会', () async {
      await retrying.setTrack(track);
      retrying.configure(enabled: true, style: style);
      await settle();
      await settle();
      retrying.lyricsCached('other');
      await settle();
      expect(platform.lyrics, isNull);
      retrying.lyricsCached('id1');
      await settle();
      expect(platform.lyrics, hasLength(2));
    });
  });

  group('双语开关', () {
    test('切换界面语言时不显示其他语言或相反中文字体的译文', () async {
      result = const SpotifyLyrics(
        lines: [LyricLine(startTimeMs: 0, words: 'wind', translation: '这里有风')],
      );
      await controls.setTrack(track);
      controls.configure(enabled: true, style: style, locale: 'zh-Hans');
      await settle();
      await settle();
      expect(platform.lyrics?.single.translation, '这里有风');
      for (final locale in ['zh-Hant', 'ja', 'en']) {
        controls.configure(enabled: true, style: style, locale: locale);
        await settle();
        expect(platform.lyrics?.single.translation, '');
      }
      controls.configure(enabled: true, style: style, locale: 'zh-Hans');
      await settle();
      expect(platform.lyrics?.single.translation, '这里有风');
      expect(loaded, hasLength(1));
    });

    const translated = SpotifyLyrics(
      lines: [
        LyricLine(startTimeMs: 0, words: 'a', translation: '甲'),
        LyricLine(startTimeMs: 1000, words: 'b', translation: '乙'),
      ],
    );

    test('打开时重新取当前曲目的歌词（关闭期间取到的没有译文），取到前原文照常显示', () async {
      await controls.setTrack(track);
      controls.configure(enabled: true, style: style, bilingual: false);
      await settle();
      await settle();
      expect(loaded, hasLength(1));
      expect(platform.lyrics?.map((l) => l.translation), ['', '']);

      // 打开双语时 SpotifyProvider 已作废内存里的歌词：重新取到的带网易云译文
      final reload = Completer<SpotifyLyrics>();
      controls.lyricsLoader = (q) {
        loaded.add(q);
        return reload.future;
      };
      platform.calls.clear();
      controls.configure(enabled: true, style: style, bilingual: true);
      await settle();
      expect(loaded, hasLength(2));
      expect(loaded.last.trackId, 'id1');
      expect(
        platform.calls,
        isNot(contains('lyrics:null')),
        reason: '新歌词到之前不清掉原文',
      );

      reload.complete(translated);
      await settle();
      expect(platform.lyrics?.map((l) => l.translation), ['甲', '乙']);
    });

    test('关上时剥掉译文重推已取到的歌词，不重新取', () async {
      result = translated;
      await controls.setTrack(track);
      controls.configure(enabled: true, style: style, bilingual: true);
      await settle();
      await settle();
      expect(platform.lyrics?.map((l) => l.translation), ['甲', '乙']);

      controls.configure(enabled: true, style: style, bilingual: false);
      await settle();
      expect(loaded, hasLength(1));
      expect(platform.lyrics?.map((l) => l.words), ['a', 'b']);
      expect(platform.lyrics?.map((l) => l.translation), ['', '']);
    });

    test('任务栏歌词没开时切换双语不取歌词', () async {
      await controls.setTrack(track);
      controls.configure(enabled: false, style: style, bilingual: false);
      controls.configure(enabled: false, style: style, bilingual: true);
      await settle();
      expect(loaded, isEmpty);
      expect(platform.calls, isEmpty);
    });
  });

  group('MultiMediaControls', () {
    test('状态推给每一端，事件合并，dispose 级联', () async {
      final a = _RecordingControls(), b = _RecordingControls(periodic: true);
      final multi = MultiMediaControls([a, b]);
      expect(multi.needsPeriodicTimeline, isTrue);

      await multi.setTrack(track);
      expect(a.calls, ['track:id1']);
      expect(b.calls, ['track:id1']);

      final events = <MediaControlEvent>[];
      final sub = multi.events.listen(events.add);
      a.controller.add(const MediaButtonEvent(MediaButton.next));
      b.controller.add(const MediaButtonEvent(MediaButton.previous));
      await settle();
      expect(events, hasLength(2));

      await sub.cancel();
      multi.dispose();
      expect(a.disposed && b.disposed, isTrue);
    });
  });

  group('发现流试听覆盖', () {
    test('显示发现流曲目与来源标注，中间按键路由到静音，退出后恢复主播放', () async {
      await controls.setTrack(track);
      controls.configure(enabled: true, style: style);
      await settle();
      await settle();
      platform.calls.clear();

      var toggled = 0, nexted = 0, preved = 0;
      controls.setWatchFeedOverride(
        title: 'Seve',
        subtitle: '发现流 · Tez Cadey',
        artUrl: '',
        muted: false,
        onPrevious: () => preved++,
        onToggleMute: () => toggled++,
        onNext: () => nexted++,
      );
      await settle();

      expect(
        platform.calls,
        containsAllInOrder([
          'track:Seve',
          'lyrics:null',
          'playback:true:mute=false',
        ]),
      );
      expect(platform.lastArtist, '发现流 · Tez Cadey');

      final mainEvents = <MediaControlEvent>[];
      final sub = controls.events.listen(mainEvents.add);
      platform.controller.add(TaskbarLyricsEvent.toggle);
      platform.controller.add(TaskbarLyricsEvent.next);
      platform.controller.add(TaskbarLyricsEvent.previous);
      await settle();
      expect(toggled, 1);
      expect(nexted, 1);
      expect(preved, 1);
      expect(mainEvents, isEmpty);

      platform.calls.clear();
      controls.clearWatchFeedOverride();
      await settle();
      await settle();
      expect(platform.calls, contains('track:Song'));
      expect(platform.lastArtist, 'Singer');
      expect(platform.lyrics, hasLength(2));
      await sub.cancel();
    });
  });
}
