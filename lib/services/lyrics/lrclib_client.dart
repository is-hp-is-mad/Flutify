import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../network/retry_after_cooldown.dart';
import '../rust_backend_bridge.dart';
import 'lrclib_candidate.dart';

/// 一次 LRCLIB 请求的结果。[networkError] 表示因断网 / 超时 / 限流 / 服务端错误没拿到结果，
/// 这种情况调用方不应把「没有歌词」当作定论缓存下来。
class LrclibResponse {
  final List<LrclibCandidate> candidates;
  final bool networkError;

  const LrclibResponse(this.candidates, {this.networkError = false});
}

/// LRCLIB（https://lrclib.net）公开歌词库，无需鉴权。
///
/// - `GET /api/get`：曲名 + 歌手 + 专辑 + 时长精确匹配，对不上返回 404（正常情况）；
/// - `GET /api/search`：按曲名 / 歌手或全文 `q` 搜索，返回数组。
///
/// 404 = 没有这条；429 / 带 Retry-After 的 503 进入共享冷却；
/// 其余 5xx / 断网 / 超时最多再试两次，失败不缓存为「没有歌词」。
class LrclibClient {
  static const String baseUrl = 'https://lrclib.net/api';
  static const Duration timeout = Duration(seconds: 12);

  final http.Client _client;
  final RetryAfterCooldown _cooldown;

  /// 重试前的等待；测试注入零延迟。
  final Future<void> Function(Duration) _sleep;
  final bool useRustBackend;

  LrclibClient(
    this._client, {
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    this.useRustBackend = false,
  }) : _sleep = sleep ?? Future.delayed,
       _cooldown = RetryAfterCooldown(now: now);

  Future<LrclibResponse> get({required String track, required String artist, String album = '', int durationSec = 0}) async {
    if (useRustBackend && RustCore.ready) {
      final proxy = await RustBackendBridge.proxyForUrl('$baseUrl/get');
      if (proxy != null) {
        rust.rustSessionSetProxy(proxy: proxy);
        final dto = await rust.rustLrclibGet(
          track: track,
          artist: artist,
          album: album,
          durationSec: durationSec,
        );
        return RustBackendBridge.lrclibResponseFromDto(dto);
      }
    }
    return _request('/get', {
      'track_name': track,
      'artist_name': artist,
      if (album.isNotEmpty) 'album_name': album,
      if (durationSec > 0) 'duration': '$durationSec',
    });
  }

  Future<LrclibResponse> search({String? track, String? artist, String? q}) async {
    if (useRustBackend && RustCore.ready) {
      final proxy = await RustBackendBridge.proxyForUrl('$baseUrl/search');
      if (proxy != null) {
        rust.rustSessionSetProxy(proxy: proxy);
        final dto = await rust.rustLrclibSearch(
          track: track ?? '',
          artist: artist ?? '',
          q: q ?? '',
        );
        return RustBackendBridge.lrclibResponseFromDto(dto);
      }
    }
    return _request('/search', {
      'track_name': ?track,
      if (artist != null && artist.isNotEmpty) 'artist_name': artist,
      'q': ?q,
    });
  }

  Future<LrclibResponse> _request(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    for (var attempt = 0; ; attempt++) {
      if (_cooldown.active) return const LrclibResponse([], networkError: true);
      int code;
      try {
        final res = await _client
            .get(uri, headers: const {'User-Agent': 'Flutify (lyrics fallback)', 'Accept': 'application/json'})
            .timeout(timeout);
        code = res.statusCode;
        if (_cooldown.observe(res)) return const LrclibResponse([], networkError: true);
        if (code == 200) {
          try {
            return LrclibResponse(LrclibCandidate.listFrom(jsonDecode(utf8.decode(res.bodyBytes))));
          } on FormatException {
            return const LrclibResponse([]);
          }
        }
      } catch (_) {
        code = 0; // 断网 / 超时 / TLS 等
      }
      if (code == 404) return const LrclibResponse([]);
      final transient = code == 0 || code >= 500;
      if (!transient) return const LrclibResponse([]);
      if (attempt >= 2) return const LrclibResponse([], networkError: true);
      await _sleep(Duration(milliseconds: 600 * (attempt + 1)));
    }
  }
}
