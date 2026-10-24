import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import 'client_profile.dart';

/// 登录后拉取账号展示信息（昵称 + 头像）。
///
/// - 首选内部资料接口 `user-profile-view/v3/profile/{username}`（[fetchProfileView]）；
/// - 失败时回退到公开 Web API `GET /v1/me`（[fetchMe]，桌面版 client_id 常被限流，只作兜底）。
class AccountProfileService {
  final http.Client _client;

  AccountProfileService(this._client);

  /// 内部资料接口（桌面版会话使用）。
  ///
  /// 桌面版 client_id 为众多客户端共用，公开 Web API 常年处于 429 限流，内部接口不受影响。
  /// 注意：路径里必须是真实用户名——`profile/me` 会被当作用户名为 "me" 的另一个账号。
  Future<AccountProfile?> fetchProfileView({
    required String username,
    required String accessToken,
    required String clientToken,
    SpotifyClientProfile profile = SpotifyClientProfile.web,
  }) async {
    if (username.isEmpty) return null;
    try {
      final res = await _client.get(
        Uri.parse(
          '${SpotifyEndpoints.defaultSpClientBase}/user-profile-view/v3/profile/'
          '${Uri.encodeComponent(username)}?playlist_limit=0&artist_limit=0',
        ),
        headers: {
          'Authorization': 'Bearer $accessToken',
          if (clientToken.isNotEmpty) 'client-token': clientToken,
          'Accept': 'application/json',
          'User-Agent': profile.userAgent,
          ...profile.headers,
        },
      );
      if (res.statusCode != 200) return null;
      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final name = (json['name'] as String? ?? '').trim();
      if (name.isEmpty) return null;
      return AccountProfile(
        displayName: name,
        avatarUrl: json['image_url'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 公开 `/v1/me`：响应的 id 即用户名，可在 AP 不可达时补全用户名。失败返回 null。
  Future<AccountProfile?> fetchMe(
    String accessToken, {
    SpotifyClientProfile profile = SpotifyClientProfile.web,
  }) async {
    try {
      final res = await _client.get(
        Uri.parse(
          '${SpotifyEndpoints.defaultWebApiBase}${SpotifyEndpoints.me}',
        ),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/json',
          'User-Agent': profile.userAgent,
        },
      );
      if (res.statusCode != 200) return null;
      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final images =
          (json['images'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [];
      images.sort(
        (a, b) =>
            ((b['width'] as num?) ?? 0).compareTo((a['width'] as num?) ?? 0),
      );
      return AccountProfile(
        id: json['id'] as String? ?? '',
        email: (json['email'] as String? ?? '').trim(),
        displayName:
            (json['display_name'] as String?)?.trim().isNotEmpty == true
            ? json['display_name'] as String
            : json['id'] as String? ?? '',
        avatarUrl: images.isEmpty ? '' : images.first['url'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 账号展示信息。
class AccountProfile {
  /// 用户 ID（仅 /v1/me 返回，可作为 username）。
  final String id;
  final String email;
  final String displayName;
  final String avatarUrl;

  const AccountProfile({
    this.id = '',
    this.email = '',
    required this.displayName,
    required this.avatarUrl,
  });
}
