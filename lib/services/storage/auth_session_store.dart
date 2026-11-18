import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'key_value_store.dart';

/// 账号会话凭据、令牌生命周期与登出/失效清理状态机。
class AuthSessionStore {
  static const String _keyAccessToken = 'sp_access_token';
  static const String _keyRefreshToken = 'sp_refresh_token';
  static const String _keyApiBaseUrl = 'sp_api_base_url';
  static const String _keySpClientToken = 'sp_spclient_token';

  static const String _keyDeviceId = 'sp_device_id';
  static const String _keyUsername = 'sp_username';
  static const String _keyAccessTokenExpiry = 'sp_access_token_expiry';
  static const String _keyClientToken = 'sp_client_token';
  static const String _keyClientTokenExpiry = 'sp_client_token_expiry';
  static const String _keyClientTokenProfile = 'sp_client_token_profile';

  static const String _keySpDc = 'sp_dc';
  static const String _keyWebAccessToken = 'sp_web_access_token';
  static const String _keyWebAccessTokenExpiry = 'sp_web_access_token_expiry';

  static const String _keyAuthMethod = 'sp_auth_method';
  static const String _desktopSession = 'desktop';
  static const List<String> _legacyKeys = [
    'sp_stored_credential',
    'sp_client_id',
    'sp_client_secret',
  ];

  static const String _keyDisplayName = 'sp_display_name';
  static const String _keyAvatarUrl = 'sp_avatar_url';
  static const String _keyEmail = 'sp_email';

  final KeyValueStore _prefs;

  AuthSessionStore(this._prefs);

  int _sessionEpoch = 0;
  int get sessionEpoch => _sessionEpoch;
  final ValueNotifier<int> sessionInvalidated = ValueNotifier(0);
  Future<void>? _sessionCleanup;
  Future<void>? _cookieCleanup;
  Future<void> Function()? clearWebViewCookies;
  final Set<Future<void> Function()> beforeCookieCleanup = {};
  bool _cookieCleanupNeeded = false;

  bool get cookieCleanupPending =>
      _cookieCleanupNeeded ||
      (_prefs.getBool('auth_cookie_cleanup_pending') ?? false);

  void checkSession(int epoch) {
    if (epoch != _sessionEpoch ||
        _sessionCleanup != null ||
        cookieCleanupPending) {
      throw StateError('登录状态已清除，请重新登录');
    }
  }

  /// Invoke all preference writes before yielding, so invalidation cannot land
  /// between writes and leave part of an old session behind.
  Future<void> writeSession(int epoch, List<Future<bool> Function()> writes) {
    checkSession(epoch);
    return Future.wait(writes.map((write) => write())).then((results) {
      if (results.any((ok) => !ok)) throw StateError('无法保存登录凭据');
      checkSession(epoch);
    });
  }

  Future<void> prepareForLogin() async {
    await _sessionCleanup;
    if (cookieCleanupPending) await retryCookieCleanup();
  }

  Future<int> beginLoginSession({int? expectedEpoch}) async {
    await prepareForLogin();
    if (expectedEpoch != null) checkSession(expectedEpoch);
    return ++_sessionEpoch;
  }

  Future<void> retryCookieCleanup() {
    if (_cookieCleanup != null) return _cookieCleanup!;
    if (!cookieCleanupPending) return Future.value();
    late final Future<void> pending;
    pending = _retryCookieCleanup().whenComplete(() {
      if (identical(_cookieCleanup, pending)) _cookieCleanup = null;
    });
    return _cookieCleanup = pending;
  }

  Future<void> _retryCookieCleanup() async {
    final clear = clearWebViewCookies;
    if (clear == null) throw StateError('WebView Cookie 清理尚未就绪');
    await clearLogin();
    await clear();
    if (!await _prefs.remove('auth_cookie_cleanup_pending')) {
      throw StateError('无法保存 Cookie 清理状态');
    }
    _cookieCleanupNeeded = false;
  }

  Future<void> invalidateSession(int epoch) {
    if (_sessionCleanup != null) return _sessionCleanup!;
    if (epoch != _sessionEpoch) return Future.value();
    ++_sessionEpoch;
    final done = Completer<void>();
    _sessionCleanup = done.future;
    unawaited(() async {
      var notified = false;
      try {
        final credentialsCleared = clearLogin();
        final writes = <Future<void>>[credentialsCleared];
        if (clearWebViewCookies != null) {
          _cookieCleanupNeeded = true;
          writes.add(
            _prefs.setBool('auth_cookie_cleanup_pending', true).then((ok) {
              if (!ok) throw StateError('无法保存 Cookie 清理状态');
            }),
          );
        }
        final persisted = Future.wait(writes);
        notified = true;
        sessionInvalidated.value++;
        await persisted;
        for (final stop in beforeCookieCleanup.toList()) {
          await stop();
        }
        if (clearWebViewCookies != null) await retryCookieCleanup();
      } catch (_) {
        if (!notified) sessionInvalidated.value++;
      } finally {
        _sessionCleanup = null;
        done.complete();
      }
    }());
    return done.future;
  }

  String get receiverDeviceId =>
      _prefs.getString('connect_receiver_device_id') ?? '';

  void ensureReceiverDeviceIdSync() {
    if (RegExp(r'^[a-f0-9]{40}$').hasMatch(receiverDeviceId)) return;
    final random = Random.secure();
    final id = List.generate(
      20,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _prefs.setString('connect_receiver_device_id', id);
  }

  Future<String> ensureReceiverDeviceId() async {
    final current = receiverDeviceId;
    if (RegExp(r'^[a-f0-9]{40}$').hasMatch(current)) return current;
    final random = Random.secure();
    final id = List.generate(
      20,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _prefs.setString('connect_receiver_device_id', id);
    return id;
  }

  Future<void> dropLegacySession() async {
    final method = _prefs.getString(_keyAuthMethod);
    final legacy =
        (method != null && method != _desktopSession) ||
        _legacyKeys.any(_prefs.containsKey);
    if (!legacy) return;
    if (method != _desktopSession) await clearLogin();
    for (final key in _legacyKeys) {
      await _prefs.remove(key);
    }
  }

  String get accessToken => _prefs.getString(_keyAccessToken) ?? '';
  Future<bool> setAccessToken(String value) =>
      _prefs.setString(_keyAccessToken, value);

  String get refreshToken => _prefs.getString(_keyRefreshToken) ?? '';
  Future<bool> setRefreshToken(String value) =>
      _prefs.setString(_keyRefreshToken, value);

  String get apiBaseUrl =>
      _prefs.getString(_keyApiBaseUrl) ?? 'https://api.spotify.com/v1';
  Future<bool> setApiBaseUrl(String value) =>
      _prefs.setString(_keyApiBaseUrl, value);

  String get spClientToken => _prefs.getString(_keySpClientToken) ?? '';
  Future<bool> setSpClientToken(String value) =>
      _prefs.setString(_keySpClientToken, value);

  String get deviceId => _prefs.getString(_keyDeviceId) ?? '';
  Future<bool> setDeviceId(String value) =>
      _prefs.setString(_keyDeviceId, value);

  String get username => _prefs.getString(_keyUsername) ?? '';
  Future<bool> setUsername(String value) =>
      _prefs.setString(_keyUsername, value);

  int get accessTokenExpiry => _prefs.getInt(_keyAccessTokenExpiry) ?? 0;
  Future<bool> setAccessTokenExpiry(int epochMs) =>
      _prefs.setInt(_keyAccessTokenExpiry, epochMs);

  String get clientToken => _prefs.getString(_keyClientToken) ?? '';
  Future<bool> setClientToken(String value) =>
      _prefs.setString(_keyClientToken, value);

  int get clientTokenExpiry => _prefs.getInt(_keyClientTokenExpiry) ?? 0;
  Future<bool> setClientTokenExpiry(int epochMs) =>
      _prefs.setInt(_keyClientTokenExpiry, epochMs);

  String get clientTokenProfile =>
      _prefs.getString(_keyClientTokenProfile) ?? '';
  Future<bool> setClientTokenProfile(String value) =>
      _prefs.setString(_keyClientTokenProfile, value);

  Future<bool> markDesktopSession() =>
      _prefs.setString(_keyAuthMethod, _desktopSession);

  String get spDc => _prefs.getString(_keySpDc) ?? '';
  Future<bool> setSpDc(String value) => _prefs.setString(_keySpDc, value);

  String get webAccessToken => _prefs.getString(_keyWebAccessToken) ?? '';
  int get webAccessTokenExpiry => _prefs.getInt(_keyWebAccessTokenExpiry) ?? 0;
  Future<bool> setWebAccessToken(String token, int expiryMs) async {
    final results = await Future.wait([
      _prefs.setString(_keyWebAccessToken, token),
      _prefs.setInt(_keyWebAccessTokenExpiry, expiryMs),
    ]);
    return results.every((ok) => ok);
  }

  Future<void> clearWebSession() async {
    await _prefs.remove(_keySpDc);
    await _prefs.remove(_keyWebAccessToken);
    await _prefs.remove(_keyWebAccessTokenExpiry);
  }

  String get displayName => _prefs.getString(_keyDisplayName) ?? '';
  Future<bool> setDisplayName(String value) =>
      _prefs.setString(_keyDisplayName, value);

  String get avatarUrl => _prefs.getString(_keyAvatarUrl) ?? '';
  Future<bool> setAvatarUrl(String value) =>
      _prefs.setString(_keyAvatarUrl, value);

  String get email => _prefs.getString(_keyEmail) ?? '';
  Future<bool> setEmail(String value) => _prefs.setString(_keyEmail, value);

  bool get isLoggedIn =>
      _prefs.getString(_keyAuthMethod) == _desktopSession &&
      (refreshToken.isNotEmpty || spDc.isNotEmpty);

  Future<void> clearLogin() async {
    final results = await Future.wait([
      _keyAuthMethod,
      _keyDisplayName,
      _keyAvatarUrl,
      _keyEmail,
      _keyRefreshToken,
      _keyUsername,
      _keyAccessToken,
      _keyAccessTokenExpiry,
      _keyClientToken,
      _keyClientTokenExpiry,
      _keyClientTokenProfile,
      _keySpClientToken,
      _keySpDc,
      _keyWebAccessToken,
      _keyWebAccessTokenExpiry,
    ].map(_prefs.remove));
    if (results.any((ok) => !ok)) throw StateError('无法清除登录凭据');
  }
}
