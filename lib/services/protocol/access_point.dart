import 'dart:async';
import 'dart:typed_data';

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../../src/rust/api/net_config.dart' as rust_net;
import '../network/rust_route.dart';


/// AP 登录凭据（`authentication.proto` LoginCredentials）。
class ApCredentials {
  /// AUTHENTICATION_USER_PASS。
  static const int typeUserPass = 0;

  /// AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS（可复用 blob 原样回传）。
  static const int typeStoredCredentials = 1;

  /// AUTHENTICATION_SPOTIFY_TOKEN（Login5/OAuth 的 access_token）。
  static const int typeSpotifyToken = 3;

  final String? username;
  final int authType;
  final Uint8List authData;

  const ApCredentials({
    this.username,
    required this.authType,
    required this.authData,
  });

  factory ApCredentials.accessToken(String token) => ApCredentials(
    authType: typeSpotifyToken,
    authData: Uint8List.fromList(token.codeUnits),
  );

  factory ApCredentials.password(String username, String password) =>
      ApCredentials(
        username: username,
        authType: typeUserPass,
        authData: Uint8List.fromList(password.codeUnits),
      );

  factory ApCredentials.storedBlob(String username, Uint8List blob) =>
      ApCredentials(
        username: username,
        authType: typeStoredCredentials,
        authData: blob,
      );
}

/// APWelcome 中的登录结果。
class ApWelcome {
  final String canonicalUsername;
  final int reusableAuthType;
  final Uint8List reusableAuth;

  const ApWelcome({
    required this.canonicalUsername,
    required this.reusableAuthType,
    required this.reusableAuth,
  });
}

/// AP 登录失败（AuthFailure / APLoginFailed）。
class ApLoginException implements Exception {
  final int errorCode;
  final String? description;

  const ApLoginException(this.errorCode, [this.description]);

  static const _messages = <int, String>{
    0x00: '协议错误',
    0x02: '该接入点不可用，请换一个（TryAnotherAP）',
    0x05: '连接 ID 无效',
    0x09: '地区限制',
    0x0b: '需要 Premium 账号',
    0x0c: '凭据无效',
    0x0d: '凭据无法验证',
    0x0e: '账号已存在',
    0x0f: '需要额外验证',
    0x10: 'App Key 无效',
    0x11: '应用已被封禁',
  };

  String get message => (description != null && description!.isNotEmpty)
      ? description!
      : (_messages[errorCode] ?? 'AP 登录失败（错误码 $errorCode）');

  @override
  String toString() => message;
}

/// Mercury 请求返回非 200 状态。
class ApMercuryException implements Exception {
  final int statusCode;
  const ApMercuryException(this.statusCode);

  @override
  String toString() => 'Mercury 请求失败（状态 $statusCode）';
}

/// 取音频密钥失败。
class ApKeyException implements Exception {
  final int code;

  /// 服务端原始错误负载（供诊断）。
  final Uint8List raw;
  ApKeyException(this.code, [Uint8List? raw]) : raw = raw ?? Uint8List(0);

  @override
  String toString() =>
      '获取音频密钥失败（错误码 $code${raw.isEmpty ? '' : ' raw=${raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'}）';
}

/// Spotify Access Point 会话：连接、握手（DH + Shannon）、登录、取音频密钥、Mercury，全部由 Rust
/// `ap_client` 完成（对照 librespot `connection/handshake.rs`、`session.rs`、`audio_key.rs`）。
///
/// 这是「完整曲目」链路里唯一必须走非 HTTP 协议的环节（音频密钥没有 REST 接口）。
/// 选路（直连 / HTTP CONNECT / SOCKS5 / 自建网关 WebSocket 隧道）按 [pushRustNetConfig]
/// 推送给 Rust 的网络配置进行；apresolve 解析、接入点轮换与「上次连通优先」也在 Rust 内。
class SpotifyAccessPoint {
  final String? _host;
  final int? _port;
  BigInt? _sessionId;
  bool _closed = false;

  SpotifyAccessPoint._(this._host, this._port);

  /// 连接是否已关闭（服务端断开 / 出错 / 主动关闭），关闭后需重新 connect。
  bool get isClosed => _closed;

  /// 登录成功后的用户名（canonical）。
  String? canonicalUsername;

  /// 可复用凭据（APWelcome 返回，可持久化后免密重登）。
  ({int type, Uint8List blob})? reusableCredentials;

  /// 准备一个 AP 会话。实际的连接与握手在 [authenticate] 时由 Rust 一并完成；
  /// [host] 与 [port] 都给出时只连该接入点，否则经 apresolve 解析并依次尝试。
  ///
  /// 先把当前代理 / 网关配置推送给 Rust；Rust 核心未加载或网关配置无效时抛 [StateError]。
  static Future<SpotifyAccessPoint> connect({String? host, int? port}) async {
    if (!RustCore.ready) throw StateError('Rust 核心未加载，无法连接 Access Point');
    await pushRustNetConfig();
    return SpotifyAccessPoint._(host, port);
  }

  /// 连接接入点并登录，成功返回 [ApWelcome]。服务端拒绝时抛 [ApLoginException]。
  Future<ApWelcome> authenticate(
    ApCredentials credentials, {
    String? deviceId,
  }) async {
    if (_closed) throw StateError('AP 会话已关闭');
    try {
      final w = await rust_net.rustApOpen(
        host: _host,
        port: _port,
        username: credentials.username ?? '',
        authType: credentials.authType,
        authData: credentials.authData,
        deviceId: deviceId ?? '',
      );
      if (_closed) {
        // 登录期间被 close()：Rust 侧会话也要释放
        unawaited(rust.rustApClose(sessionId: w.sessionId).catchError((_) {}));
        throw StateError('AP 会话已关闭');
      }
      _sessionId = w.sessionId;
      canonicalUsername = w.canonicalUsername;
      reusableCredentials = (type: w.reusableAuthType, blob: w.reusableAuth);
      return ApWelcome(
        canonicalUsername: w.canonicalUsername,
        reusableAuthType: w.reusableAuthType,
        reusableAuth: w.reusableAuth,
      );
    } on StateError {
      rethrow;
    } catch (e) {
      final m = RegExp(r'ap_login:(-?\d+):?(.*)').firstMatch(e.toString());
      if (m != null) {
        final desc = m.group(2)?.trim() ?? '';
        throw ApLoginException(int.parse(m.group(1)!), desc.isEmpty ? null : desc);
      }
      rethrow;
    }
  }

  BigInt _requireSession() {
    final sid = _sessionId;
    if (sid == null || _closed) throw StateError('AP 会话已关闭');
    return sid;
  }

  /// 连接已断开时标记关闭，调用方据此重新 connect。
  void _markClosedIfGone(String msg) {
    if (msg.contains('ap:closed') || msg.contains('ap_session_not_found')) {
      _closed = true;
    }
  }

  /// 请求曲目音频密钥（cmd 0x0c → 0x0d）。[fileId] 20 字节，[trackGid] 16 字节。
  Future<Uint8List> requestAudioKey(Uint8List fileId, Uint8List trackGid) async {
    if (fileId.length != 20) throw ArgumentError('fileId must be 20 bytes');
    if (trackGid.length != 16) throw ArgumentError('gid must be 16 bytes');
    final sid = _requireSession();
    try {
      return await rust.rustApRequestAudioKey(
        sessionId: sid,
        fileId: fileId,
        trackGid: trackGid,
      );
    } catch (e) {
      final msg = e.toString();
      final m = RegExp(r'ap_audio_key_error:(-?\d+)').firstMatch(msg);
      if (m != null) throw ApKeyException(int.parse(m.group(1)!));
      _markClosedIfGone(msg);
      rethrow;
    }
  }

  /// 发送 Mercury GET 请求（如 `hm://metadata/4/episode/{gid}`），返回响应体。
  /// 非 200 状态抛 [ApMercuryException]。
  Future<Uint8List> requestMercury(String uri) async {
    final sid = _requireSession();
    try {
      return await rust.rustApMercuryGet(sessionId: sid, uri: uri);
    } catch (e) {
      final msg = e.toString();
      final m = RegExp(r'ap_mercury_http:(\d+)').firstMatch(msg);
      if (m != null) throw ApMercuryException(int.parse(m.group(1)!));
      _markClosedIfGone(msg);
      rethrow;
    }
  }

  /// 关闭会话。
  void close() {
    if (_closed) return;
    _closed = true;
    final sid = _sessionId;
    _sessionId = null;
    if (sid != null) {
      unawaited(rust.rustApClose(sessionId: sid).catchError((_) {}));
    }
  }
}
