import 'dart:async';

import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/services/audio/audio_output_service.dart';
import 'package:flutify_app/services/lyric_bridge/lyric_bridge_channel.dart';
import 'package:flutify_app/services/lyric_bridge/lyric_metadata_controls.dart';
import 'package:flutify_app/services/media_controls/system_media_controls.dart';
import 'package:flutter_test/flutter_test.dart';

class _Inner implements SystemMediaControls {
  final tracks = <MediaTrackInfo?>[];

  @override
  Stream<MediaControlEvent> get events => const Stream.empty();
  @override
  bool get needsPeriodicTimeline => false;
  @override
  Future<void> setTrack(MediaTrackInfo? track) async => tracks.add(track);
  @override
  Future<void> setPlayback(MediaPlaybackInfo info) async {}
  @override
  void dispose() {}
}

class _Bridge implements LyricBridgePlatform {
  _Bridge({this.flyme = false});

  final bool flyme;
  final devicesController = StreamController<List<BluetoothAudioDevice>>();
  final tickers = <String?>[];

  @override
  Future<bool> isFlyme() async => flyme;
  @override
  Future<void> setTicker(String? text) async => tickers.add(text);
  @override
  Future<bool> hasBluetoothPermission() async => true;
  @override
  Future<void> requestBluetoothPermission() async {}
  @override
  Future<List<BluetoothAudioDevice>> connectedDevices() async => const [];
  @override
  Stream<List<BluetoothAudioDevice>> get devices => devicesController.stream;
}

const _track = MediaTrackInfo(
  id: 't1',
  title: 'Something Just Like This',
  artist: 'The Chainsmokers, Coldplay',
  album: 'Memories',
  artUrl: '',
  duration: Duration(minutes: 4),
);

const _car = BluetoothAudioDevice(address: 'AA', name: 'My Car', isCar: true);
const _buds = BluetoothAudioDevice(address: 'BB', name: 'Buds', isCar: false);

MediaPlaybackInfo _playing(Duration at) => MediaPlaybackInfo(
  playing: true,
  buffering: false,
  position: at,
  canNext: true,
  canPrevious: true,
);

void main() {
  late _Inner inner;
  late _Bridge bridge;
  LyricMetadataControls? created;
  LyricMetadataControls controls() => created!;
  late DateTime now;

  Future<void> setUpControls({bool flyme = false}) async {
    inner = _Inner();
    bridge = _Bridge(flyme: flyme);
    now = DateTime(2026);
    created = LyricMetadataControls(inner, bridge, now: () => now)
      ..lyricsLoader = (_) async => const SpotifyLyrics(
        lines: [
          LyricLine(startTimeMs: 1000, words: "I've been reading books of old"),
          LyricLine(
            startTimeMs: 5000,
            words: 'The legends and the myths',
            translation: '传说与神话',
          ),
        ],
      );
    await pumpEventQueue();
  }

  void configure({
    BluetoothLyricsMode mode = BluetoothLyricsMode.car,
    bool translation = false,
    List<String> extra = const [],
    bool flyme = false,
  }) => controls().configure(
    mode: mode,
    withTranslation: translation,
    extraDevices: extra,
    flymeStatusBar: flyme,
  );

  tearDown(() {
    created?.dispose();
    created = null;
  });

  test('car device: title becomes the current lyric, artist "song - artist"', () async {
    await setUpControls();
    configure();
    bridge.devicesController.add([_car]);
    await controls().setTrack(_track);
    await controls().setPlayback(_playing(const Duration(seconds: 2)));
    await pumpEventQueue();

    final last = inner.tracks.last!;
    expect(last.title, "I've been reading books of old");
    expect(last.artist, 'Something Just Like This - The Chainsmokers, Coldplay');
    expect(last.album, last.artist);
  });

  test('translation is appended when enabled', () async {
    await setUpControls();
    configure(translation: true);
    bridge.devicesController.add([_car]);
    await controls().setTrack(_track);
    await controls().setPlayback(_playing(const Duration(seconds: 6)));
    await pumpEventQueue();

    expect(inner.tracks.last!.title, 'The legends and the myths / 传说与神话');
  });

  test('non-car device keeps original metadata unless added manually', () async {
    await setUpControls();
    configure();
    bridge.devicesController.add([_buds]);
    await controls().setTrack(_track);
    await controls().setPlayback(_playing(const Duration(seconds: 2)));
    await pumpEventQueue();
    expect(inner.tracks.last!.title, _track.title);

    configure(extra: const ['BB']);
    await pumpEventQueue();
    expect(inner.tracks.last!.title, "I've been reading books of old");
  });

  test('disconnecting restores the original metadata', () async {
    await setUpControls();
    configure(mode: BluetoothLyricsMode.all);
    bridge.devicesController.add([_buds]);
    await controls().setTrack(_track);
    await controls().setPlayback(_playing(const Duration(seconds: 2)));
    await pumpEventQueue();
    expect(inner.tracks.last!.title, isNot(_track.title));

    bridge.devicesController.add(const []);
    await pumpEventQueue();
    expect(inner.tracks.last!.title, _track.title);
    expect(inner.tracks.last!.artist, _track.artist);
  });

  test('intro (before the first line) keeps the song title', () async {
    await setUpControls();
    configure();
    bridge.devicesController.add([_car]);
    await controls().setTrack(_track);
    await controls().setPlayback(_playing(Duration.zero));
    await pumpEventQueue();
    expect(inner.tracks.last!.title, _track.title);
  });

  test('clearing the track is forwarded', () async {
    await setUpControls();
    configure(mode: BluetoothLyricsMode.off);
    await controls().setTrack(_track);
    await controls().setTrack(null);
    expect(inner.tracks.last, isNull);
  });

  test('Flyme ticker follows the line while playing and clears on pause', () async {
    await setUpControls(flyme: true);
    configure(mode: BluetoothLyricsMode.off, flyme: true);
    await controls().setTrack(_track);
    await controls().setPlayback(_playing(const Duration(seconds: 2)));
    await pumpEventQueue();
    expect(bridge.tickers.last, "I've been reading books of old");

    await controls().setPlayback(
      const MediaPlaybackInfo(
        playing: false,
        buffering: false,
        position: Duration(seconds: 2),
        canNext: true,
        canPrevious: true,
      ),
    );
    await pumpEventQueue();
    expect(bridge.tickers.last, isNull);
  });

  test('Flyme ticker is never written on other systems', () async {
    await setUpControls();
    configure(mode: BluetoothLyricsMode.off, flyme: true);
    await controls().setTrack(_track);
    await controls().setPlayback(_playing(const Duration(seconds: 2)));
    await pumpEventQueue();
    expect(bridge.tickers, isEmpty);
  });

  test('preferences round-trip the new fields', () {
    const prefs = AppPreferences(
      bluetoothLyrics: BluetoothLyricsMode.all,
      bluetoothLyricsTranslation: true,
      bluetoothLyricsDevices: ['AA'],
      flymeStatusBarLyrics: true,
      audioOutputDevice: 'wasapi/{x}',
    );
    expect(AppPreferences.decode(prefs.encode()), prefs);
  });

  group('AudioOutputService', () {
    test('missing saved device: default for now, preference kept, restored when back', () async {
      final backend = _Outputs([const AudioOutputDevice('a', 'Speakers')]);
      String? saved;
      final service = AudioOutputService(
        backend,
        initial: 'usb',
        onSelected: (id) => saved = id,
      );
      await service.refresh();
      expect(service.selected, '');
      expect(saved, isNull, reason: '设备暂时不在不应改写用户偏好');
      expect(backend.selected.last, '');

      backend.devices.add(const AudioOutputDevice('usb', 'USB DAC'));
      await service.refresh();
      expect(service.selected, 'usb');
      expect(backend.selected.last, 'usb');
    });

    test('select applies and persists', () async {
      final backend = _Outputs([const AudioOutputDevice('a', 'Speakers')]);
      String? saved;
      final service = AudioOutputService(backend, onSelected: (id) => saved = id);
      await service.select('a');
      expect(backend.selected, ['a']);
      expect(saved, 'a');
    });
  });
}

class _Outputs implements AudioOutputBackend {
  _Outputs(List<AudioOutputDevice> devices) : devices = [...devices];

  final List<AudioOutputDevice> devices;
  final selected = <String>[];

  @override
  Future<List<AudioOutputDevice>> list() async => devices;
  @override
  Future<void> select(String id) async => selected.add(id);
}
