import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutify_app/services/protocol/aes.dart';
import 'package:flutify_app/services/protocol/audio_normalization.dart';
import 'package:flutify_app/services/protocol/decrypt/decrypt_backend.dart';
import 'package:flutify_app/services/protocol/progressive_download.dart';
import 'package:flutify_app/services/protocol/track_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 合成一个「Spotify Ogg」：0xa7 字节私有头（偏移 144 处为响度数据）+ `OggS` 开头的正文。
Uint8List _spotifyOgg(int bodyLength) {
  final data = Uint8List(SpotifyAudioHeader.oggHeaderEnd + bodyLength);
  final loudness = ByteData.sublistView(data, AudioNormalization.headerOffset);
  loudness.setFloat32(0, -6.0, Endian.little); // track_gain_db
  loudness.setFloat32(4, 0.9, Endian.little); // track_peak
  data.setAll(SpotifyAudioHeader.oggHeaderEnd, 'OggS'.codeUnits);
  for (var i = SpotifyAudioHeader.oggHeaderEnd + 4; i < data.length; i++) {
    data[i] = (i * 31 + 7) & 0xff;
  }
  return data;
}

final _key = Uint8List.fromList(List.generate(16, (i) => i * 3));
final _iv = Uint8List.fromList(List.generate(16, (i) => 0xf0 + i));
final _spec = AesCtrDecryptSpec(key: _key, iv: _iv);

Uint8List _encrypt(Uint8List plain) {
  final out = Uint8List.fromList(plain);
  AesCtr(_key, _iv).process(out);
  return out;
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: true);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Stream<List<int>> _chunks(Uint8List data, {int size = 1000}) async* {
  for (var i = 0; i < data.length; i += size) {
    yield data.sublist(i, (i + size).clamp(0, data.length));
    await Future<void>.delayed(Duration.zero);
  }
}

/// 支持 Range 的假 CDN：无 Range 回 200 整份，有 Range 回 206 对应区间，并记录请求与并发数。
class _FakeCdn {
  _FakeCdn(
    this.cipher, {
    this.honorRange = true,
    this.gate,
    this.failBoundedStart,
    this.chunkDelay = Duration.zero,
  });

  final Uint8List cipher;

  /// false 时无视 Range，一律回 200 整份。
  final bool honorRange;

  /// 带 Range 的请求在它完成之前不回包（用来控制分段的先后）。
  final Future<void>? gate;

  /// 起点等于它、且带结尾的 Range 请求一律回 500（模拟某一段始终取不到）。
  final int? failBoundedStart;
  static const int chunkSize = 1000;
  final Duration chunkDelay;

  final requests = <http.BaseRequest>[];
  int _inflight = 0;
  int maxInflight = 0;

  http.Client get client => MockClient.streaming(_handle);

  /// 带 Range 的请求的起点，按发出顺序。
  List<int> get rangeStarts => [
    for (final r in requests)
      if (r.headers['Range'] != null) _parse(r.headers['Range']!).$1,
  ];

  /// 带 Range 的请求覆盖的字节数。
  List<int> get rangeSpans => [
    for (final r in requests)
      if (r.headers['Range'] != null && _parse(r.headers['Range']!).$2 != null)
        _parse(r.headers['Range']!).$2! - _parse(r.headers['Range']!).$1 + 1,
  ];

  static (int, int?) _parse(String range) {
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
    return (int.parse(m.group(1)!), m.group(2)!.isEmpty ? null : int.parse(m.group(2)!));
  }

  Future<http.StreamedResponse> _handle(http.BaseRequest request, http.ByteStream _) async {
    requests.add(request);
    final header = request.headers['Range'];
    if (header == null) return _body(200, 0, cipher.length, null);
    await gate;
    final (start, end) = _parse(header);
    if (end != null && start == failBoundedStart) {
      return http.StreamedResponse(const Stream<List<int>>.empty(), 500);
    }
    if (!honorRange) return _body(200, 0, cipher.length, null);
    final last = math.min(end ?? cipher.length - 1, cipher.length - 1);
    return _body(206, start, last + 1, 'bytes $start-$last/${cipher.length}');
  }

  http.StreamedResponse _body(int status, int start, int end, String? contentRange) {
    Stream<List<int>> stream() async* {
      _inflight++;
      maxInflight = math.max(maxInflight, _inflight);
      try {
        for (var i = start; i < end; i += chunkSize) {
          yield cipher.sublist(i, math.min(i + chunkSize, end));
          await Future<void>.delayed(chunkDelay);
        }
      } finally {
        _inflight--;
      }
    }

    return http.StreamedResponse(
      stream(),
      status,
      contentLength: end - start,
      headers: {'content-range': ?contentRange},
    );
  }
}
void main() {
  final isolateBackend = IsolateDecryptBackend();
  tearDownAll(isolateBackend.dispose);

  // 同一组用例分别在当前线程和常驻后台 Isolate 里解密，结果必须一致
  for (final (name, backend) in <(String, DecryptBackend)>[
    ('当前线程解密', const InlineDecryptBackend()),
    ('后台 Isolate 解密', isolateBackend),
  ]) {
    group(name, () => _suite(backend));
  }
}

void _suite(DecryptBackend backend) {
  test('解密、去掉私有头、读出响度数据；任意区间读取正确', () async {
    final plain = _spotifyOgg(20000);
    final cipher = _encrypt(plain);
    final client = MockClient.streaming((request, _) async {
      return http.StreamedResponse(_chunks(cipher), 200, contentLength: cipher.length);
    });

    final download = ProgressiveDownload(
      urls: ['https://cdn.test/a'],
      decrypt: _spec,
      backend: backend,
      format: AudioFileFormat.oggVorbis160,
      client: client,
    )..start();

    await download.ready;
    expect(download.length, plain.length - SpotifyAudioHeader.oggHeaderEnd);
    expect(download.normalization?.trackGainDb, closeTo(-6.0, 1e-6));
    expect(download.contentType, 'audio/ogg');

    // 头部到达后立即开始读，读取会等待后续数据
    final body = Uint8List.sublistView(plain, SpotifyAudioHeader.oggHeaderEnd);
    final all = await _collect(download.read(0));
    expect(all, body);

    final middle = await _collect(download.read(5000, 12345));
    expect(middle, Uint8List.sublistView(body, 5000, 12345));

    await download.done;
    expect(download.isComplete, isTrue);
    expect(download.playableBytes, body);
    expect(download.normalizationBytes, isNotNull);
  });

  test('中途断线后用 Range 续传，并换到下一个 CDN 地址', () async {
    final plain = _spotifyOgg(30000);
    final cipher = _encrypt(plain);
    const cutAt = 12000;
    final requests = <http.BaseRequest>[];

    final client = MockClient.streaming((request, _) async {
      requests.add(request);
      if (request.url.host == 'cdn1.test') {
        // 发出一部分后断开
        Stream<List<int>> broken() async* {
          yield* _chunks(Uint8List.sublistView(cipher, 0, cutAt));
          throw http.ClientException('connection reset');
        }

        return http.StreamedResponse(broken(), 200, contentLength: cipher.length);
      }
      final range = request.headers['Range']!;
      final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      return http.StreamedResponse(
        _chunks(Uint8List.sublistView(cipher, start)),
        206,
        contentLength: cipher.length - start,
        headers: {'content-range': 'bytes $start-${cipher.length - 1}/${cipher.length}'},
      );
    });

    final download = ProgressiveDownload(
      urls: ['https://cdn1.test/a', 'https://cdn2.test/a'],
      decrypt: _spec,
      backend: backend,
      format: AudioFileFormat.oggVorbis160,
      client: client,
    )..start();

    final read = _collect(download.read(0));
    await download.done;
    expect(requests, hasLength(2));
    expect(requests[1].headers['Range'], 'bytes=$cutAt-');
    expect(await read, Uint8List.sublistView(plain, SpotifyAudioHeader.oggHeaderEnd));
  });

  test('所有地址都失败：ready 抛错', () async {
    final client = MockClient((request) async => http.Response('nope', 403));
    final download = ProgressiveDownload(
      urls: ['https://cdn.test/a'],
      decrypt: _spec,
      backend: backend,
      format: AudioFileFormat.oggVorbis160,
      client: client,
      maxAttempts: 2,
    )..start();
    await expectLater(download.ready, throwsStateError);
    await expectLater(download.done, throwsStateError);
  });

  test('MP3 不跳过任何字节', () async {
    final plain = Uint8List.fromList(List.generate(4000, (i) => i & 0xff));
    final cipher = _encrypt(plain);
    final client = MockClient.streaming((request, _) async {
      return http.StreamedResponse(_chunks(cipher), 200, contentLength: cipher.length);
    });
    final download = ProgressiveDownload(
      urls: ['https://cdn.test/a'],
      decrypt: _spec,
      backend: backend,
      format: AudioFileFormat.mp3_160,
      client: client,
    )..start();
    await download.done;
    expect(download.length, plain.length);
    expect(download.normalization, isNull);
    expect(await _collect(download.read(0)), plain);
  });

  group('多连接分段并行', () {
    const seg = 4000;
    final plain = _spotifyOgg(40000); // 含私有头共 40167 字节 → 11 段
    final cipher = _encrypt(plain);
    final body = Uint8List.sublistView(plain, SpotifyAudioHeader.oggHeaderEnd);

    ProgressiveDownload build(_FakeCdn cdn, {int connections = 4, int maxAttempts = 4}) => ProgressiveDownload(
      urls: ['https://cdn1.test/a', 'https://cdn2.test/a'],
      decrypt: _spec,
      backend: backend,
      format: AudioFileFormat.oggVorbis160,
      client: cdn.client,
      connections: connections,
      segmentBytes: seg,
      maxAttempts: maxAttempts,
    );

    test('各段并行下载、各自从偏移处解密，拼出的内容与顺序下载一致', () async {
      final cdn = _FakeCdn(cipher, chunkDelay: const Duration(milliseconds: 1));
      final download = build(cdn)..start();

      expect(await _collect(download.read(0)), body);
      await download.done;
      expect(download.isComplete, isTrue);
      expect(download.playableBytes, body);
      expect(download.progress, 1.0);
      // 首个连接顺序下载 [0, seg)；其余 10 段每段恰好请求一次
      expect(cdn.rangeStarts, unorderedEquals([for (var i = 1; i <= 10; i++) i * seg]));
      expect(cdn.rangeSpans.every((n) => n <= seg), isTrue);
      expect(cdn.maxInflight, greaterThanOrEqualTo(2));
      expect(cdn.maxInflight, lessThanOrEqualTo(4));
    });

    test('connections 为 1 时只有一个顺序连接', () async {
      final cdn = _FakeCdn(cipher);
      final download = build(cdn, connections: 1)..start();
      await download.done;
      expect(cdn.requests, hasLength(1));
      expect(cdn.rangeStarts, isEmpty);
      expect(download.playableBytes, body);
    });

    test('播放器拖到还没下载的位置：该位置所在的段插队优先下载', () async {
      final gate = Completer<void>();
      final cdn = _FakeCdn(cipher, gate: gate.future, chunkDelay: const Duration(milliseconds: 5));
      final download = build(cdn, connections: 2)..start();
      await download.ready;

      const target = 31000; // 可播放坐标；文件坐标 31167 落在第 7 段（28000 起）
      final read = _collect(download.read(target, target + 500));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      gate.complete();

      expect(await read, Uint8List.sublistView(body, target, target + 500));
      await download.done;
      final order = cdn.rangeStarts;
      expect(order, contains(28000));
      expect(order.indexOf(28000), lessThan(order.indexOf(2 * seg)));
      expect(download.playableBytes, body);
    });

    test('服务器无视 Range（回 200）：退回单连接，内容仍然正确', () async {
      final cdn = _FakeCdn(cipher, honorRange: false);
      final download = build(cdn, connections: 3)..start();
      expect(await _collect(download.read(0)), body);
      await download.done;
      expect(download.playableBytes, body);
    });

    test('某一段始终失败：退回单连接补齐剩余部分，不比原来更差', () async {
      final cdn = _FakeCdn(cipher, failBoundedStart: 16000);
      final download = build(cdn, maxAttempts: 2)..start();
      expect(await _collect(download.read(0)), body);
      await download.done;
      expect(download.isComplete, isTrue);
      expect(download.playableBytes, body);
    });
  });}
