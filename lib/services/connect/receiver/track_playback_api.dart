import 'dart:convert';

import 'package:http/http.dart' as http;
import '../../../models/audio_playback_info.dart';

/// track-playback 设备接口（`{spclient}/track-playback/v1/devices…`）。
///
/// 约定：
/// - 必须用 **Web 播放器身份**：Web token（sp_dc + TOTP）+ Web client-token（`js_sdk_data`），
///   再带上 Web 播放器的 `app-platform` / `spotify-app-version` / Origin / Referer；
///   桌面 token 注册会被拒。
/// - client-token 按 [deviceId] 申请后缓存，并发调用合并为一次请求；服务端给出有效期时到期前重新申请，
///   认证被拒（401）时 [invalidate] 重新申请；403 保留状态交给调用方。
/// - 每次汇报带递增的 `seq_num`，起点为注册响应里的 `initial_seq_num`。
class TrackPlaybackApi {
  static const String webClientId = 'd8a5ed958d274c2e8ee717e6a4b0971d';
  static const String webClientVersion = '1.3.5.31.ga27a71fef885';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';

  final http.Client _client;
  final Future<String> Function() _webToken;
  final String deviceId;
  final String _spclientHost;
  final String? Function()? _spclientHostProvider;
  final DateTime Function() _now;

  String get spclientHost => _spclientHostProvider?.call() ?? _spclientHost;

  String? _clientToken;
  DateTime? _clientTokenRefreshAt;
  Future<String>? _clientTokenInFlight;
  int _clientTokenGeneration = 0;
  int _seq = 0;

  TrackPlaybackApi({
    required http.Client client,
    required Future<String> Function() webToken,
    required this.deviceId,
    String spclientHost = 'gae2-spclient.spotify.com',
    String? Function()? spclientHostProvider,
    DateTime Function()? now,
  }) : _client = client,
       _webToken = webToken,
       _spclientHost = spclientHost,
       _spclientHostProvider = spclientHostProvider,
       _now = now ?? DateTime.now;

  void invalidate() {
    ++_clientTokenGeneration;
    _clientToken = null;
    _clientTokenRefreshAt = null;
    _clientTokenInFlight = null;
  }

  Future<Map<String, String>> headers() async => {
    'Authorization':
        'Bearer ${await _webToken().timeout(const Duration(seconds: 10))}',
    'client-token': await _ensureClientToken(),
    'User-Agent': userAgent,
    'Origin': 'https://open.spotify.com',
    'Referer': 'https://open.spotify.com/',
    'app-platform': 'WebPlayer',
    'spotify-app-version': webClientVersion,
    'Content-Type': 'application/json',
  };

  Future<String> _ensureClientToken() {
    final cached = _clientToken;
    final refreshAt = _clientTokenRefreshAt;
    if (cached != null && (refreshAt == null || _now().isBefore(refreshAt))) {
      return Future.value(cached);
    }
    final existing = _clientTokenInFlight;
    if (existing != null) return existing;
    late final Future<String> pending;
    pending = _requestClientToken(_clientTokenGeneration).whenComplete(() {
      if (identical(_clientTokenInFlight, pending)) {
        _clientTokenInFlight = null;
      }
    });
    return _clientTokenInFlight = pending;
  }

  Future<String> _requestClientToken(int generation) async {
    final res = await _client
        .post(
          Uri.parse('https://clienttoken.spotify.com/v1/clienttoken'),
          headers: {
            'content-type': 'application/json',
            'accept': 'application/json',
            'User-Agent': userAgent,
          },
          body: jsonEncode({
            'client_data': {
              'client_version': webClientVersion,
              'client_id': webClientId,
              'js_sdk_data': {
                'device_brand': 'unknown',
                'device_model': 'unknown',
                'os': 'windows',
                'os_version': 'NT 10.0',
                'device_id': deviceId,
                'device_type': 'computer',
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (generation != _clientTokenGeneration) return _ensureClientToken();
    if (res.statusCode != 200) {
      throw StateError('Web client-token 申请失败：HTTP ${res.statusCode}');
    }
    final granted =
        (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['granted_token']
            as Map?;
    final token = granted?['token'];
    if (token is! String || token.isEmpty) {
      throw StateError('Web client-token 申请失败：HTTP ${res.statusCode}');
    }
    final deadlines = [
      granted?['refresh_after_seconds'],
      granted?['expires_after_seconds'],
    ].whereType<int>().where((seconds) => seconds >= 0).toList()..sort();
    // 未给 TTL 时短期缓存；短 TTL 也必须过期，且不晚于 expires_after。
    final ttl = deadlines.isEmpty ? 300 : deadlines.first;
    final refreshIn = (ttl - (ttl ~/ 10).clamp(1, 60)).clamp(0, ttl);
    _clientTokenRefreshAt = _now().add(Duration(seconds: refreshIn));
    return _clientToken = token;
  }

  Uri _uri(String path) =>
      Uri.https(spclientHost, '/track-playback/v1/devices$path');

  /// 注册为播放端；[connectionId] 来自同一 Web token 建立的 dealer 连接。
  Future<void> register({
    required String connectionId,
    required String name,
    required int volume,
    bool Function()? isCurrent,
  }) async {
    final res = await _client
        .post(
          _uri(''),
          headers: await headers(),
          body: jsonEncode({
            'device': {
              'brand': 'spotify',
              'capabilities': {
                'change_volume': true,
                'enable_play_token': true,
                'supports_file_media_type': true,
                'play_token_lost_behavior': 'pause',
                'disable_connect': false,
                'audio_podcasts': true,
                'video_playback': false,
                'manifest_formats': [
                  'file_ids_mp3',
                  'file_urls_mp3',
                  'file_urls_external',
                  'file_ids_mp4',
                  'file_ids_mp4_dual',
                ],
              },
              'device_id': deviceId,
              'device_type': 'computer',
              'metadata': {},
              'model': 'web_player',
              'name': name,
              'platform_identifier':
                  'web_player windows 10;chrome 154.0.0.0;desktop',
              'is_group': false,
            },
            'outro_endcontent_snooping': false,
            'connection_id': connectionId,
            'client_version': 'harmony:4.62.0',
            'volume': volume,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (isCurrent != null && !isCurrent()) return;
    _check(res, '注册');
    _seq =
        ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['initial_seq_num']
                as num?)
            ?.toInt() ??
        0;
  }

  /// 汇报当前状态；[stateMachineId] 为空表示「无状态」（已停止 / 改在本机播放别的）。
  ///
  /// 响应里可能带新的状态机（服务端在汇报后扩展了前后曲目），原样返回给调用方。
  Future<Map<String, dynamic>?> putState({
    required String debugSource,
    String? stateMachineId,
    String? stateId,
    bool paused = false,
    int positionMs = 0,
    int durationMs = 0,
    int? previousPositionMs,
    AudioPlaybackInfo audio = const AudioPlaybackInfo(),
  }) async {
    final res = await _client
        .put(
          _uri('/$deviceId/state'),
          headers: await headers(),
          body: jsonEncode({
            'seq_num': ++_seq,
            'state_ref': stateMachineId == null
                ? null
                : {
                    'state_machine_id': stateMachineId,
                    'state_id': stateId,
                    'paused': paused,
                  },
            'sub_state': {
              'playback_speed': paused ? 0 : 1,
              'position': positionMs,
              'duration': durationMs,
              'media_type': 'AUDIO',
              'bitrate': ?audio.bitrate,
              'format': ?audio.format,
            },
            'previous_position': ?previousPositionMs,
            'debug_source': debugSource,
          }),
        )
        .timeout(const Duration(seconds: 10));
    _check(res, '汇报 $debugSource');
    if (res.body.isEmpty) return null;
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    return json is Map<String, dynamic> ? json : null;
  }

  /// 拒绝与本机当前状态对不上的 replace_state（其 `prev_state_ref` 不是本机当前状态）：
  /// 带上本机当前状态与被拒的 [rejected] 状态引用，服务端在响应里给出应执行的命令。
  /// 与官方 Web Player 的 `state_conflict` 一致；返回响应里的 `commands`。
  Future<List<Map<String, dynamic>>> postStateConflict({
    String? stateMachineId,
    String? stateId,
    bool paused = true,
    int positionMs = 0,
    int durationMs = 0,
    required List<Map<String, dynamic>> rejected,
  }) async {
    final res = await _client
        .post(
          _uri('/$deviceId/state_conflict'),
          headers: await headers(),
          body: jsonEncode({
            'seq_nums': [for (var i = 0; i < rejected.length; i++) ++_seq],
            'state_ref': stateMachineId == null
                ? null
                : {
                    'state_machine_id': stateMachineId,
                    'state_id': stateId,
                    'paused': paused,
                  },
            'sub_state': {
              'playback_speed': paused ? 0 : 1,
              'position': positionMs,
              'duration': durationMs,
              'media_type': 'AUDIO',
            },
            'rejected_state_refs': rejected,
            'debug_source': 'state_conflict',
          }),
        )
        .timeout(const Duration(seconds: 10));
    _check(res, '状态冲突');
    if (res.body.isEmpty) return const [];
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    final commands = json is Map ? json['commands'] : null;
    return commands is List
        ? [
            for (final c in commands)
              if (c is Map) c.cast<String, dynamic>(),
          ]
        : const [];
  }

  Future<void> putVolume(int volume) async {
    final res = await _client
        .put(
          _uri('/$deviceId/volume'),
          headers: await headers(),
          body: jsonEncode({
            'seq_num': ++_seq,
            'command_id': '',
            'volume': volume,
          }),
        )
        .timeout(const Duration(seconds: 10));
    _check(res, '音量');
  }

  Future<void> deregister() async {
    final res = await _client
        .delete(
          _uri('/$deviceId'),
          headers: await headers(),
          body: jsonEncode({
            'seq_num': ++_seq,
            'state_ref': null,
            'sub_state': {'playback_speed': 0, 'position': 0, 'duration': 0},
            'debug_source': 'deregister',
          }),
        )
        .timeout(const Duration(seconds: 10));
    _check(res, '注销');
  }

  void _check(http.Response res, String what) {
    if (res.statusCode == 401) invalidate();
    if (res.statusCode >= 300) {
      throw StateError(
        'track-playback $what 失败：HTTP ${res.statusCode} ${res.body}',
      );
    }
  }
}
