import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../services/auth/session_expired_exception.dart';
import '../services/auth/spotify_auth_service.dart';

/// 登录流程所处阶段。
enum AuthStatus {
  /// 未登录（可展示登录页）。
  signedOut,

  /// 已登录。
  signedIn,
}

/// Spotify 账号登录态（唯一方式：Web 登录）。
///
/// UI 只与本类交互：它把 [SpotifyAuthService] 的异步结果翻译成可渲染的状态与中文错误提示。
/// 登录 / 登出成功后回调 [onSessionChanged]，由外部刷新依赖登录态的数据。
class AuthProvider extends ChangeNotifier {
  final SpotifyAuthService _auth;

  /// 登录态变化（登录成功 / 登出）后的回调。
  VoidCallback? onSessionChanged;

  AuthStatus _status;
  AuthFailure? _failure;
  bool _refreshing = false;
  int _revision = 0;
  bool _disposed = false;

  AuthProvider(this._auth)
    : _status = _auth.isLoggedIn ? AuthStatus.signedIn : AuthStatus.signedOut {
    // 恢复的会话缺资料（昵称 / 用户名）时启动后补拉；拿到用户名后媒体库需要重新加载
    unawaited(_backfillProfile());
    _auth.sessionExpired.addListener(notifyListeners);
    _auth.sessionInvalidated.addListener(_onSessionInvalidated);
  }

  void _onSessionInvalidated() {
    ++_revision;
    _status = AuthStatus.signedOut;
    _refreshing = false;
    _failure = const AuthFailure(
      AuthFailureKind.sessionInvalidated,
      '登录已失效，已清除登录凭据，请重新登录',
    );
    notifyListeners();
    onSessionChanged?.call();
  }

  /// 资料补拉的退避间隔：登录刚完成时 AP 取用户名可能失败、/v1/me 常被限流，
  /// 不重试的话要重启 App 才有用户名（媒体库、歌单都按用户名寻址）。
  static const List<Duration> _profileRetryDelays = [
    Duration.zero,
    Duration(seconds: 3),
    Duration(seconds: 8),
    Duration(seconds: 20),
  ];

  /// 资料缺失时按 [_profileRetryDelays] 补拉，用户名变化后回调 [onSessionChanged] 刷新依赖数据。
  Future<void> _backfillProfile() async {
    for (final delay in _profileRetryDelays) {
      if (_disposed || !_auth.needsProfile) return;
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (_disposed || !_auth.needsProfile) return;
      final usernameBefore = _auth.username;
      await _auth.ensureProfile();
      if (_disposed || !isSignedIn) return;
      if (_auth.username != usernameBefore || !_auth.needsProfile) {
        notifyListeners();
        if (_auth.username != usernameBefore) onSessionChanged?.call();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    _auth.sessionExpired.removeListener(notifyListeners);
    _auth.sessionInvalidated.removeListener(_onSessionInvalidated);
    super.dispose();
  }

  /// 已登录但续期凭据被服务端吊销：界面应提示「登录已过期」并引导重新登录，而不是报网络错误。
  bool get sessionExpired => isSignedIn && _auth.sessionExpired.value;

  AuthStatus get status => _status;
  bool get isSignedIn => _status == AuthStatus.signedIn;
  bool get isRefreshing => _refreshing;

  /// 最近一次操作的错误提示；新的操作开始时清空。
  String? get error => _failure?.message;

  /// 与 [error] 对应的结构化原因：界面按 [AuthFailure.kind] 显示本地化文案，
  /// [AuthFailure.message] 只是中文兜底（日志 / 测试用）。
  AuthFailure? get failure => _failure;

  String get username => _auth.username;
  String get displayName => _auth.displayName;
  String get avatarUrl => _auth.avatarUrl;
  DateTime? get accessTokenExpiry => _auth.accessTokenExpiry;

  // ---------------------------------------------------------------------------
  // Web 登录
  // ---------------------------------------------------------------------------

  /// 用已完成的 Web 会话（`sp_dc` + 铸造的 `webAccessToken`）完成登录。
  Future<void> completeWebSignIn() async {
    final revision = ++_revision;
    _failure = null;
    try {
      await _auth.completeWebSignIn();
    } catch (e) {
      if (_disposed || revision != _revision) return;
      _failure = describeFailure(e);
      notifyListeners();
      return;
    }
    if (_disposed || revision != _revision || !_auth.isLoggedIn) return;
    _status = AuthStatus.signedIn;
    notifyListeners();
    onSessionChanged?.call();
    unawaited(_backfillProfile());
  }

  // ---------------------------------------------------------------------------
  // 已登录操作
  // ---------------------------------------------------------------------------

  /// 立即续期 access_token（设置页「刷新令牌」）。
  Future<void> refreshToken() async {
    if (!isSignedIn || _refreshing) return;
    _refreshing = true;
    final revision = _revision;
    _failure = null;
    notifyListeners();
    try {
      await _auth.refreshAccessToken();
    } catch (e) {
      if (_disposed || revision != _revision) return;
      _failure = describeFailure(e);
    }
    if (_disposed || revision != _revision) return;
    _refreshing = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    await _auth.logout();
    if (_disposed) return;
    final changed = _status != AuthStatus.signedOut;
    _failure = null;
    _status = AuthStatus.signedOut;
    notifyListeners();
    if (changed) onSessionChanged?.call();
  }

  void clearError() {
    if (_failure == null) return;
    _failure = null;
    notifyListeners();
  }

  /// 把底层异常翻译为面向用户的中文提示（兜底文案；界面显示以 [describeFailure] 的 kind 为准）。
  @visibleForTesting
  static String describeError(Object e) => describeFailure(e).message;

  /// 把底层异常归类为 [AuthFailure]，界面据此显示本地化提示。
  static AuthFailure describeFailure(Object e) {
    if (e is SessionExpiredException) {
      return AuthFailure(AuthFailureKind.sessionExpired, e.toString());
    }
    if (e is SocketException ||
        e is TimeoutException ||
        e is http.ClientException) {
      return const AuthFailure(
        AuthFailureKind.network,
        '无法连接到 Spotify，请检查网络或代理',
      );
    }
    if (e is StateError) {
      return AuthFailure(AuthFailureKind.message, e.message, detail: e.message);
    }
    return AuthFailure(AuthFailureKind.failed, '登录失败：$e', detail: '$e');
  }
}

/// 登录相关错误的类别：界面按类别显示本地化文案。
enum AuthFailureKind {
  /// 服务端让登录失效，已清除凭据。
  sessionInvalidated,

  /// 登录已过期。
  sessionExpired,

  /// 网络不可达（含代理问题）。
  network,

  /// 底层给出的原始说明，原样显示 [AuthFailure.detail]。
  message,

  /// 其他失败，显示「登录失败：detail」。
  failed,
}

class AuthFailure {
  const AuthFailure(this.kind, this.message, {this.detail = ''});

  final AuthFailureKind kind;

  /// 中文兜底文案。
  final String message;

  /// 底层异常说明（不翻译）。
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is AuthFailure &&
      other.kind == kind &&
      other.message == message &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, message, detail);
}
