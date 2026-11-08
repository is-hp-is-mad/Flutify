import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants/spotify_endpoints.dart';
import '../models/lyrics.dart';

/// 取歌词失败（网络 / 鉴权 / 服务端错误）。无歌词不是失败，见 [LyricsService.fetch]。
class LyricsException implements Exception {
  final String message;
  final int? statusCode;

  const LyricsException(this.message, [this.statusCode]);

  @override
  String toString() =>
      statusCode == null ? message : '$message（HTTP $statusCode）';
}

/// 歌词服务：spclient `GET /color-lyrics/v2/track/{trackId}`（Spotify 官方客户端的同步歌词接口）。
///
/// 请求头沿用会话身份（[headers]：Bearer、client-token，以及与 `client_profile.dart` 一致的
/// User-Agent / app-platform / spotify-app-version，即桌面版会话带桌面端头）。
/// 开发者应用 OAuth 会话没有官方客户端身份，此时按 Web 播放器声明 `app-platform: WebPlayer`。
class LyricsService {
  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;

  LyricsService(this._client, {required this._headers});

  /// 取 [trackId]（base62）的歌词。
  ///
  /// - 200：解析歌词（按行同步或未同步）；
  /// - 404：这首歌没有歌词，返回空歌词（可缓存）；
  /// - 其他状态码 / 网络错误：抛 [LyricsException]（调用方不应缓存）。
  Future<SpotifyLyrics> fetch(String trackId) async {
    if (trackId.isEmpty) return const SpotifyLyrics(lines: []);

    final path = SpotifyEndpoints.spclientColorLyrics.replaceAll(
      '{track_id}',
      trackId,
    );
    final headers = await _headers();
    final http.Response res;
    try {
      res = await _client.get(
        // 官方播放器的 ALL_LANGUAGES 模式：一次取回来源已有的译词。
        Uri.parse(
          '${SpotifyEndpoints.defaultSpClientBase}$path?format=json&vocalRemoval=false&market=from_token&clientLanguage=all',
        ),
        headers: {
          // 没有官方客户端身份（头里没有 app-platform）时按 Web 播放器声明
          if (!headers.containsKey('app-platform')) 'app-platform': 'WebPlayer',
          ...headers,
          'Accept': 'application/json',
        },
      );
    } catch (e) {
      throw LyricsException('获取歌词失败，请检查网络：$e');
    }

    if (res.statusCode == 404) return const SpotifyLyrics(lines: []);
    if (res.statusCode != 200) throw LyricsException('获取歌词失败', res.statusCode);
    return parse(res.bodyBytes);
  }

  /// 解析 color-lyrics 响应（`{lyrics: {syncType, lines[{startTimeMs, words}]}, colors, ...}`）；
  /// 结构异常时返回空歌词，不抛错。
  static SpotifyLyrics parse(List<int> body) {
    try {
      final json = jsonDecode(utf8.decode(body));
      if (json is! Map<String, dynamic>) return const SpotifyLyrics(lines: []);
      final lyrics = SpotifyLyrics.fromJson(json);
      // 同步歌词里的空行表示间奏 / 停顿（用于切换当前行），需要保留；但全是空行等同于没有歌词
      if (lyrics.lines.every((l) => l.words.trim().isEmpty))
        return const SpotifyLyrics(lines: []);
      return lyrics;
    } catch (_) {
      return const SpotifyLyrics(lines: []);
    }
  }
}
