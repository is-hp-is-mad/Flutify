import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../auth/auth_constants.dart';
import '../network/retry_after_cooldown.dart';
import '../rust_backend_bridge.dart';

/// 网易云音乐「搜索结果」里的一首曲目（只取歌词匹配需要的字段）。
class NeteaseSong {
  final int id;
  final String name;

  /// 多位艺人以 ", " 连接（与 [LyricsQuery.artist] 一致）。
  final String artists;
  final String album;
  final int durationMs;

  const NeteaseSong({
    required this.id,
    required this.name,
    this.artists = '',
    this.album = '',
    this.durationMs = 0,
  });

  static NeteaseSong? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! int || name is! String || name.isEmpty) return null;
    final artists = json['artists'] is List
        ? json['artists'] as List
        : const [];
    final album = json['album'];
    final duration = json['duration'];
    return NeteaseSong(
      id: id,
      name: name,
      artists: [
        for (final a in artists)
          if (a is Map && a['name'] is String) a['name'] as String,
      ].join(', '),
      album: album is Map && album['name'] is String
          ? album['name'] as String
          : '',
      durationMs: duration is int ? duration : 0,
    );
  }
}

/// 一首歌的原文与译文歌词（LRC 文本；没有对应字段时为空串）。
class NeteaseLyricBundle {
  final String lrc;
  final String tlyric;

  const NeteaseLyricBundle({this.lrc = '', this.tlyric = ''});

  /// 序列化成缓存用的单行 JSON。
  String encode() => jsonEncode({'lrc': lrc, 'tlyric': tlyric});

  static NeteaseLyricBundle? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      return NeteaseLyricBundle(
        lrc: json['lrc'] is String ? json['lrc'] as String : '',
        tlyric: json['tlyric'] is String ? json['tlyric'] as String : '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 一次网易云请求的结果。[networkError] 表示断网 / 超时 / 风控 / 服务端错误，
/// 这种情况调用方不应把「没有译文」当作定论缓存下来。
class NeteaseResponse<T> {
  final T? value;
  final bool networkError;

  const NeteaseResponse(this.value, {this.networkError = false});
}

/// 网易云音乐网页端公开接口（https://music.163.com），无需登录。
///
/// - `POST /api/search/get`：按关键词搜曲目（`type=1` 单曲）；
/// - `GET /api/song/lyric`：`lrc` 原文 LRC、`tlyric` 社区翻译 LRC（带时间轴，很多外语歌有中译）。
///
/// 「没有」与「请求失败」分开：404 / 空结果记为没有；断网 / 超时 / 普通 5xx 最多再试两次，
/// 仍失败记为 [NeteaseResponse.networkError]。
/// 429 / 带 Retry-After 的 503 遵循服务端冷却时间，不立即重试。
///
/// 风控（业务码非 200，如 `-460` / `-462`；或 HTTP 403）也记为网络错误，但不重试：网易云按出口 IP
/// 判定，马上重试照样被拒。随后 [cooldown] 内不再发请求，直接返回网络错误。
/// 请求不伪造来源 IP：NetworkProxy 让 music.163.com 始终直连，不走用户为 Spotify 开的海外代理。
class NeteaseClient {
  static const String _base = 'https://music.163.com';
  static const Duration timeout = Duration(seconds: 10);

  /// 被风控后暂停请求的时长（只记在内存里，重启即恢复）。
  static const Duration cooldown = Duration(minutes: 10);

  static Map<String, String> get _headers => {
    'User-Agent': SpotifyAuthConstants.webUserAgent,
    'Referer': 'https://music.163.com',
  };

  final http.Client _client;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;
  final RetryAfterCooldown _rateLimit;
  final bool useRustBackend;

  /// 风控冷却的截止时间；null 表示没有被风控过。
  DateTime? _cooldownUntil;

  NeteaseClient(
    this._client, {
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    this.useRustBackend = false,
  }) : _sleep = sleep ?? Future.delayed,
       _now = now ?? DateTime.now,
       _rateLimit = RetryAfterCooldown(now: now);

  Future<http.Response> _sendRequest({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    List<int>? bodyBytes,
  }) async {
    if (useRustBackend && RustCore.ready) {
      final proxy = await RustBackendBridge.proxyForUrl(url.toString());
      if (proxy != null) {
        final raw = await rust.rustLyricsHttpRequest(
          method: method,
          url: url.toString(),
          headers: [for (final e in headers.entries) (e.key, e.value)],
          body: bodyBytes == null ? null : Uint8List.fromList(bodyBytes),
          proxy: proxy,
        );
        return http.Response.bytes(raw.body, raw.status);
      }
    }
    if (method == 'POST') {
      return _client
          .post(url, headers: headers, body: bodyBytes)
          .timeout(timeout);
    }
    return _client.get(url, headers: headers).timeout(timeout);
  }

  /// 搜曲目；没有命中返回空列表。
  Future<NeteaseResponse<List<NeteaseSong>>> search(
    String keyword, {
    int limit = 6,
  }) async {
    return _retry(() async {
      final form = Uri(
        queryParameters: {'s': keyword, 'type': '1', 'limit': '$limit'},
      ).query;
      final res = await _sendRequest(
        method: 'POST',
        url: Uri.parse('$_base/api/search/get'),
        headers: {
          ..._headers,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        bodyBytes: utf8.encode(form),
      );
      if (res.statusCode != 200) return _http(res);
      try {
        final json = jsonDecode(utf8.decode(res.bodyBytes));
        if (_rejected(json)) return _blocked();
        final songs = json is Map && json['result'] is Map
            ? (json['result'] as Map)['songs']
            : null;
        if (songs is! List) return NeteaseResponse(const <NeteaseSong>[]);
        return NeteaseResponse([
          for (final s in songs) ?NeteaseSong.fromJson(s),
        ]);
      } on FormatException {
        return NeteaseResponse(const <NeteaseSong>[]);
      }
    });
  }

  /// 取一首歌的原文 / 译文歌词；查不到返回空 bundle。
  Future<NeteaseResponse<NeteaseLyricBundle>> lyric(int songId) async {
    return _retry(() async {
      final res = await _sendRequest(
        method: 'GET',
        url: Uri.parse('$_base/api/song/lyric?id=$songId&lv=1&tv=1'),
        headers: _headers,
      );
      if (res.statusCode != 200) return _http(res);
      try {
        final json = jsonDecode(utf8.decode(res.bodyBytes));
        if (json is! Map) return const NeteaseResponse(NeteaseLyricBundle());
        if (_rejected(json)) return _blocked();
        String text(String key) {
          final obj = json[key];
          return obj is Map && obj['lyric'] is String
              ? obj['lyric'] as String
              : '';
        }

        return NeteaseResponse(
          NeteaseLyricBundle(lrc: text('lrc'), tlyric: text('tlyric')),
        );
      } on FormatException {
        return const NeteaseResponse(NeteaseLyricBundle());
      }
    });
  }

  /// 业务码不是 200：网易云风控（`-460` / `-462` 等）与服务端繁忙时 HTTP 状态仍是 200，
  /// 只在 JSON 的 `code` 里报错。按风控处理（[_blocked]），不能当「没有歌词 / 没搜到」。
  static bool _rejected(Object? json) =>
      json is Map && json['code'] is num && json['code'] != 200;

  NeteaseResponse<T> _http<T>(http.Response response) {
    if (_rateLimit.observe(response)) return const NeteaseResponse(null, networkError: true);
    final code = response.statusCode;
    if (code == 403) return _blocked();
    if (code >= 500 || code == 0)
      return const NeteaseResponse(null, networkError: true);
    // 404 = 没有这条；其余 4xx 不当成可重试的故障，按「没有」处理
    return NeteaseResponse(null);
  }

  /// 被风控：开始冷却，结果记为网络错误（调用方不会把「没有译文」当定论缓存，冷却过后再查）。
  NeteaseResponse<T> _blocked<T>() {
    _cooldownUntil = _now().add(cooldown);
    return const NeteaseResponse(null, networkError: true);
  }

  bool get _coolingDown {
    final until = _cooldownUntil;
    return _rateLimit.active || (until != null && _now().isBefore(until));
  }

  Future<NeteaseResponse<T>> _retry<T>(
    Future<NeteaseResponse<T>> Function() request,
  ) async {
    for (var attempt = 0; ; attempt++) {
      // 冷却中不发请求（含等待重试期间另一个请求被风控的情况）
      if (_coolingDown) return const NeteaseResponse(null, networkError: true);
      NeteaseResponse<T> res;
      try {
        res = await request();
      } catch (_) {
        res = const NeteaseResponse(null, networkError: true);
      }
      // 刚被风控（已进入冷却）也不重试：马上再请求照样被拒
      if (!res.networkError || attempt >= 2 || _coolingDown) return res;
      await _sleep(Duration(milliseconds: 600 * (attempt + 1)));
    }
  }
}
