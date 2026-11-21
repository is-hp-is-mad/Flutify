import '../../core/rust_core.dart';
import '../../src/rust/api/session_tokens.dart' as rust;
import '../rust_backend_bridge.dart';
import '../storage/auth_session_store.dart';
import 'auth_constants.dart';
import 'web_token_exception.dart';

/// 续期得到的令牌与到期时间（毫秒时间戳）。
typedef SessionToken = ({String token, int expiryMs});

/// 会话令牌的续期来源（生产环境为 Rust 会话核心 [RustSessionTokenSource]）。
///
/// 返回 null 表示这次不由它处理（Rust 核心未加载、目标需走自定义网关、传输层失败），
/// 调用方改走 Dart HTTP 实现。HTTP 拒绝等确定性失败直接抛出：
/// - Web token：[WebTokenHttpException]（状态码）、[WebSignInRequiredException]（缺 sp_dc）、[StateError]；
/// - client-token：[StateError]。
///
/// 结果由调用方按会话 epoch 写回 [AuthSessionStore]。
abstract interface class SessionTokenSource {
  /// 用会话的 `sp_dc` 强制重新铸造 Web access_token。
  Future<SessionToken?> refreshWebAccessToken(AuthSessionStore storage);

  /// 用会话的 device_id 强制重新申请 Web 播放器 client-token。
  Future<SessionToken?> refreshClientToken(AuthSessionStore storage);
}

/// [SessionTokenSource] 的续期结果写回前的公共处理：令牌端点 401 表示 `sp_dc` 已被吊销，
/// 与 [SessionHttpClient] 对 Dart 请求的处理一致，清除这一会话的登录态（含 WebView cookie）。
Future<SessionToken?> refreshWebTokenVia(
  SessionTokenSource source,
  AuthSessionStore storage,
) async {
  final epoch = storage.sessionEpoch;
  try {
    return await source.refreshWebAccessToken(storage);
  } on WebTokenHttpException catch (e) {
    if (e.statusCode == 401) await storage.invalidateSession(epoch);
    rethrow;
  }
}

/// Rust 会话核心（`spotify_session`）的令牌续期：单飞、按 epoch 写回 Rust 会话。
///
/// 调用前先把 Dart 存储的会话（sp_dc / device_id / epoch）同步给 Rust；
/// 代理按目标地址由 [RustBackendBridge.proxyForUrl] 选取，需走网关时交回 Dart。
class RustSessionTokenSource implements SessionTokenSource {
  const RustSessionTokenSource();

  static const String _tokenEndpoint = 'https://open.spotify.com/api/token';

  @override
  Future<SessionToken?> refreshWebAccessToken(AuthSessionStore storage) async {
    if (!RustCore.ready) return null;
    final proxy = await RustBackendBridge.proxyForUrl(_tokenEndpoint);
    if (proxy == null) return null;
    RustBackendBridge.syncSession(storage);
    try {
      final r = await rust.rustSessionEnsureWebAccessToken(
        forceRefresh: true,
        proxy: proxy,
      );
      return (token: r.token, expiryMs: r.expiryMs.toInt());
    } catch (e) {
      final msg = e.toString();
      final status = _httpStatus(msg);
      if (status != null) throw WebTokenHttpException(status);
      if (msg.contains('auth:')) throw WebSignInRequiredException();
      if (msg.contains('decode:')) {
        throw StateError('Minting the web token failed: invalid response');
      }
      return null; // connect: / timeout: / request: 等传输错误交回 Dart
    }
  }

  @override
  Future<SessionToken?> refreshClientToken(AuthSessionStore storage) async {
    if (!RustCore.ready) return null;
    final proxy = await RustBackendBridge.proxyForUrl(
      SpotifyAuthConstants.clientTokenEndpoint,
    );
    if (proxy == null) return null;
    RustBackendBridge.syncSession(storage);
    try {
      final r = await rust.rustSessionEnsureClientToken(
        forceRefresh: true,
        proxy: proxy,
      );
      return (token: r.token, expiryMs: r.expiryMs.toInt());
    } catch (e) {
      final msg = e.toString();
      final status = _httpStatus(msg);
      if (status != null) throw StateError('client-token HTTP $status');
      if (msg.contains('auth:') || msg.contains('decode:')) {
        throw StateError('Requesting the client token failed: $msg');
      }
      return null;
    }
  }

  static int? _httpStatus(String msg) {
    final m = RegExp(r'http:(\d+):').firstMatch(msg);
    return m == null ? null : int.parse(m.group(1)!);
  }
}
