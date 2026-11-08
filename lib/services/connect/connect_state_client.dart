import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/connect_cluster.dart';
import '../network/retry_after_cooldown.dart';

/// Connect 请求失败。[statusCode] 为 null 表示没有拿到 HTTP 响应（网络错误 / 解析失败 / 未连接）。
class ConnectException implements Exception {
  final int? statusCode;
  final String message;

  const ConnectException(this.statusCode, this.message);

  /// 按状态码给出简短中文说明。
  factory ConnectException.fromStatus(int statusCode) {
    final message = switch (statusCode) {
      401 => '登录已过期，请重新登录',
      403 => '无法控制该设备（免费账号可能受限）',
      404 => '设备已离线或不可用',
      429 => '请求过于频繁，请稍后再试',
      >= 500 => 'Spotify 服务暂时不可用',
      _ => '操作失败',
    };
    return ConnectException(statusCode, message);
  }

  @override
  String toString() =>
      statusCode == null ? message : '$message（HTTP $statusCode）';
}

/// spclient `connect-state/v1` 接口：注册 / 注销隐藏观察者，以及转移、播放命令、音量。
///
/// 约定：
/// - 所有请求都带会话请求头 [_headers] 与 `X-Spotify-Connection-Id`（dealer 连接 id）；
///   注册 / 注销显式传入，控制命令取 [_connectionId]（未连接时抛 [ConnectException]）；
/// - 控制命令的 `from` 是本机观察者 id（`hobs_…`），`to` 是目标设备 id；
/// - 2xx 视为成功，其余抛 [ConnectException]；
/// - 注册响应不带 content-type，但正文是 JSON，所以按字节解析而不看响应头。
class ConnectStateClient {
  final http.Client _client;
  final Future<Map<String, String>> Function() _headers;
  final String Function() _spclientHost;
  final String? Function() _connectionId;
  final RetryAfterCooldown _cooldown;
  int _cooldownStatus = 429;

  ConnectStateClient({
    required this._client,
    required this._headers,
    required this._spclientHost,
    required this._connectionId,
    DateTime Function()? now,
  }) : _cooldown = RetryAfterCooldown(now: now);

  /// 注册隐藏观察者（只收状态，不出现在别的设备的列表里）并返回全量 cluster。
  Future<ConnectCluster> registerObserver(
    String observerId,
    String connectionId,
  ) async {
    final res = await _send(
      'PUT',
      '/connect-state/v1/devices/${Uri.encodeComponent(observerId)}',
      connectionId: connectionId,
      body: {
        'member_type': 'CONNECT_STATE',
        'device': {
          'device_info': {
            'capabilities': {
              'can_be_player': false,
              'hidden': true,
              'needs_full_player_state': true,
            },
          },
        },
      },
    );
    try {
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is Map)
        return ConnectCluster.fromJson(json.cast<String, dynamic>());
    } catch (_) {}
    throw ConnectException(res.statusCode, '无法解析设备状态');
  }

  /// 注销观察者（204）。
  Future<void> unregister(String observerId, String connectionId) => _send(
    'DELETE',
    '/connect-state/v1/devices/${Uri.encodeComponent(observerId)}',
    connectionId: connectionId,
  );

  /// 把播放转移到 [to]；[play] 为 false 时到达后保持暂停。
  Future<void> transfer(String from, String to, {bool play = true}) => _send(
    'POST',
    '/connect-state/v1/connect/transfer/from/${Uri.encodeComponent(from)}/to/${Uri.encodeComponent(to)}',
    body: {
      'transfer_options': {'restore_paused': play ? 'restore' : 'pause'},
    },
  );

  /// 向 [to] 发播放命令：`{"command":{"endpoint":…, ...extra}}`。
  Future<void> command(
    String from,
    String to,
    String endpoint, {
    Map<String, Object?> extra = const {},
  }) => _send(
    'POST',
    '/connect-state/v1/player/command/from/${Uri.encodeComponent(from)}/to/${Uri.encodeComponent(to)}',
    body: {
      'command': {'endpoint': endpoint, ...extra},
    },
  );

  /// 设置 [to] 的音量，[raw] 为 0 – 65535（越界会被截断）。
  Future<void> setVolume(String from, String to, int raw) => _send(
    'PUT',
    '/connect-state/v1/connect/volume/from/${Uri.encodeComponent(from)}/to/${Uri.encodeComponent(to)}',
    body: {'volume': raw.clamp(0, 65535)},
  );

  String _requireConnectionId() {
    final id = _connectionId();
    if (id == null || id.isEmpty)
      throw const ConnectException(null, '尚未连接到 Spotify Connect');
    return id;
  }

  /// [connectionId] 为空时取当前 dealer 连接 id。
  Future<http.Response> _send(
    String method,
    String path, {
    String? connectionId,
    Map<String, Object?>? body,
  }) async {
    _checkCooldown();
    final request = http.Request(
      method,
      Uri.parse('https://${_spclientHost()}$path'),
    );
    final http.Response res;
    try {
      request.headers.addAll({
        ...await _headers().timeout(const Duration(seconds: 10)),
        'Content-Type': 'application/json',
        'X-Spotify-Connection-Id': connectionId ?? _requireConnectionId(),
      });
      _checkCooldown(); // Another request may have been limited while awaiting credentials.
      if (body != null) request.body = jsonEncode(body);
      res = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 10));
    } on ConnectException {
      rethrow;
    } catch (_) {
      throw const ConnectException(null, '网络错误，无法连接 Spotify');
    }
    if (_cooldown.observe(res)) _cooldownStatus = res.statusCode;
    if (res.statusCode < 200 || res.statusCode >= 300)
      throw ConnectException.fromStatus(res.statusCode);
    return res;
  }

  void _checkCooldown() {
    if (_cooldown.active) throw ConnectException.fromStatus(_cooldownStatus);
  }
}
