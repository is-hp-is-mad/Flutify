import 'dart:async';
import 'dart:convert';

import 'package:flutify_app/models/playback_state.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/connect/dealer_client.dart';
import 'package:flutify_app/services/connect/receiver/connect_receiver.dart';
import 'package:flutify_app/services/connect/receiver/playback_receiver_host.dart';
import 'package:flutify_app/services/connect/receiver/track_playback_state.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_dealer.dart';
import '../fakes/fake_track_audio_source.dart';

class _DelayedLoader extends FakeTrackAudioSource {
  final gates = <String, Completer<void>>{};
  @override
  Future<LoadedAudio> open(
    String trackIdOrUri, {
    void Function(double)? progress,
  }) async {
    final audio = await super.open(trackIdOrUri, progress: progress);
    await gates[trackIdOrUri]?.future;
    return audio;
  }
}

class _DelayedAudio extends FakeAudioPlayerService {
  Completer<void>? sourceGate;
  Object? playError;
  int sourceLoads = 0;

  @override
  Future<void> play() async {
    if (playError case final error?) throw error;
    await super.play();
  }

  @override
  Future<void> playFile(
    String path, {
    Duration? initialPosition,
    bool autoplay = true,
  }) async {
    sourceLoads++;
    await sourceGate?.future;
    await super.playFile(
      path,
      initialPosition: initialPosition,
      autoplay: autoplay,
    );
  }
}

Map<String, Object?> machine(List<String> ids, {Map<String, bool>? options}) =>
    {
      'state_machine_id': ids.join('-'),
      if (options != null) 'attributes': {'options': options},
      'tracks': [
        for (final id in ids)
          {
            'metadata': {
              'uri': 'spotify:track:$id',
              'name': id,
              'duration': 180000,
            },
          },
      ],
      'states': [
        for (var i = 0; i < ids.length; i++)
          {
            'state_id': ids[i],
            'track': i,
            'transitions': {
              if (i + 1 < ids.length) 'advance': {'state_index': i + 1},
              if (i + 1 < ids.length) 'skip_next': {'state_index': i + 1},
              if (i > 0) 'skip_prev': {'state_index': i - 1},
            },
          },
      ],
    };

void main() {
  late PlaybackProvider playback;
  late PlaybackReceiverHost host;
  late ConnectReceiver receiver;
  late DealerClient dealer;
  late FakeDealerServer server;
  late _DelayedAudio audio;
  late _DelayedLoader loader;
  Future<http.Response> Function(http.Request)? report;
  Future<http.Response> Function(http.Request)? registration;
  Future<http.Response> Function(http.Request)? conflict;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    audio = _DelayedAudio();
    loader = _DelayedLoader();
    playback = PlaybackProvider(
      audio,
      await StorageService.init(),
      audioLoader: loader,
    );
    host = PlaybackReceiverHost(
      playback,
      handoverRetryDelay: const Duration(milliseconds: 5),
    );
    server = FakeDealerServer();
    report = null;
    registration = null;
    conflict = null;
    final client = MockClient((r) async {
      if (r.url.host == 'clienttoken.spotify.com') {
        return http.Response(
          jsonEncode({
            'granted_token': {'token': 'test'},
          }),
          200,
        );
      }
      if (r.method == 'POST' && r.url.path.endsWith('/state_conflict')) {
        return conflict?.call(r) ?? http.Response('{"commands":[]}', 200);
      }
      if (r.method == 'POST') {
        return registration?.call(r) ??
            http.Response('{"initial_seq_num":0}', 200);
      }
      if (r.method == 'PUT' && r.url.path.endsWith('/state')) {
        return report?.call(r) ?? http.Response('', 204);
      }
      return http.Response('{}', 200);
    });
    dealer = DealerClient(
      client: client,
      headers: () async => {'Authorization': 'Bearer test'},
      connector: server.connect,
      initialBackoff: const Duration(milliseconds: 5),
      maxBackoff: const Duration(milliseconds: 10),
    );
    receiver = ConnectReceiver(
      host: host,
      deviceName: () => 'Test',
      client: client,
      webToken: () async => 'test',
      deviceId: 'test',
      dealer: dealer,
      registerRetryDelay: const Duration(milliseconds: 5),
    );
    host.receiver = receiver;
    final registered = Completer<void>();
    receiver.onRegistered = () {
      if (!registered.isCompleted) registered.complete();
    };
    await receiver.start();
    await registered.future;
  });

  tearDown(() async {
    await receiver.stop();
    host.dispose();
    playback.dispose();
    await dealer.dispose();
  });

  void replaceMachine(
    Map<String, Object?> value, {
    int? seek,
    bool paused = false,
  }) {
    server.channels.last.pushJson('hm://track-playback/v1/command', {
      'type': 'replace_state',
      'state_machine': value,
      'state_ref': {'state_index': 0, 'paused': paused},
      if (seek != null) 'seek_to': seek,
    });
  }

  void replace(List<String> ids, {Map<String, bool>? options, int? seek}) =>
      replaceMachine(machine(ids, options: options), seek: seek);

  Map<String, Object?> withAds(List<String> ids, Set<int> ads) {
    final value = machine(ids);
    for (final i in ads) {
      final meta = ((value['tracks'] as List)[i] as Map)['metadata'] as Map;
      meta['is_advertisement'] = i.isEven ? 'true' : true;
    }
    return value;
  }

  for (final paused in [false, true]) {
    test(
      'leading advertisements are never displayed or loaded (paused=$paused)',
      () async {
        final displayed = <String?>[];
        playback.addListener(() => displayed.add(playback.currentTrack?.id));
        final reports = <Map<String, dynamic>>[];
        report = (request) async {
          reports.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('', 204);
        };
        replaceMachine(
          withAds(['ad1', 'ad2', 'song', 'next'], {0, 1}),
          seek: 22000,
          paused: paused,
        );
        await until(
          () => reports.any(
            (r) => r['debug_source'] == (paused ? 'pause' : 'started_playing'),
          ),
        );
        expect(playback.currentTrack?.id, 'song');
        expect(playback.upNext.map((e) => e.track.id), ['next']);
        expect(displayed.whereType<String>().toSet(), {'song'});
        expect(loader.loaded, paused ? isEmpty : ['song']);
        expect(audio.isPlaying, !paused);
        expect(playback.position, Duration.zero);
        expect(
          reports.every((r) => r['state_ref']['state_id'] == 'song'),
          isTrue,
        );
        expect(reports.every((r) => r['sub_state']['position'] == 0), isTrue);
        expect(
          reports.any((r) => r['debug_source'] == 'played_threshold_reached'),
          isFalse,
        );
      },
    );
  }

  test(
    'automatic advance and previous keep Connect state across filtered ads',
    () async {
      replaceMachine(withAds(['a', 'ad1', 'ad2', 'b'], {1, 2}));
      await until(
        () => playback.currentTrack?.id == 'a' && !playback.isBuffering,
      );
      expect(playback.upNext.map((e) => e.track.id), ['b']);
      audio.emitCompleted();
      await until(
        () => playback.currentTrack?.id == 'b' && !playback.isBuffering,
      );
      expect(receiver.isActive, isTrue);
      await playback.previousTrack();
      await until(
        () => playback.currentTrack?.id == 'a' && !playback.isBuffering,
      );
      expect(receiver.isActive, isTrue);
      expect(loader.loaded.where((id) => id.startsWith('ad')), isEmpty);
    },
  );

  test(
    'all-ad cycle cancels a pending song without playing any advertisement',
    () async {
      loader.gates['old'] = Completer<void>();
      replace(['old']);
      await until(() => loader.loaded.contains('old'));
      final value = withAds(['ad1', 'ad2'], {0, 1});
      final states = value['states'] as List;
      (states[1]['transitions'] as Map)['advance'] = {'state_index': 0};
      replaceMachine(value);
      await until(() => !receiver.isActive);
      loader.gates['old']!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(audio.playedFiles, isEmpty);
      expect(audio.isPlaying, isFalse);
      expect(playback.isBuffering, isFalse);
      expect(playback.currentTrack?.id, 'old');
      expect(loader.loaded, ['old']);
      replace(['recovered']);
      await until(
        () => playback.currentTrack?.id == 'recovered' && !playback.isBuffering,
      );
      expect(audio.isPlaying, isTrue);
    },
  );

  test('expanded and same-track queues do not expose advertisements', () async {
    report = (_) async => http.Response(
      jsonEncode({
        'state_machine': withAds(['a', 'ad', 'b'], {1}),
        'updated_state_ref': {'state_index': 0},
      }),
      200,
    );
    replace(['a']);
    await until(() => playback.upNext.isNotEmpty);
    expect(playback.upNext.map((e) => e.track.id), ['b']);
    report = null;
    replaceMachine(withAds(['a', 'ad', 'c'], {1}));
    await until(() => playback.upNext.last.track.id == 'c');
    expect(playback.upNext.map((e) => e.track.id), ['c']);
    expect(loader.loaded, ['a']);
  });

  test('ad URI is skipped, promotional song title alone is not', () async {
    final value = machine(['ad', 'song']);
    final tracks = value['tracks'] as List;
    tracks[0]['metadata']['uri'] = 'spotify:ad:promo';
    tracks[1]['metadata']['name'] = '広告ナシで音楽を聴こう。';
    tracks[1]['metadata']['duration'] = 28000;
    replaceMachine(value);
    await until(
      () => playback.currentTrack?.id == 'song' && !playback.isBuffering,
    );
    expect(loader.loaded, ['song']);
    expect(playback.currentTrack?.name, '広告ナシで音楽を聴こう。');
  });

  test('late load cannot overwrite the latest track or queue', () async {
    loader.gates['a'] = Completer<void>();
    replace(['a', 'b']);
    await until(() => loader.loaded.contains('a'));
    replace(['x', 'y']);
    await until(
      () => playback.currentTrack?.id == 'x' && !playback.isBuffering,
    );
    loader.gates['a']!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(playback.currentTrack?.id, 'x');
    expect(playback.upNext.map((e) => e.track.id), ['y']);
    expect(audio.playedFiles, [contains('x')]);
  });

  test(
    'initial receiver playback retains the selected playlist beyond its two-track window',
    () async {
      const context = PlaybackContext.playlist(
        'Full playlist',
        uri: 'spotify:playlist:test',
      );
      final tracks = [
        for (final id in ['a', 'b', 'c', 'd'])
          SpotifyTrack(id: id, uri: 'spotify:track:$id', name: id),
      ];
      playback.prepareReceiverQueue(context, tracks, tracks[1]);
      replace(['b', 'c'], options: {'shuffling_context': false});
      await until(
        () => playback.currentTrack?.id == 'b' && !playback.isBuffering,
      );
      expect(playback.upNext.map((e) => e.track.id), ['c', 'd']);
      expect(playback.playbackContext.name, 'Full playlist');
      expect(loader.loaded, ['b']);
      replace(['c', 'd']);
      await until(
        () => playback.currentTrack?.id == 'c' && !playback.isBuffering,
      );
      expect(playback.upNext.map((e) => e.track.id), ['d']);
      expect(playback.playbackContext.name, 'Full playlist');
      await playback.previousTrack();
      expect(playback.currentTrack?.id, 'b');
    },
  );

  test(
    'same current track accepts a new full context without reloading audio',
    () async {
      replace(['a', 'b']);
      await until(
        () => playback.currentTrack?.id == 'a' && !playback.isBuffering,
      );
      final tracks = [
        for (final id in ['a', 'c', 'd'])
          SpotifyTrack(id: id, uri: 'spotify:track:$id', name: id),
      ];
      playback.prepareReceiverQueue(
        const PlaybackContext.playlist('Other'),
        tracks,
        tracks.first,
      );
      replace(['a', 'c']);
      await until(() => playback.upNext.length == 2);
      expect(playback.upNext.map((e) => e.track.id), ['c', 'd']);
      expect(playback.playbackContext.name, 'Other');
      expect(loader.loaded, ['a']);
    },
  );

  for (final shuffled in [false, true]) {
    test(
      'receiver ${shuffled ? 'shuffle' : 'changed order'} does not append an invented playlist tail',
      () async {
        final tracks = [
          for (final id in ['a', 'b', 'c', 'd'])
            SpotifyTrack(id: id, uri: 'spotify:track:$id', name: id),
        ];
        final old = playback.prepareReceiverQueue(
          const PlaybackContext.playlist('Old'),
          tracks,
          tracks[1],
        );
        playback.prepareReceiverQueue(
          const PlaybackContext.playlist('New'),
          tracks,
          tracks.first,
        );
        playback.cancelReceiverQueue(old);
        replace(
          ['a', shuffled ? 'b' : 'c'],
          options: {'shuffling_context': shuffled},
        );
        await until(
          () => playback.currentTrack?.id == 'a' && !playback.isBuffering,
        );
        expect(playback.upNext.map((e) => e.track.id), [shuffled ? 'b' : 'c']);
        expect(playback.playbackContext.name, 'New');
      },
    );
  }

  test(
    'transfer away cancels loading; resume retains the requested seek position',
    () async {
      loader.gates['a'] = Completer<void>();
      replace(['a', 'b']);
      await until(() => loader.loaded.contains('a'));
      await host.sync(positionMs: 42000, paused: true);
      loader.gates['a']!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(audio.playedFiles, isEmpty);
      expect(audio.isPlaying, isFalse);
      await host.sync(positionMs: null, paused: false);
      expect(audio.initialPositions.single, const Duration(seconds: 42));
      expect(audio.isPlaying, isTrue);
    },
  );

  for (final explicitNull in [true, false]) {
    test(
      'wire transfer revokes playing device (null ref=$explicitNull)',
      () async {
        replace(['a', 'b']);
        await until(() => audio.isPlaying);
        server.channels.last.pushJson('hm://track-playback/v1/command', {
          'type': 'replace_state',
          if (explicitNull) 'state_ref': null,
        });
        await until(() => !receiver.isActive && !audio.isPlaying);
        expect(playback.currentTrack?.id, 'a');
        // A fresh explicit transfer back must still work, including the same song.
        replace(['a', 'b']);
        await until(() => receiver.isActive && audio.isPlaying);
      },
    );
  }

  test('wire transfer cancels an unfinished source load', () async {
    audio.sourceGate = Completer<void>();
    replace(['a', 'b']);
    await until(() => audio.sourceLoads == 1);
    server.channels.last.pushJson('hm://track-playback/v1/command', {
      'type': 'replace_state',
      'state_ref': null,
    });
    await until(() => !receiver.isActive && !playback.isLoadingTrack);
    audio.sourceGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(audio.isPlaying, isFalse);
    expect(playback.isBuffering, isFalse);
  });

  for (final resumeBeforeReply in [false, true]) {
    test(
      'revoked handover permits local resume (before reply=$resumeBeforeReply)',
      () async {
        final handover = Completer<bool>();
        var attempts = 0;
        host.handOver = (_) {
          attempts++;
          return attempts == 1 ? handover.future : Future.value(true);
        };
        final m = TpStateMachine.fromJson(machine(['a']))!;
        await host.load(m, [0], positionMs: 0, paused: false);
        audio.stateController.add(PlayerState(true, ProcessingState.ready));
        await until(() => attempts == 1);
        server.channels.last.pushJson('hm://track-playback/v1/command', {
          'type': 'replace_state',
          'state_ref': null,
        });
        await until(() => !audio.isPlaying);
        audio.stateController.add(PlayerState(false, ProcessingState.ready));
        if (resumeBeforeReply) {
          await playback.togglePlayPause();
          audio.stateController.add(PlayerState(true, ProcessingState.ready));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(attempts, 1);
        }
        handover.complete(true);
        if (!resumeBeforeReply) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(attempts, 1);
          await playback.togglePlayPause();
          audio.stateController.add(PlayerState(true, ProcessingState.ready));
        }
        await until(() => attempts == 2);
      },
    );
  }

  test('stop immediately after load prevents audio from starting', () async {
    final m = TpStateMachine.fromJson(machine(['a', 'b']))!;
    final loading = host.load(m, [0, 1], positionMs: 0, paused: false);
    await host.stop();
    await loading;
    expect(audio.playedFiles, isEmpty);
    expect(audio.isPlaying, isFalse);
    expect(playback.isBuffering, isFalse);
  });

  test(
    'pause while the audio engine loads a source prevents late autoplay',
    () async {
      audio.sourceGate = Completer<void>();
      final m = TpStateMachine.fromJson(machine(['a', 'b']))!;
      final loading = host.load(m, [0, 1], positionMs: 10000, paused: false);
      await until(() => audio.sourceLoads == 1);
      await host.sync(positionMs: 42000, paused: true);
      audio.sourceGate!.complete();
      await loading;
      expect(audio.isPlaying, isFalse);
      expect(playback.isBuffering, isFalse);
      await host.sync(positionMs: null, paused: false);
      expect(audio.initialPositions.last, const Duration(seconds: 42));
      expect(audio.isPlaying, isTrue);
    },
  );

  test(
    'seek while the audio engine loads is applied before playback starts',
    () async {
      audio.sourceGate = Completer<void>();
      final m = TpStateMachine.fromJson(machine(['a', 'b']))!;
      final loading = host.load(m, [0, 1], positionMs: 10000, paused: false);
      await until(() => audio.sourceLoads == 1);
      await host.sync(positionMs: 42000, paused: false);
      audio.sourceGate!.complete();
      await loading;
      expect(audio.seeks.single, const Duration(seconds: 42));
      expect(playback.position, const Duration(seconds: 42));
      expect(audio.isPlaying, isTrue);
    },
  );

  test(
    'asynchronous audio start failure is reported and can be retried',
    () async {
      audio.playError = StateError('audio device unavailable');
      final m = TpStateMachine.fromJson(machine(['a']))!;
      await host.load(m, [0], positionMs: 10000, paused: false);
      await until(() => playback.playbackError != null);
      expect(playback.isBuffering, isFalse);
      expect(audio.isPlaying, isFalse);
      audio.playError = null;
      await host.sync(positionMs: null, paused: false);
      expect(playback.playbackError, isNull);
      expect(audio.isPlaying, isTrue);
    },
  );

  test(
    'paused replacement cancels old load without leaving the new track buffering',
    () async {
      loader.gates['a'] = Completer<void>();
      replace(['a', 'b']);
      await until(() => loader.loaded.contains('a'));
      final m = TpStateMachine.fromJson(machine(['x', 'y']))!;
      await host.load(m, [0, 1], positionMs: 10000, paused: true);
      loader.gates['a']!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(playback.currentTrack?.id, 'x');
      expect(playback.isBuffering, isFalse);
      expect(audio.isPlaying, isFalse);
      await host.sync(positionMs: null, paused: false);
      expect(audio.playedFiles, [contains('x')]);
      expect(audio.initialPositions.single, const Duration(seconds: 10));
    },
  );

  test(
    'failed receiver registration retries on the same reconnected dealer',
    () async {
      var calls = 0;
      var registered = 0;
      receiver.onRegistered = () => registered++;
      registration = (_) async => ++calls < 3
          ? http.Response('temporary', 503)
          : http.Response('{"initial_seq_num":7}', 200);
      server.channels.last.drop();
      await until(() => registered == 1);
      expect(calls, 3);
      expect(server.channels.length, 2);
    },
  );

  test(
    'local handover retries temporary failure and stops after success',
    () async {
      var attempts = 0;
      host.handOver = (_) async => ++attempts >= 2;
      final m = TpStateMachine.fromJson(machine(['a']))!;
      await host.load(m, [0], positionMs: 0, paused: false);
      audio.stateController.add(PlayerState(true, ProcessingState.ready));
      await until(() => attempts == 2);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      playback.setVolume(0.5);
      expect(attempts, 2);
    },
  );

  test(
    'handover retries are bounded and registration can recover the same track',
    () async {
      var attempts = 0;
      host.handOver = (_) async {
        attempts++;
        return false;
      };
      final m = TpStateMachine.fromJson(machine(['a']))!;
      await host.load(m, [0], positionMs: 0, paused: false);
      audio.stateController.add(PlayerState(true, ProcessingState.ready));
      await until(() => attempts == 3);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(attempts, 3);
      host.handOver = (_) async {
        attempts++;
        return true;
      };
      host.onReceiverRegistered();
      await until(() => attempts == 4);
    },
  );

  test(
    'stopping during registration ignores late success and schedules no retry',
    () async {
      final response = Completer<http.Response>();
      var calls = 0;
      var registered = 0;
      receiver.onRegistered = () => registered++;
      registration = (_) {
        calls++;
        return response.future;
      };
      server.channels.last.drop();
      await until(() => calls == 1);
      await receiver.stop();
      response.complete(http.Response('{"initial_seq_num":7}', 200));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(registered, 0);
      expect(calls, 1);
    },
  );

  test(
    'expanded state report reaches local queue without reloading current track',
    () async {
      report = (_) async => http.Response(
        jsonEncode({
          'state_machine': machine(['a', 'b', 'c', 'd']),
          'updated_state_ref': {'state_index': 0},
        }),
        200,
      );
      replace(['a', 'b']);
      await until(() => playback.upNext.length == 3);
      expect(loader.loaded, ['a']);
      await playback.nextTrack();
      expect(playback.currentTrack?.id, 'b');
      expect(playback.canSkipNext, isTrue);
    },
  );

  test(
    'same-track replacement updates queue and absent options preserve repeat',
    () async {
      replace(['a', 'b'], options: {'repeating_context': true});
      await until(
        () => playback.currentTrack?.id == 'a' && !playback.isBuffering,
      );
      replace(['a', 'b', 'c']);
      await until(() => playback.upNext.length == 2);
      expect(loader.loaded, ['a']);
      expect(playback.repeatMode, SpotifyRepeatMode.context);
      replace(
        ['a', 'c'],
        options: {'repeating_context': false, 'repeating_track': false},
      );
      await until(() => playback.repeatMode == SpotifyRepeatMode.off);
      expect(playback.upNext.single.track.id, 'c');
    },
  );

  test('response from an older command cannot replace a newer queue', () async {
    final response = Completer<http.Response>();
    var calls = 0;
    report = (_) async {
      if (++calls == 1) return response.future;
      return http.Response('', 204);
    };
    replace(['a', 'b']);
    await until(() => calls == 1 && playback.currentTrack?.id == 'a');
    replace(['x', 'y']);
    await until(() => playback.currentTrack?.id == 'x');
    response.complete(
      http.Response(
        jsonEncode({
          'state_machine': machine(['a', 'b', 'c']),
          'updated_state_ref': {'state_index': 0},
        }),
        200,
      ),
    );
    await until(() => calls > 1);
    expect(playback.currentTrack?.id, 'x');
    expect(playback.upNext.single.track.id, 'y');
  });

  test('single-track repeat still exposes the manual next transition', () {
    final json = machine(['a', 'b']);
    final states = json['states'] as List;
    (states[0]['transitions'] as Map)['advance'] = {'state_index': 0};
    expect(TpStateMachine.fromJson(json)!.advanceChain(0), [0, 1]);
  });

  test('missing advance still follows a valid manual next transition', () {
    final json = machine(['a', 'b', 'c']);
    final states = json['states'] as List;
    (states[0]['transitions'] as Map).remove('advance');
    expect(TpStateMachine.fromJson(json)!.advanceChain(0), [0, 1, 2]);
  });

  test('leaving the receiver queue reports a cleared state', () async {
    final reports = <Map<String, dynamic>>[];
    report = (request) async {
      reports.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('', 204);
    };
    replace(['a', 'b']);
    await until(
      () => playback.currentTrack?.id == 'a' && !playback.isBuffering,
    );
    receiver.onLocalTrackChanged('spotify:track:outside', durationMs: 180000);
    await until(() => reports.any((r) => r['debug_source'] == 'state_clear'));
    expect(receiver.isActive, isFalse);
    expect(reports.last['state_ref'], isNull);
  });

  group('prev_state_ref（与官方 Web Player 一致）', () {
    const current = {'state_machine_id': 'a-b', 'state_id': 'a', 'paused': false};

    Future<void> playAB() async {
      replace(['a', 'b']);
      await until(() => receiver.isActive && audio.isPlaying);
    }

    test('与本机当前状态一致：照常执行（转走 = 清空并停止）', () async {
      await playAB();
      server.channels.last.pushJson('hm://track-playback/v1/command', {
        'type': 'replace_state',
        'prev_state_ref': current,
        'state_ref': null,
      });
      await until(() => !receiver.isActive && !audio.isPlaying);
    });

    test('基于过期状态：拒绝并经 state_conflict 执行服务端给的命令', () async {
      final bodies = <Map<String, dynamic>>[];
      conflict = (request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'commands': [
              {
                'type': 'replace_state',
                'prev_state_ref': current,
                'state_ref': null,
              },
            ],
          }),
          200,
        );
      };
      await playAB();
      server.channels.last.pushJson('hm://track-playback/v1/command', {
        'type': 'replace_state',
        'prev_state_ref': {
          'state_machine_id': 'old',
          'state_id': 'x',
          'paused': false,
        },
        'state_machine': machine(['c']),
        'state_ref': {'state_index': 0, 'paused': true},
      });
      await until(() => !receiver.isActive && !audio.isPlaying);

      // 过期命令没有执行（没有换成 c）
      expect(playback.currentTrack?.id, 'a');
      expect(bodies, hasLength(1));
      expect(bodies.single['state_ref'], current);
      expect(bodies.single['rejected_state_refs'], [
        {'state_machine_id': 'c', 'state_id': 'c', 'paused': true},
      ]);
      expect(bodies.single['seq_nums'], hasLength(1));
    });
  });
}
