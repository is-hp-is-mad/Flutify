import 'package:http/http.dart' as http;

import '../network/http2_client.dart';
import '../storage_service.dart';

/// Observes account-authenticated Spotify HTTP responses only. CDN URLs,
/// anonymous certificate requests and third-party services cannot log out an
/// account. Does not alter TLS, redirects, headers, or response bodies.
///
/// 直连的 Spotify API 请求经 [Http2Client] 走 Rust HTTP/2（一条连接多路复用），
/// 其余请求（含网关 / 代理、CDN、未加载 Rust 核心的测试）原样交给 [client]。
class SessionHttpClient extends http.BaseClient {
  SessionHttpClient(this.storage, http.Client client)
    : _client = client is Http2Client ? client : Http2Client(client);

  final StorageService storage;
  final http.Client _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final epoch = storage.sessionEpoch;
    final accountRequest = _isAccountRequest(request);
    final response = await _client.send(request);
    if (response.statusCode == 401 && accountRequest) {
      await storage.invalidateSession(epoch);
    }
    return response;
  }

  bool _isAccountRequest(http.BaseRequest request) {
    final uri = request.url;
    if (uri.scheme != 'https' ||
        !(uri.host == 'spotify.com' || uri.host.endsWith('.spotify.com'))) {
      return false;
    }
    String header(String name) =>
        request.headers.entries
            .where((e) => e.key.toLowerCase() == name)
            .map((e) => e.value)
            .firstOrNull ??
        '';
    final authorization = header('authorization');
    if ([
      storage.accessToken,
      storage.webAccessToken,
    ].any((token) => token.isNotEmpty && authorization == 'Bearer $token')) {
      return true;
    }
    if (storage.spDc.isNotEmpty &&
        header('cookie')
            .split(';')
            .any((cookie) => cookie.trim() == 'sp_dc=${storage.spDc}')) {
      return true;
    }
    return uri.host == 'accounts.spotify.com' &&
        uri.path == '/api/token' &&
        request.method == 'POST';
  }

  @override
  void close() => _client.close();
}
