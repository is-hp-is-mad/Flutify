import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutify_app/services/updates/update_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late File destination;
  final bytes = List.generate(4097, (i) => i % 251);
  final digest = sha256.convert(bytes).toString();

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('flutify-download-test-');
    destination = File(p.join(temporary.path, 'update.zip'));
  });
  tearDown(() async {
    expect(
      p.isWithin(Directory.systemTemp.absolute.path, temporary.absolute.path),
      isTrue,
    );
    await temporary.delete(recursive: true);
  });

  Future<void> download(UpdateDownloader downloader, {String? checksum}) =>
      downloader.download(
        url: Uri.parse('https://example.test/update.zip'),
        size: bytes.length,
        sha256Hex: checksum ?? digest,
        destination: destination,
        onProgress: (_, _) {},
      );

  test('four concurrent ranges reassemble the exact package', () async {
    final allStarted = Completer<void>();
    final ranges = <String>[];
    final downloader = UpdateDownloader(
      rangeThreshold: 1,
      clientFactory: () => MockClient((request) async {
        final range = request.headers['Range']!;
        ranges.add(range);
        if (ranges.length == 4) allStarted.complete();
        await allStarted.future.timeout(const Duration(seconds: 3));
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        return http.Response.bytes(
          bytes.sublist(start, end + 1),
          206,
          headers: {'content-range': 'bytes $start-$end/${bytes.length}'},
        );
      }),
    );
    await download(downloader);
    expect(ranges, hasLength(4));
    expect(await destination.readAsBytes(), bytes);
    expect(await temporary.list().length, 1);
  });

  test('ignored ranges fall back to one complete download', () async {
    var fullDownloads = 0;
    var ranges = 0;
    final downloader = UpdateDownloader(
      rangeThreshold: 1,
      clientFactory: () => MockClient((request) async {
        if (request.headers.containsKey('Range')) {
          ranges++;
        } else {
          fullDownloads++;
        }
        return http.Response.bytes(bytes, 200);
      }),
    );
    await download(downloader);
    expect(ranges, 4);
    expect(fullDownloads, 1);
    expect(await destination.readAsBytes(), bytes);
    expect(await temporary.list().length, 1);
  });

  test(
    'checksum failure leaves no installable file or partial pieces',
    () async {
      final downloader = UpdateDownloader(
        clientFactory: () =>
            MockClient((_) async => http.Response.bytes(bytes, 200)),
      );
      await expectLater(
        download(downloader, checksum: '0' * 64),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
      expect(await temporary.list().isEmpty, isTrue);
    },
  );

  test('resumes a truncated range chunk from the received offset', () async {
    final requestedRanges = <String>[];
    var truncatedOnce = false;
    final downloader = UpdateDownloader(
      rangeThreshold: 1,
      parallelism: 2,
      clientFactory: () => MockClient.streaming((request, _) async {
        final range = request.headers['Range']!;
        requestedRanges.add(range);
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        final chunk = bytes.sublist(start, end + 1);
        if (start == 0 && !truncatedOnce) {
          truncatedOnce = true;
          final half = chunk.length ~/ 2;
          return http.StreamedResponse(
            Stream.value(chunk.sublist(0, half)),
            206,
            contentLength: chunk.length,
            headers: {'content-range': 'bytes $start-$end/${bytes.length}'},
          );
        }
        return http.StreamedResponse(
          Stream.value(chunk),
          206,
          contentLength: chunk.length,
          headers: {'content-range': 'bytes $start-$end/${bytes.length}'},
        );
      }),
    );

    await download(downloader);
    expect(await destination.readAsBytes(), bytes);
    // First chunk truncated at half; retry must resume from half, not 0.
    expect(requestedRanges.where((r) => r.startsWith('bytes=0-')).length, 1);
    expect(requestedRanges.any((r) => r.startsWith('bytes=${(bytes.length ~/ 2) ~/ 2}-')), isTrue);
  });

  test('falls back to single-stream download when parallel range fails', () async {
    var singleStreamRequests = 0;
    final downloader = UpdateDownloader(
      rangeThreshold: 1,
      clientFactory: () => MockClient((request) async {
        if (request.headers.containsKey('Range')) {
          return http.Response('Service Unavailable', 503);
        }
        singleStreamRequests++;
        return http.Response.bytes(bytes, 200);
      }),
    );

    await download(downloader);
    expect(singleStreamRequests, 1);
    expect(await destination.readAsBytes(), bytes);
  });
}
