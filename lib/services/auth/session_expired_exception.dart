/// 登录已失效：Web 会话（`sp_dc`）被服务端吊销，或是旧版本留下的、已不再支持的桌面授权会话。
/// 只能重新登录。
class SessionExpiredException implements Exception {
  final String message;

  const SessionExpiredException([this.message = '登录已过期，请重新登录']);

  @override
  String toString() => message;
}
