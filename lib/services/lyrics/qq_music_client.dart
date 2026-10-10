import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../network/retry_after_cooldown.dart';

class QqMusicSong {
  final int id;
  final String title;
  final String artists;
  final int durationMs;
  final int songType;

  const QqMusicSong({
    required this.id,
    required this.title,
    required this.artists,
    this.durationMs = 0,
    this.songType = 0,
  });

  static QqMusicSong? fromJson(Object? value, {bool detail = false}) {
    if (value is! Map) return null;
    final rawId = value['id'] ?? value['songid'];
    final id = rawId is int ? rawId : int.tryParse('$rawId');
    final title = value['title'] ?? value['name'];
    final singer = value['singer'];
    final artists = singer is String
        ? singer
        : singer is List
        ? [
            for (final s in singer)
              if (s is Map && s['name'] is String) s['name'],
          ].join(', ')
        : '';
    final interval = value['interval'];
    final type = value['type'];
    if (id == null ||
        id <= 0 ||
        title is! String ||
        title.trim().isEmpty ||
        artists.trim().isEmpty) {
      return null;
    }
    if (detail &&
        (interval is! int || interval <= 0 || type is! int || type < 0)) {
      return null;
    }
    return QqMusicSong(
      id: id,
      title: title,
      artists: artists,
      durationMs: interval is int ? interval * 1000 : 0,
      songType: type is int ? type : 0,
    );
  }
}

class QqMusicLyrics {
  final String lrc;
  final String tlyric;

  const QqMusicLyrics({this.lrc = '', this.tlyric = ''});

  String encode() => jsonEncode({'lrc': lrc, 'tlyric': tlyric});

  static QqMusicLyrics? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['lrc'] is! String || json['tlyric'] is! String) {
        return null;
      }
      return QqMusicLyrics(lrc: json['lrc'], tlyric: json['tlyric']);
    } catch (_) {
      return null;
    }
  }
}

/// A confirmed miss differs from an unavailable/malformed response: only the
/// former may be cached. Requests never use Spotify or QQ account credentials.
class QqMusicResult<T> {
  final T? value;
  final bool networkError;

  const QqMusicResult(this.value, {this.networkError = false});
}

class QqMusicClient {
  static const timeout = Duration(seconds: 3);
  static const maxResponseBytes = 512 * 1024;
  final http.Client _client;
  final Duration requestTimeout;
  final DateTime Function() _now;
  final RetryAfterCooldown _rateLimit;
  DateTime? _blockedUntil;

  QqMusicClient(
    this._client, {
    this.requestTimeout = timeout,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _rateLimit = RetryAfterCooldown(now: now);

  Future<QqMusicResult<List<QqMusicSong>>> search(String keyword) async {
    final data = await _request(
      'GET',
      Uri.https('c.y.qq.com', '/splcloud/fcgi-bin/smartbox_new.fcg', {
        'key': keyword,
        'format': 'json',
      }),
    );
    final result = data?['data'];
    final category = result is Map ? result['song'] : null;
    final songs = category is Map ? category['itemlist'] : null;
    if (songs is! List) return const QqMusicResult(null, networkError: true);
    final parsed = [
      for (final song in songs.take(10)) ?QqMusicSong.fromJson(song),
    ];
    if (songs.isNotEmpty && parsed.isEmpty) {
      return const QqMusicResult(null, networkError: true);
    }
    return QqMusicResult(parsed);
  }

  Future<QqMusicResult<QqMusicSong>> detail(int songId) async {
    final data = await _rpc('music.pf_song_detail_svr', 'get_song_detail_yqq', {
      'song_id': songId,
    });
    final song = QqMusicSong.fromJson(data?['track_info'], detail: true);
    if (song == null || song.id != songId) {
      return const QqMusicResult(null, networkError: true);
    }
    return QqMusicResult(song);
  }

  Future<QqMusicResult<QqMusicLyrics>> lyric(
    int songId, {
    int songType = 0,
  }) async {
    final data = await _rpc(
      'music.musichallSong.PlayLyricInfo',
      'GetPlayLyricInfo',
      {
        // crypt=0 returns Base64 LRC, avoiding the encrypted QRC format entirely.
        'songId': songId, 'type': songType, 'crypt': 0,
        'qrc': 0, 'qrc_t': 0, 'lrc_t': 0, 'trans': 1, 'trans_t': 0,
        'roma': 0, 'roma_t': 0,
      },
    );
    try {
      String decode(Object? value) {
        if (value is! String) {
          throw const FormatException('Missing lyric field');
        }
        return utf8.decode(base64Decode(value));
      }

      return QqMusicResult(
        QqMusicLyrics(
          lrc: decode(data?['lyric']),
          tlyric: decode(data?['trans']),
        ),
      );
    } catch (_) {
      return const QqMusicResult(null, networkError: true);
    }
  }

  Future<Map?> _rpc(
    String module,
    String method,
    Map<String, Object> param,
  ) async {
    final json = await _request(
      'POST',
      Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
      body: {
        'comm': {'ct': 24, 'cv': 0, 'format': 'json', 'uin': 0},
        'request': {'module': module, 'method': method, 'param': param},
      },
    );
    final response = json?['request'];
    if (response is Map && response['code'] is num && response['code'] != 0) {
      _blockedUntil = _now().add(const Duration(minutes: 1));
    }
    if (response is! Map || response['code'] != 0 || response['data'] is! Map) {
      return null;
    }
    return response['data'] as Map;
  }

  /// Bound both response size and total request time; abort timed-out/oversized
  /// requests and reject redirects. No immediate retries before the next source.
  Future<Map?> _request(
    String method,
    Uri url, {
    Map<String, Object>? body,
  }) async {
    if (_rateLimit.active ||
        (_blockedUntil != null && _now().isBefore(_blockedUntil!))) {
      return null;
    }
    final abort = Completer<void>();
    try {
      return await (() async {
        final request =
            http.AbortableRequest(method, url, abortTrigger: abort.future)
              ..followRedirects = false
              ..headers.addAll({
                'User-Agent': 'Mozilla/5.0 Flutify (lyrics translation)',
                'Referer': 'https://y.qq.com/',
                'Accept': 'application/json',
              });
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode(body);
        }
        final response = await _client.send(request);
        if (_rateLimit.observe(
          // QQ sometimes sends `text/plain; charset=utf-8;` (trailing ;).
          // Response(String) parses that invalid media type; bytes do not.
          http.Response.bytes(
            const [],
            response.statusCode,
            headers: response.headers,
          ),
        )) {
          return null;
        }
        if (response.statusCode == 403) {
          _blockedUntil = _now().add(const Duration(minutes: 1));
        }
        if (response.statusCode != 200) return null;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) return null;
          bytes.addAll(chunk);
        }
        final json = jsonDecode(utf8.decode(bytes));
        if (json is Map && json['code'] is num && json['code'] != 0) {
          _blockedUntil = _now().add(const Duration(minutes: 1));
        }
        if (json is! Map || json['code'] != 0) return null;
        return json;
      })().timeout(requestTimeout);
    } catch (_) {
      return null;
    } finally {
      abort.complete();
    }
  }
}
