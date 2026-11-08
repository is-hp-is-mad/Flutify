import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/utils/json_bytes.dart';
import 'pathfinder_operations.dart';

/// GraphQL Pathfinder 客户端（`api-partner.spotify.com/pathfinder/v2/query`）。
///
/// 与桌面版一致使用 v2：POST JSON `{variables, operationName, extensions.persistedQuery}`。
/// 请求头（Bearer、client-token、桌面 UA / app-platform）由 [headers] 提供，保证与会话身份一致。
class PathfinderClient {
  static const String endpoint = 'https://api-partner.spotify.com/pathfinder/v2/query';

  final http.Client _client;
  final Future<Map<String, String>> Function() headers;

  PathfinderClient(this._client, {required this.headers});

  /// 执行查询并返回 `data`；HTTP 非 200 或响应含 errors 且无 data 时抛 [PathfinderException]。
  Future<Map<String, dynamic>> query(PathfinderOperation op, Map<String, Object?> variables) async {
    final res = await _client.post(
      Uri.parse(endpoint),
      headers: {...await headers(), 'content-type': 'application/json;charset=UTF-8'},
      body: jsonEncode({
        'variables': variables,
        'operationName': op.name,
        'extensions': {
          'persistedQuery': {'version': 1, 'sha256Hash': op.sha256Hash},
        },
      }),
    );

    Object? json;
    try {
      // 主页 / 专辑 / 艺人 / 搜索 / 歌单补全的响应可达数 MB：大响应在后台 Isolate 解码，不卡 UI
      json = await decodeJsonBytes(res.bodyBytes);
    } catch (_) {}
    final data = json is Map<String, dynamic> ? json['data'] : null;
    if (res.statusCode != 200 || data is! Map<String, dynamic>) {
      final errors = json is Map<String, dynamic> ? json['errors'] : null;
      final hashStale = _isHashStale(errors);
      throw PathfinderException(op.name, res.statusCode, errors?.toString() ?? '', hashStale: hashStale);
    }
    return data;
  }

  /// 桌面客户端升级后旧的 sha256Hash 会被服务端拒绝：
  /// 返回 `PersistedQueryNotFound` 类错误（不同版本的 code / message 写法略有差异）。
  static bool _isHashStale(Object? errors) {
    if (errors is! List) return false;
    for (final e in errors) {
      if (e is! Map) continue;
      final code = (e['extensions'] is Map ? (e['extensions'] as Map)['code'] : null)?.toString() ?? '';
      final message = e['message']?.toString() ?? '';
      if (code.toLowerCase().contains('persistedquery') ||
          message.toLowerCase().contains('persisted query') ||
          message.toLowerCase().contains('persistedquery')) {
        return true;
      }
    }
    return false;
  }
}

class PathfinderException implements Exception {
  final String operation;
  final int statusCode;
  final String detail;

  /// 持久化查询哈希已失效（桌面客户端升级后旧 hash 被拒）。只能更新客户端解决。
  final bool hashStale;

  const PathfinderException(this.operation, this.statusCode, this.detail, {this.hashStale = false});

  /// 面向用户、可直接展示的说明。
  String get message => hashStale
      ? 'Spotify 桌面客户端已升级，本版本的查询签名已失效，请更新 Flutify 后重试'
      : 'Pathfinder $operation 失败（HTTP $statusCode）$detail';

  @override
  String toString() => message;
}
