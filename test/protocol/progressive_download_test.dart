import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutify_app/services/protocol/audio_normalization.dart';
import 'package:flutify_app/services/protocol/progressive_download.dart';
import 'package:flutify_app/services/protocol/track_metadata.dart';
import 'package:flutify_app/src/rust/api/network.dart' show AudioDownloadEvent;
import 'package:flutter_test/flutter_test.dart';

// 下载、解密、续传与重试在 Rust（downloads::download_progressive，有自己的单元测试）；
// 这里用假事件流驱动 ProgressiveDownload，验证 Dart 侧的缓冲、起播、按区间读取、取消与错误传递。

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

AudioDownloadEvent _event(
  int kind, {
  int status = 0,
  int total = 0,
  int bytes = 0,
  Uint8List? data,
  String message = '',
}) => AudioDownloadEvent(
  kind: kind,
  status: status,
  total: total,
  bytes: bytes,
  data: data ?? Uint8List(0),
  message: message,
);

AudioDownloadEvent _meta(int total, {int status = 200, int start = 0}) =>
    _event(0, status: status, total: total, bytes: start);
AudioDownloadEvent _done(int total) => _event(3, total: total);
AudioDownloadEvent _error(String message) => _event(4, message: message);

/// 把 [data] 的 `[from, to)` 按块推送为数据事件（带文件偏移），块之间让出事件循环。
Future<void> _push(
  StreamController<AudioDownloadEvent> c,
  Uint8List data, {
  int from = 0,
  int? to,
  int size = 1000,
}) async {
  final end = to ?? data.length;
  for (var i = from; i < end; i += size) {
    final stop = (i + size).clamp(0, end);
    c.add(_event(1, bytes: i, data: Uint8List.fromList(data.sublist(i, stop))));
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: true);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// 假事件来源：记录调用参数，事件由测试经 [controller] 推送。
class _FakeFetch {
  final controller = StreamController<AudioDownloadEvent>();
  final calls = <(List<String>, Uint8List, Uint8List, int)>[];
  var cancelled = false;

  _FakeFetch() {
    controller.onCancel = () => cancelled = true;
  }

  Stream<AudioDownloadEvent> call(
    List<String> urls,
    Uint8List key,
    Uint8List iv,
    int maxAttempts,
  ) {
    calls.add((urls, key, iv, maxAttempts));
    return controller.stream;
  }
}

ProgressiveDownload _download(
  _FakeFetch fetch, {
  AudioFileFormat format = AudioFileFormat.oggVorbis160,
  List<String> urls = const ['https://cdn.test/a'],
}) => ProgressiveDownload(
  urls: urls,
  key: _key,
  iv: _iv,
  format: format,
  fetch: fetch.call,
)..start();

void main() {
  test('去掉私有头、读出响度数据；头部到达即可读，任意区间读取正确', () async {
    final plain = _spotifyOgg(20000);
    final fetch = _FakeFetch();
    final download = _download(
      fetch,
      urls: ['https://cdn1.test/a', 'https://cdn2.test/a'],
    );
    expect(fetch.calls.single.$1, ['https://cdn1.test/a', 'https://cdn2.test/a']);
    expect(fetch.calls.single.$2, _key);
    expect(fetch.calls.single.$3, _iv);
    expect(fetch.calls.single.$4, 4);

    final progress = <double>[];
    download.addProgressListener(progress.add);
    fetch.controller.add(_meta(plain.length));
    await _push(fetch.controller, plain, to: 1000);

    await download.ready;
    expect(download.length, plain.length - SpotifyAudioHeader.oggHeaderEnd);
    expect(download.normalization?.trackGainDb, closeTo(-6.0, 1e-6));
    expect(download.contentType, 'audio/ogg');

    // 头部到达后立即开始读，读取会等待后续数据
    final body = Uint8List.sublistView(plain, SpotifyAudioHeader.oggHeaderEnd);
    final all = _collect(download.read(0));
    final middle = _collect(download.read(5000, 12345));
    await _push(fetch.controller, plain, from: 1000);
    fetch.controller.add(_done(plain.length));

    expect(await all, body);
    expect(await middle, Uint8List.sublistView(body, 5000, 12345));
    await download.done;
    expect(download.isComplete, isTrue);
    expect(download.playableBytes, body);
    expect(download.normalizationBytes, isNotNull);
    expect(progress.last, 1.0);
    expect(progress, orderedEquals([...progress]..sort()));
    expect(fetch.cancelled, isTrue, reason: '完成后释放事件流');
  });

  test('续传（206 从断点继续）与服务器忽略 Range（200 从头覆盖写）都能拼出完整文件', () async {
    final plain = _spotifyOgg(30000);
    final fetch = _FakeFetch();
    final download = _download(fetch);
    final read = _collect(download.read(0));

    fetch.controller.add(_meta(plain.length));
    await _push(fetch.controller, plain, to: 12000);
    // 第二次请求：Range 续传
    fetch.controller.add(_meta(plain.length, status: 206, start: 12000));
    await _push(fetch.controller, plain, from: 12000, to: 20000);
    // 第三次请求：服务器忽略 Range，从头重新推送
    fetch.controller.add(_meta(plain.length));
    await _push(fetch.controller, plain);
    fetch.controller.add(_done(plain.length));

    await download.done;
    expect(await read, Uint8List.sublistView(plain, SpotifyAudioHeader.oggHeaderEnd));
    expect(download.progress, 1.0);
  });

  test('总长未知：重试时丢弃已收集的数据，下载完成后才可播放', () async {
    final plain = _spotifyOgg(5000);
    final fetch = _FakeFetch();
    final download = _download(fetch);
    var ready = false;
    unawaited(download.ready.then((_) => ready = true));

    fetch.controller.add(_meta(0));
    await _push(fetch.controller, plain, to: 2000);
    fetch.controller.add(_meta(0)); // 重试从头开始
    await _push(fetch.controller, plain);
    expect(ready, isFalse);
    fetch.controller.add(_done(plain.length));

    await download.done;
    expect(ready, isTrue);
    expect(download.length, plain.length - SpotifyAudioHeader.oggHeaderEnd);
    expect(download.playableBytes, Uint8List.sublistView(plain, SpotifyAudioHeader.oggHeaderEnd));
  });

  test('Rust 报告失败：ready / done 抛出去掉前缀的原因', () async {
    final fetch = _FakeFetch();
    final download = _download(fetch);
    fetch.controller.add(_error('request:所有 CDN 地址下载失败：CDN 返回 HTTP 403'));
    await expectLater(
      download.ready,
      throwsA(isA<StateError>().having((e) => e.message, 'message', '所有 CDN 地址下载失败：CDN 返回 HTTP 403')),
    );
    await expectLater(download.done, throwsStateError);
    expect(download.isComplete, isFalse);
  });

  test('事件来源本身出错（如网关配置无效）同样以 StateError 结束', () async {
    final fetch = _FakeFetch();
    final download = _download(fetch);
    fetch.controller.addError(Exception('boom'));
    await expectLater(download.done, throwsStateError);
  });

  test('事件流没有完成事件就结束：视为中断', () async {
    final plain = _spotifyOgg(3000);
    final fetch = _FakeFetch();
    final download = _download(fetch);
    final read = expectLater(
      _collect(download.read(0)),
      throwsStateError,
      reason: '等待中的读取随之失败',
    );
    fetch.controller.add(_meta(plain.length));
    await _push(fetch.controller, plain, to: 1500);
    await fetch.controller.close();
    await expectLater(download.done, throwsStateError);
    await read;
  });

  test('数据超出声明长度：失败并停止下载', () async {
    final fetch = _FakeFetch();
    final download = _download(fetch, format: AudioFileFormat.mp3_160);
    fetch.controller.add(_meta(100));
    fetch.controller.add(_event(1, bytes: 50, data: Uint8List(100)));
    await expectLater(download.done, throwsStateError);
    expect(fetch.cancelled, isTrue);
  });

  test('取消：立即以 DownloadCancelledException 结束并取消 Rust 事件流', () async {
    final plain = _spotifyOgg(10000);
    final fetch = _FakeFetch();
    final download = _download(fetch);
    fetch.controller.add(_meta(plain.length));
    await _push(fetch.controller, plain, to: 2000);
    await download.ready;
    download.cancel();
    expect(download.isCancelled, isTrue);
    await expectLater(download.done, throwsA(isA<DownloadCancelledException>()));
    expect(fetch.cancelled, isTrue);
  });

  test('没有使用者超过宽限期后自动取消', () {
    fakeAsync((async) {
      final fetch = _FakeFetch();
      final download = _download(fetch);
      download.done.ignore();
      final release = download.retain();
      release();
      async.elapse(ProgressiveDownload.cancelGrace - const Duration(milliseconds: 1));
      expect(download.isCancelled, isFalse);
      async.elapse(const Duration(milliseconds: 2));
      expect(download.isCancelled, isTrue);
      expect(fetch.cancelled, isTrue);
    });
  });

  test('MP3 不跳过任何字节', () async {
    final plain = Uint8List.fromList(List.generate(4000, (i) => i & 0xff));
    final fetch = _FakeFetch();
    final download = _download(fetch, format: AudioFileFormat.mp3_160);
    fetch.controller.add(_meta(plain.length));
    await _push(fetch.controller, plain);
    fetch.controller.add(_done(plain.length));
    await download.done;
    expect(download.length, plain.length);
    expect(download.normalization, isNull);
    expect(await _collect(download.read(0)), plain);
  });

  test('没有 CDN 地址：直接失败，不调用 Rust', () async {
    final fetch = _FakeFetch();
    final download = _download(fetch, urls: const []);
    await expectLater(download.ready, throwsStateError);
    expect(fetch.calls, isEmpty);
  });
}
