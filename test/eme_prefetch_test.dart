import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/auth/proto_codec.dart';
import 'package:flutify_app/services/eme/fairplay.dart';
import 'package:flutify_app/services/eme/streaming_download.dart';
import 'package:flutify_app/services/protocol/eme_track_audio_source.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';

const _trackId = '0000000000000000000001';
const _otherTrackId = '0000000000000000000002';
const _fileId = '1111111111111111111111111111111111111111';
const _otherFileId = '2222222222222222222222222222222222222222';
const _prefixBytes = 256 * 1024;
const _audioBytes = _prefixBytes + 8;

class _DownloadGate {
  final requested = Completer<void>();
  final remainder = Completer<void>();
  Object? failure;

  void release() {
    if (!remainder.isCompleted) remainder.complete();
  }

  void fail() {
    failure = const HttpException('Connection lost after the playable prefix');
    release();
  }
}

class _Fixture {
  final Directory root;
  final _DownloadGate? gate;
  final requests = <http.BaseRequest>[];
  final _downloadPaths = <String>{};
  late final EmeTrackAudioSource source;
  late String cacheDirectory;
  bool webSessionReady = true;
  bool _gateUsed = false;

  _Fixture(this.root, {this.gate}) {
    cacheDirectory = root.path;
    source = EmeTrackAudioSource(
      cacheDirectory: root.path,
      cacheDirectoryProvider: () => cacheDirectory,
      accessToken: () async => 'test-token',
      webSessionReady: () => webSessionReady,
      client: MockClient.streaming((request, _) async {
        requests.add(request);
        if (request.url.path.contains('track-playback')) {
          final id = request.url.path.contains(_otherTrackId)
              ? _otherTrackId
              : _trackId;
          final fileId = id == _otherTrackId ? _otherFileId : _fileId;
          return _response(
            utf8.encode(
              jsonEncode({
                'media': {
                  'spotify:track:$id': {
                    'item': {
                      'metadata': {'duration': 180000},
                      'manifest': {
                        'file_ids_mp4': [
                          {'file_id': fileId, 'format': 10, 'bitrate': 128000},
                        ],
                      },
                    },
                  },
                },
              }),
            ),
          );
        }
        if (request.url.path.contains('sneaktables')) {
          return _response(utf8.encode('#EXTM3U\n#EXT-X-VERSION:7'));
        }
        if (request.url.path.contains('storage-resolve')) {
          final fileId = request.url.path.contains(_otherFileId)
              ? _otherFileId
              : _fileId;
          return _response(
            (ProtoWriter()..string(2, 'https://cdn.test/$fileId')).toBytes(),
          );
        }
        expect(request.url.host, 'cdn.test');
        final fileId = request.url.pathSegments.last;
        _downloadPaths.add(fileFor(fileId).path);
        final activeGate = fileId == _fileId && !_gateUsed ? gate : null;
        if (activeGate != null) {
          _gateUsed = true;
          activeGate.requested.complete();
        }
        return http.StreamedResponse(
          _audioBody(activeGate),
          200,
          contentLength: _audioBytes,
        );
      }),
    );
  }

  File get file => fileFor(_fileId);

  File fileFor(String fileId) =>
      File(p.join(cacheDirectory, 'eme_audio', '$fileId.m4a'));

  Stream<List<int>> _audioBody(_DownloadGate? activeGate) async* {
    yield Uint8List(_prefixBytes);
    if (activeGate != null) {
      await activeGate.remainder.future;
      if (activeGate.failure != null) throw activeGate.failure!;
    }
    yield List.filled(8, 7);
  }

  Future<void> waitForPrefix() async {
    await gate!.requested.future.timeout(const Duration(seconds: 5));
    await StreamingDownloads.of(
      file.path,
    )!.waitFor(_prefixBytes).timeout(const Duration(seconds: 5));
  }

  Future<void> settleDownload() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_downloadPaths.any((path) => StreamingDownloads.of(path) != null)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('The test download did not finish');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> dispose() async {
    gate?.release();
    await settleDownload();
    await source.trimCache();
    source.dispose();
    await root.delete(recursive: true);
  }
}

http.StreamedResponse _response(List<int> bytes) => http.StreamedResponse(
  Stream.value(bytes),
  200,
  contentLength: bytes.length,
);

Future<void> _waitUntil(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'The expected playback state did not become ready',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugUseFairPlayOverride = false);
  tearDown(() => debugUseFairPlayOverride = null);

  Future<_Fixture> fixture({_DownloadGate? gate}) async {
    final root = await Directory.systemTemp.createTemp('flutify-eme-prefetch-');
    final fixture = _Fixture(root, gate: gate);
    addTearDown(fixture.dispose);
    return fixture;
  }

  test(
    'prefetch waits for the whole song while open can start early',
    () async {
      final gate = _DownloadGate();
      final f = await fixture(gate: gate);
      var prefetched = false;
      final prefetch = f.source
          .prefetch(_trackId)
          .then((_) => prefetched = true);
      final opening = f.source.open('spotify:track:$_trackId');
      await f.waitForPrefix();
      final audio = await opening.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(audio.file.lengthSync(), _prefixBytes);
      expect(
        prefetched,
        isFalse,
        reason: 'A playable prefix is not a fully prefetched next song',
      );
      expect(f.requests.where((r) => r.url.host == 'cdn.test'), hasLength(1));

      gate.release();
      await prefetch.timeout(const Duration(seconds: 5));
      expect(audio.file.lengthSync(), _audioBytes);
      expect(File('${audio.path}.done').existsSync(), isTrue);
    },
  );

  test(
    'opening a prefetched song needs no new playback metadata or CDN',
    () async {
      final f = await fixture();
      await f.source.prefetch('spotify:track:$_trackId');
      await f.settleDownload();
      final requestsAfterPrefetch = f.requests.length;

      final audio = await f.source.open(_trackId);

      expect(audio.file.lengthSync(), _audioBytes);
      expect(audio.emeContent!.m3u8, contains('#EXTM3U'));
      expect(
        f.requests.length,
        requestsAfterPrefetch,
        reason:
            'Next-song handoff must not wait for track-playback or HLS again',
      );
    },
  );

  test(
    'open joins a prefetch even after its playable prefix is ready',
    () async {
      final gate = _DownloadGate();
      final f = await fixture(gate: gate);
      final prefetch = f.source.prefetch(_trackId);
      await f.waitForPrefix();
      await Future<void>.delayed(Duration.zero);
      final requestsBeforeOpen = f.requests.length;

      final audio = await f.source
          .open(_trackId)
          .timeout(const Duration(seconds: 5));

      expect(audio.file.lengthSync(), _prefixBytes);
      expect(f.requests.length, requestsBeforeOpen);
      gate.release();
      await prefetch.timeout(const Duration(seconds: 5));
      expect(audio.file.lengthSync(), _audioBytes);
    },
  );

  for (final removed in ['audio', 'completion marker']) {
    test('a missing $removed invalidates the prepared song', () async {
      final f = await fixture();
      await f.source.prefetch(_trackId);
      await f.settleDownload();
      final missing = removed == 'audio' ? f.file : File('${f.file.path}.done');
      await missing.delete();
      final requestsBeforeOpen = f.requests.length;

      final audio = await f.source.open(_trackId);
      await f.settleDownload();

      expect(audio.file.lengthSync(), _audioBytes);
      expect(File('${audio.path}.done').existsSync(), isTrue);
      expect(f.requests.length, greaterThan(requestsBeforeOpen));
      expect(f.requests.where((r) => r.url.host == 'cdn.test'), hasLength(2));
    });
  }

  test('moving the cache directory invalidates a prepared path', () async {
    final f = await fixture();
    await f.source.prefetch(_trackId);
    await f.settleDownload();
    await f.source.trimCache();
    final oldPath = f.file.path;
    f.cacheDirectory = p.join(f.root.path, 'moved');

    final audio = await f.source.open(_trackId);
    await f.settleDownload();

    expect(audio.path, f.file.path);
    expect(audio.path, isNot(oldPath));
    expect(audio.file.lengthSync(), _audioBytes);
    expect(f.requests.where((r) => r.url.host == 'cdn.test'), hasLength(2));
  });

  test('prepared metadata cannot bypass an expired Web session', () async {
    final f = await fixture();
    await f.source.prefetch(_trackId);
    await f.settleDownload();
    final requestsBeforeSignOut = f.requests.length;
    f.webSessionReady = false;

    await expectLater(
      f.source.open(_trackId),
      throwsA(
        isA<TrackPlaybackException>().having(
          (error) => error.kind,
          'failure',
          TrackPlaybackFailure.webSignInRequired,
        ),
      ),
    );
    await f.source.prefetch(_trackId);
    expect(f.requests.length, requestsBeforeSignOut);
  });

  test('prefetch skips both episode URIs and episode URLs', () async {
    final f = await fixture();

    await f.source.prefetch('spotify:episode:$_trackId');
    await f.source.prefetch('https://open.spotify.com/episode/$_trackId');

    expect(f.requests, isEmpty);
    expect(await f.root.list().toList(), isEmpty);
  });

  test('only the latest next song keeps prepared playback metadata', () async {
    final f = await fixture();
    await f.source.prefetch(_trackId);
    await f.source.prefetch(_otherTrackId);
    await f.settleDownload();
    final requestsAfterPrefetch = f.requests.length;

    final next = await f.source.open(_otherTrackId);
    expect(next.trackId, _otherTrackId);
    expect(f.requests.length, requestsAfterPrefetch);

    final older = await f.source.open(_trackId);
    expect(older.trackId, _trackId);
    expect(f.requests.length, greaterThan(requestsAfterPrefetch));
  });

  test(
    'an older prefetch finishing late does not replace the next song',
    () async {
      final gate = _DownloadGate();
      final f = await fixture(gate: gate);
      final older = f.source.prefetch(_trackId);
      await f.waitForPrefix();
      await f.source.prefetch(_otherTrackId);
      gate.release();
      await older;
      await f.settleDownload();
      final requestsAfterPrefetch = f.requests.length;

      final next = await f.source.open(_otherTrackId);

      expect(next.trackId, _otherTrackId);
      expect(f.requests.length, requestsAfterPrefetch);
    },
  );

  test('a failed prefetch is retried by foreground playback', () async {
    final gate = _DownloadGate();
    final f = await fixture(gate: gate);
    final prefetch = f.source.prefetch(_trackId);
    await f.waitForPrefix();
    gate.fail();
    await prefetch;
    await f.settleDownload();
    expect(File('${f.file.path}.done').existsSync(), isFalse);

    final audio = await f.source.open(_trackId);
    await f.settleDownload();

    expect(audio.file.lengthSync(), _audioBytes);
    expect(File('${audio.path}.done').existsSync(), isTrue);
    expect(f.requests.where((r) => r.url.host == 'cdn.test'), hasLength(2));
  });

  test(
    'DRM open exposes a separate whole-download completion signal',
    () async {
      final gate = _DownloadGate();
      final f = await fixture(gate: gate);
      final audio = await f.source.open(_trackId);
      expect(audio.downloadComplete, isNotNull);
      var downloaded = false;
      final completion = audio.downloadComplete!.then((_) => downloaded = true);
      await Future<void>.delayed(Duration.zero);

      expect(audio.file.lengthSync(), _prefixBytes);
      expect(downloaded, isFalse);

      gate.release();
      await completion.timeout(const Duration(seconds: 5));
      expect(audio.file.lengthSync(), _audioBytes);
      expect(File('${audio.path}.done').existsSync(), isTrue);
    },
  );

  test('late transfer failure is reported by the completion signal', () async {
    final gate = _DownloadGate();
    final f = await fixture(gate: gate);
    final audio = await f.source.open(_trackId);
    expect(audio.downloadComplete, isNotNull);
    final failure = expectLater(
      audio.downloadComplete!,
      throwsA(isA<HttpException>()),
    );

    gate.fail();
    await failure;

    expect(File('${audio.path}.done').existsSync(), isFalse);
    final retry = await f.source.load(_trackId);
    expect(retry.file.lengthSync(), _audioBytes);
    expect(f.requests.where((r) => r.url.host == 'cdn.test'), hasLength(2));
  });

  test(
    'an unobserved late transfer failure does not escape the loader',
    () async {
      final gate = _DownloadGate();
      final f = await fixture(gate: gate);
      await f.source.open(_trackId);

      gate.fail();
      await f.settleDownload();
      await Future<void>.delayed(Duration.zero);

      expect(File('${f.file.path}.done').existsSync(), isFalse);
    },
  );

  test('concurrent prefetch callers both wait for the entire song', () async {
    final gate = _DownloadGate();
    final f = await fixture(gate: gate);
    var firstDone = false;
    var secondDone = false;
    final first = f.source.prefetch(_trackId).then((_) => firstDone = true);
    final second = f.source.prefetch(_trackId).then((_) => secondDone = true);
    await f.waitForPrefix();
    await Future<void>.delayed(Duration.zero);

    expect(firstDone, isFalse);
    expect(secondDone, isFalse);
    expect(f.requests.where((r) => r.url.host == 'cdn.test'), hasLength(1));

    gate.release();
    await Future.wait([first, second]);
    expect(f.file.lengthSync(), _audioBytes);
  });

  test(
    'fully loaded current song starts prefetch and completion reuses it',
    () async {
      const current = SpotifyTrack(
        id: _trackId,
        name: 'Current song',
        uri: 'spotify:track:$_trackId',
        durationMs: 180000,
      );
      const next = SpotifyTrack(
        id: _otherTrackId,
        name: 'Next song',
        uri: 'spotify:track:$_otherTrackId',
        durationMs: 180000,
      );
      SharedPreferences.setMockInitialValues({});
      final gate = _DownloadGate();
      final f = await fixture(gate: gate);
      final audio = FakeAudioPlayerService();
      final playback = PlaybackProvider(
        audio,
        await StorageService.init(),
        audioLoader: f.source,
      );
      addTearDown(playback.dispose);

      await playback.playTrack(current, contextQueue: [current, next]);

      expect(audio.isPlaying, isTrue);
      expect(audio.playedEme.single.fileIdHex, _fileId);
      expect(f.file.lengthSync(), _prefixBytes);
      expect(
        f.requests.where((r) => r.url.path.contains(_otherTrackId)),
        isEmpty,
        reason: 'The next download must not compete with the current one',
      );

      gate.release();
      final nextFile = f.fileFor(_otherFileId);
      await _waitUntil(
        () =>
            File('${nextFile.path}.done').existsSync() &&
            StreamingDownloads.of(nextFile.path) == null,
      );
      await f.settleDownload();
      final requestsAfterPrefetch = f.requests.length;
      expect(nextFile.lengthSync(), _audioBytes);
      expect(playback.currentTrack, current);

      audio.emitCompleted();
      await _waitUntil(() => audio.playedEme.length == 2);
      await Future<void>.delayed(Duration.zero);

      expect(playback.currentTrack, next);
      expect(audio.isPlaying, isTrue);
      expect(audio.playedEme.last.fileIdHex, _otherFileId);
      expect(
        f.requests.length,
        requestsAfterPrefetch,
        reason: 'Automatic next-song playback must adopt the prepared download',
      );
    },
  );
}
