import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../auth/web_token_exception.dart';
import 'license_client.dart';
import 'streaming_download.dart';

/// EME 本地回环媒体与 DRM 反代服务器：
/// - 托管 `/eme` 页面、`/hls.js`、`/audio.m3u8` 与支持 Range/流式等待的 `/audio/current.m4a`；
/// - 反代 `/license`、`/cert` 与受白名单限制的 `/provision`；
/// - 通过 `Host` 与 `Origin` 校验拦截 DNS rebinding 与跨站跳板请求。
class EmeLoopbackServer {
  static const Set<String> allowedProvisionHosts = {
    'www.googleapis.com',
    'www.googleapis.cn',
    'android.clients.google.com',
  };

  final http.Client _httpClient;
  final bool Function() _isDisposed;
  final int Function() _playGen;
  final String Function() _emePageHtml;
  final String? Function() _hlsJsSource;
  final String? Function() _localM3u8;
  final File? Function() _audioFile;
  final Future<Uint8List> Function(Uint8List request)? Function() _licensePoster;
  final Future<Uint8List> Function()? Function() _certFetcher;
  final bool Function() _fairPlayMode;
  final void Function(String name, Object error, bool webSignInSuggested)
  _onRelayError;

  HttpServer? _server;
  Future<void>? _starting;

  EmeLoopbackServer({
    required http.Client httpClient,
    required bool Function() isDisposed,
    required int Function() playGen,
    required String Function() emePageHtml,
    required String? Function() hlsJsSource,
    required String? Function() localM3u8,
    required File? Function() audioFile,
    required Future<Uint8List> Function(Uint8List request)? Function()
    licensePoster,
    required Future<Uint8List> Function()? Function() certFetcher,
    required bool Function() fairPlayMode,
    required void Function(String name, Object error, bool webSignInSuggested)
    onRelayError,
  }) : _httpClient = httpClient,
       _isDisposed = isDisposed,
       _playGen = playGen,
       _emePageHtml = emePageHtml,
       _hlsJsSource = hlsJsSource,
       _localM3u8 = localM3u8,
       _audioFile = audioFile,
       _licensePoster = licensePoster,
       _certFetcher = certFetcher,
       _fairPlayMode = fairPlayMode,
       _onRelayError = onRelayError;

  int? get port => _server?.port;
  String get origin => 'http://127.0.0.1:${_server!.port}';

  Future<void> ensureStarted() => _starting ??= _start().catchError((
    Object error,
    StackTrace stack,
  ) {
    _starting = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> close() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Future<void> _start() async {
    if (_isDisposed()) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_isDisposed()) {
      await server.close(force: true);
      return;
    }
    _server = server;
    server.listen((request) async {
      if (!isOwnRequest(request.headers, server.port)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final path = request.uri.path;
      try {
        if (path == '/eme') {
          request.response.headers.contentType = ContentType.html;
          request.response.write(_emePageHtml());
          await request.response.close();
        } else if (path == '/hls.js') {
          request.response.headers.contentType = ContentType(
            'application',
            'javascript',
          );
          request.response.write(_hlsJsSource() ?? '');
          await request.response.close();
        } else if (path == '/audio.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(_localM3u8() ?? '#EXTM3U');
          await request.response.close();
        } else if (path == '/audio/current.m4a') {
          await _serveAudio(request);
        } else if (path == '/license' && request.method == 'POST') {
          await _relayLicense(request);
        } else if (path == '/cert') {
          await _relayCert(request);
        } else if (path == '/provision' && request.method == 'POST') {
          await _relayProvision(request);
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      } catch (_) {
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  static bool isOwnRequest(HttpHeaders headers, int port) {
    final host = headers.value(HttpHeaders.hostHeader)?.toLowerCase();
    if (host == null) return false;
    final hostOk =
        host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '127.0.0.1:$port' ||
        host == 'localhost:$port';
    if (!hostOk) return false;
    final origin = headers.value('origin')?.toLowerCase();
    return origin == null ||
        origin == 'http://127.0.0.1:$port' ||
        origin == 'http://localhost:$port';
  }

  static bool isAllowedProvisionTarget(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return false;
    }
    if (uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != 443)) {
      return false;
    }
    return allowedProvisionHosts.contains(uri.host.toLowerCase());
  }

  static Future<Uint8List> consolidatedBody(HttpRequest request) async {
    final builder = BytesBuilder();
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _serveAudio(HttpRequest request) async {
    final file = _audioFile();
    if (file == null) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final response = request.response;
    response.headers.contentType = ContentType('audio', 'mp4');

    final dl = StreamingDownloads.of(file.path);

    int start = 0;
    int? endExclusive;
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (m == null) {
        response.statusCode = 416;
        await response.close();
        return;
      }
      start = int.parse(m.group(1)!);
      endExclusive = m.group(2)!.isEmpty ? null : int.parse(m.group(2)!) + 1;
    }

    if (dl != null && dl.error != null) {
      response.statusCode = 503;
      await response.close();
      return;
    }

    if (dl != null && !dl.done) {
      final need =
          endExclusive ?? (dl.expectedTotal > 0 ? dl.expectedTotal : start + 1);
      try {
        await dl.waitFor(need);
      } catch (e) {
        response.statusCode = 503;
        await response.close();
        return;
      }
      if (dl.error != null) {
        response.statusCode = 503;
        await response.close();
        return;
      }
    }

    final total = (dl != null && !dl.done)
        ? dl.available
        : file.lengthSync();
    final end = (endExclusive ?? total).clamp(0, total);
    final len = end - start;
    if (len <= 0) {
      response.statusCode = 416;
      await response.close();
      return;
    }
    if (rangeHeader != null) {
      response.statusCode = 206;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/$total',
      );
    }
    response.headers.set(HttpHeaders.contentLengthHeader, len);
    await file.openRead(start, end).pipe(response);
  }

  Future<void> _relayLicense(HttpRequest request) async {
    final gen = _playGen();
    final body = await consolidatedBody(request);
    final poster = _licensePoster();
    if (poster == null) {
      await _failRelay(
        request,
        'license',
        StateError('licensePoster 未注入'),
        gen,
      );
      return;
    }
    try {
      final resp = await poster(body);
      debugPrint('[eme] license 中转：请求 ${body.length}B → 响应 ${resp.length}B');
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      request.response.add(resp);
      await request.response.close();
    } catch (e) {
      await _failRelay(request, 'license', e, gen);
    }
  }

  Future<void> _relayCert(HttpRequest request) async {
    final gen = _playGen();
    final fetcher = _certFetcher();
    if (fetcher == null) {
      await _failRelay(request, '证书', StateError('certFetcher 未注入'), gen);
      return;
    }
    try {
      final cert = await fetcher();
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      request.response.add(cert);
      await request.response.close();
    } catch (e) {
      await _failRelay(request, '证书', e, gen);
    }
  }

  Future<void> _relayProvision(HttpRequest request) async {
    final gen = _playGen();
    final target = request.uri.queryParameters['target'];
    if (target == null || !isAllowedProvisionTarget(target)) {
      debugPrint('[eme] provision 中转：拒绝非法 target=$target');
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final body = await consolidatedBody(request);
    try {
      final resp = await _httpClient
          .post(
            Uri.parse(target),
            headers: {'Content-Type': 'application/octet-stream'},
            body: body,
          )
          .timeout(const Duration(seconds: 15));
      var line =
          '[eme] provision 中转：请求 ${body.length}B → HTTP ${resp.statusCode} ${resp.bodyBytes.length}B';
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        line =
            '$line | ${utf8.decode(resp.bodyBytes.take(200).toList(), allowMalformed: true)}';
      }
      debugPrint(line);
      request.response.statusCode = resp.statusCode;
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      request.response.add(resp.bodyBytes);
      await request.response.close();
    } catch (e) {
      await _failRelay(request, 'provision', e, gen);
    }
  }

  Future<void> _failRelay(
    HttpRequest request,
    String name,
    Object error,
    int gen,
  ) async {
    if (gen != _playGen()) {
      debugPrint('[eme] $name 中转失败（上一首残留，忽略）: $error');
    } else {
      debugPrint('[eme] $name 中转失败: $error');
      _onRelayError(
        name,
        error,
        _usesWebToken(name) && _isWebAuthFailure(error),
      );
    }
    try {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType(
        'text',
        'plain',
        charset: 'utf-8',
      );
      request.response.write('$error');
      await request.response.close();
    } catch (_) {}
  }

  bool _usesWebToken(String relay) =>
      relay == 'license' || (relay == '证书' && _fairPlayMode());

  static bool _isWebAuthFailure(Object error) => switch (error) {
    WebSignInRequiredException() => true,
    WebTokenHttpException(:final statusCode) => statusCode == 401,
    LicenseHttpException(:final statusCode) => statusCode == 401,
    _ => false,
  };
}
