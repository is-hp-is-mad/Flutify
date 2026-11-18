import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/file_digest.dart';

class UpdateCancelled implements Exception {}

class _RangeUnsupported implements Exception {}

/// Four concurrent range requests, bounded disk streaming, and a single-stream
/// fallback for proxies/servers that ignore Range. Partial files never install.
class UpdateDownloader {
  final http.Client Function() clientFactory;
  final int parallelism;
  final int rangeThreshold;
  final _clients = <http.Client>{};
  bool _cancelled = false;

  UpdateDownloader({
    http.Client Function()? clientFactory,
    this.parallelism = 4,
    this.rangeThreshold = 1024 * 1024,
  }) : clientFactory = clientFactory ?? http.Client.new;

  void cancel() {
    _cancelled = true;
    for (final client in _clients.toList()) {
      client.close();
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw UpdateCancelled();
  }

  Future<void> download({
    required Uri url,
    required int size,
    required String sha256Hex,
    required File destination,
    required void Function(int received, int total) onProgress,
  }) async {
    if (size <= 0 || size > 4 * 1024 * 1024 * 1024 ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256Hex)) {
      throw const FormatException('Invalid update size or checksum');
    }
    _checkCancelled();
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.partial');
    final pieces = <File>[];
    final received = <int, int>{};
    void progress(int part, int bytes) {
      received[part] = bytes;
      onProgress(received.values.fold(0, (a, b) => a + b), size);
    }

    Future<void> fetch(File file, int part, int start, int end, bool range) async {
      final totalExpected = end - start + 1;
      var written = 0;
      var append = false;
      for (var attempt = 0; attempt < 4; attempt++) {
        _checkCancelled();
        final client = clientFactory();
        _clients.add(client);
        IOSink? sink;
        try {
          final resume = range || written > 0;
          final reqStart = resume ? start + written : start;
          final expected = end - reqStart + 1;
          progress(part, resume ? written : 0);
          final request = http.Request('GET', url)
            ..headers['Accept-Encoding'] = 'identity';
          if (resume) request.headers['Range'] = 'bytes=$reqStart-$end';
          final response = await client.send(request).timeout(const Duration(seconds: 30));
          if (range && (response.statusCode == 200 || response.statusCode == 416)) {
            throw _RangeUnsupported();
          }
          // If a single-stream retry tried Range resume and got 200, restart from 0.
          if (!range && resume && response.statusCode == 200) {
            written = 0;
            append = false;
            progress(part, 0);
            if (response.contentLength != null && response.contentLength != totalExpected) {
              throw const FormatException('Unexpected download length');
            }
            sink = file.openWrite();
            var count = 0;
            await sink.addStream(response.stream.timeout(const Duration(seconds: 45)).map((bytes) {
              _checkCancelled();
              count += bytes.length;
              if (count > totalExpected) throw const FormatException('Oversized update');
              written = count;
              progress(part, written);
              return bytes;
            }));
            if (count != totalExpected) throw const FormatException('Truncated update');
            await sink.flush();
            return;
          }
          if (response.statusCode != (resume ? 206 : 200)) {
            throw HttpException('Download HTTP ${response.statusCode}');
          }
          if (resume && response.headers['content-range'] != 'bytes $reqStart-$end/$size') {
            throw const FormatException('Invalid Content-Range');
          }
          if (response.contentLength != null && response.contentLength != expected) {
            throw const FormatException('Unexpected download length');
          }
          sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
          var count = 0;
          // addStream applies backpressure instead of accumulating a whole APK.
          await sink.addStream(response.stream.timeout(const Duration(seconds: 45)).map((bytes) {
            _checkCancelled();
            count += bytes.length;
            if (count > expected) throw const FormatException('Oversized update');
            written += bytes.length;
            append = true;
            progress(part, written);
            return bytes;
          }));
          if (count != expected) throw const FormatException('Truncated update');
          await sink.flush();
          return;
        } on _RangeUnsupported {
          rethrow;
        } catch (e) {
          _checkCancelled();
          debugPrint(
            '[Updates] Download part=$part attempt=${attempt + 1}/4 failed: $e',
          );
          if (attempt == 3) rethrow;
        } finally {
          await sink?.close();
          _clients.remove(client);
          client.close();
        }
      }
    }

    try {
      final count = size >= rangeThreshold ? min(parallelism.clamp(1, 8), size) : 1;
      if (count > 1) {
        var unsupported = false;
        Object? parallelError;
        // Wait for all workers before fallback or cleanup, even after failure.
        await Future.wait([
          for (var i = 0; i < count; i++)
            () async {
              final file = File('${destination.path}.part$i');
              pieces.add(file);
              try {
                await fetch(file, i, size * i ~/ count, size * (i + 1) ~/ count - 1, true);
              } on _RangeUnsupported {
                unsupported = true;
              } catch (e) {
                parallelError ??= e;
              }
            }(),
        ]);
        _checkCancelled();
        if (unsupported || parallelError != null) {
          if (parallelError != null) {
            debugPrint(
              '[Updates] Parallel download failed ($parallelError), falling back to single-stream',
            );
          }
          received.clear();
          await fetch(partial, 0, 0, size - 1, false);
        } else {
          final output = partial.openWrite();
          try {
            // pieces are registered synchronously in request order.
            for (final piece in pieces) {
              _checkCancelled();
              await output.addStream(piece.openRead());
            }
            await output.flush();
          } finally {
            await output.close();
          }
        }
      } else {
        await fetch(partial, 0, 0, size - 1, false);
      }
      _checkCancelled();
      final actual = await sha256OfFile(partial);
      if (actual != sha256Hex.toLowerCase()) {
        throw const FormatException('Update SHA-256 mismatch');
      }
      _checkCancelled();
      await partial.rename(destination.path);
    } finally {
      for (final file in [partial, ...pieces]) {
        if (await file.exists()) await file.delete();
      }
    }
  }
}
