import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_constants.dart';
import 'client_profile.dart';

/// 申请 Web 播放器 client-token（`clienttoken.spotify.com/v1/clienttoken`）的 Dart 实现。
///
/// 生产环境由 Rust 会话核心申请（见 `RustSessionTokenSource`）；这里只在需要走自定义网关、
/// Rust 传输失败或单元测试（未加载 Rust 核心）时使用。
///
/// client-token 与 access_token 是两套令牌：前者是设备/客户端态，spclient 内部接口普遍要求携带。
class ClientTokenService {
  final http.Client _client;

  ClientTokenService(this._client);

  /// 以 Web 播放器身份申请（对齐 open.spotify.com 前端）：JSON 请求体
  /// `{client_data:{client_version, client_id, js_sdk_data:{…}}}`，响应取 `granted_token`。
  /// Web 前端不处理挑战，这里也一样：没拿到令牌即失败（抛 [StateError]）。
  Future<GrantedClientToken> request(String deviceId) async {
    const profile = SpotifyClientProfile.web;
    final res = await _client.post(
      Uri.parse(SpotifyAuthConstants.clientTokenEndpoint),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': profile.userAgent,
      },
      body: jsonEncode({
        'client_data': {
          'client_version': profile.clientVersion,
          'client_id': profile.clientId,
          'js_sdk_data': profile.jsSdkData(deviceId),
        },
      }),
    );
    if (res.statusCode != 200) {
      throw StateError('client-token HTTP ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final granted = body is Map ? body['granted_token'] : null;
    final token = granted is Map ? granted['token'] : null;
    if (token is! String || token.isEmpty) {
      throw StateError('client-token 申请失败：未返回令牌（${body is Map ? body['response_type'] : 'invalid'}）');
    }
    int seconds(Object? v, int fallback) => v is num ? v.toInt() : fallback;
    final refreshAfter = seconds(granted['refresh_after_seconds'], 1209600);
    return GrantedClientToken(
      token: token,
      expiresAfterSeconds: seconds(granted['expires_after_seconds'], refreshAfter),
      refreshAfterSeconds: refreshAfter,
    );
  }
}

/// 申请成功的 client-token 及其有效期。
class GrantedClientToken {
  final String token;
  final int expiresAfterSeconds;
  final int refreshAfterSeconds;

  GrantedClientToken({
    required this.token,
    required this.expiresAfterSeconds,
    required this.refreshAfterSeconds,
  });

  /// 到期时间戳（毫秒）。
  int expiryEpochMs(DateTime now) => now.add(Duration(seconds: expiresAfterSeconds)).millisecondsSinceEpoch;
}
