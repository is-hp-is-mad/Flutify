import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/constants/spotify_endpoints.dart';
import '../protocol/access_point.dart';
import '../storage_service.dart';
import 'account_profile_service.dart';
import 'auth_constants.dart';
import 'client_profile.dart';
import 'client_token_service.dart';
import 'session_expired_exception.dart';
import 'session_http_client.dart';
import 'web_token_exception.dart';
import 'web_token_service.dart';

/// Spotify 身份鉴权总控：只有一条登录链路——**Web 登录**。
///
/// 在应用内 WebView（Linux 为系统 Chrome）登录 open.spotify.com，取得 Web 会话凭据 `sp_dc`，
/// 再用 `sp_dc + TOTP` 铸造 access_token；过期时用同一个 `sp_dc` 重新铸造。App 不接触密码。
/// client-token 以桌面端身份申请。
///
/// 说明：以官方客户端身份访问违反 Spotify 服务条款，存在账号风控风险，建议用小号测试。
class SpotifyAuthService {
  /// 令牌提前续期的余量：剩余有效期不足该值即视为过期。
  static const int _refreshMarginMs = 60 * 1000;

  /// Web 登录铸造的令牌属于 Web 播放器，client-token 与业务请求头必须同一身份。
  static const SpotifyClientProfile _profile = SpotifyClientProfile.web;

  final StorageService _storage;
  final http.Client _client;
  final ClientTokenService _clientTokenService;
  final AccountProfileService _profiles;

  /// 按 access_token 查询 canonical username（默认登录 AP 读 APWelcome；测试注入替身）。
  final Future<String> Function(String accessToken, String deviceId)
  _usernameResolver;

  /// 正在进行中的续期请求：并发调用复用同一个 Future，避免重复打令牌端点。
  Future<String>? _refreshInFlight;
  Future<String>? _clientTokenInFlight;

  /// 登录已失效：服务端吊销了续期凭据，只能重新登录。置位后不再请求令牌端点（避免每个请求都打一次），
  /// 重新登录或登出时清除。不持久化：重启 App 会再试一次续期。
  final ValueNotifier<bool> sessionExpired = ValueNotifier(false);

  SpotifyAuthService._(
    this._storage,
    this._client,
    this._usernameResolver,
  ) : _clientTokenService = ClientTokenService(_client),
      _profiles = AccountProfileService(_client) {
    _storage.sessionInvalidated.addListener(() {
      _refreshInFlight = null;
      _clientTokenInFlight = null;
      sessionExpired.value = false;
    });
  }

  factory SpotifyAuthService(
    StorageService storage, [
    http.Client? client,
    Future<String> Function(String accessToken, String deviceId)?
    usernameResolver,
  ]) {
    final http.Client effectiveClient = SessionHttpClient(
      storage,
      client ?? http.Client(),
    );
    return SpotifyAuthService._(
      storage,
      effectiveClient,
      usernameResolver ??
          (token, deviceId) =>
              _usernameFromAccessPoint(effectiveClient, token, deviceId),
    );
  }

  bool get isLoggedIn => _storage.isLoggedIn;
  ValueListenable<int> get sessionInvalidated => _storage.sessionInvalidated;
  String get username => _storage.username;
  String get displayName => _storage.displayName.isNotEmpty
      ? _storage.displayName
      : _storage.username;
  String get avatarUrl => _storage.avatarUrl;

  /// 业务请求应附带的客户端头（User-Agent / app-platform / spotify-app-version），与令牌所属客户端一致。
  Map<String, String> get clientHeaders {
    if (!isLoggedIn) return const {};
    return {'user-agent': _profile.userAgent, ..._profile.headers};
  }

  /// access_token 到期时间；未登录返回 null。
  DateTime? get accessTokenExpiry {
    final ms = _storage.accessTokenExpiry;
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 设备 ID：首次调用时生成并持久化（client-token 与其绑定，不可随意更换）。
  Future<String> _deviceId() async {
    var id = _storage.deviceId;
    if (id.isEmpty) {
      id = SpotifyAuthConstants.generateDeviceId();
      await _storage.setDeviceId(id);
    }
    return id;
  }

  static bool _isFresh(int expiryMs) =>
      expiryMs > DateTime.now().millisecondsSinceEpoch + _refreshMarginMs;

  // ---------------------------------------------------------------------------
  // client-token
  // ---------------------------------------------------------------------------

  /// 获取有效的 Web 播放器 client-token；过期、缺失或身份不一致（旧版本留下的桌面端）则重新申请。
  Future<String> ensureClientToken() {
    _storage.checkSession(_storage.sessionEpoch);
    if (_storage.clientToken.isNotEmpty &&
        _storage.clientTokenProfile == _profile.name &&
        _isFresh(_storage.clientTokenExpiry)) {
      return Future.value(_storage.clientToken);
    }
    if (_clientTokenInFlight != null) return _clientTokenInFlight!;
    late final Future<String> pending;
    pending = _requestClientToken().whenComplete(() {
      if (identical(_clientTokenInFlight, pending)) _clientTokenInFlight = null;
    });
    return _clientTokenInFlight = pending;
  }

  Future<String> _requestClientToken() async {
    final epoch = _storage.sessionEpoch;
    final granted = await _clientTokenService.request(
      await _deviceId(),
      _profile,
    );
    await _storage.writeSession(epoch, [
      () => _storage.setClientToken(granted.token),
      () =>
          _storage.setClientTokenExpiry(granted.expiryEpochMs(DateTime.now())),
      () => _storage.setClientTokenProfile(_profile.name),
    ]);
    return granted.token;
  }

  // ---------------------------------------------------------------------------
  // Web 登录
  // ---------------------------------------------------------------------------

  /// 用已完成的 Web 会话（`sp_dc` + 铸造的 `webAccessToken`）建立全局登录态。
  Future<void> completeWebSignIn() async {
    final epoch = _storage.sessionEpoch;
    _storage.checkSession(epoch);
    var token = _storage.webAccessToken;
    var expiryMs = _storage.webAccessTokenExpiry;
    if (token.isEmpty || !_isFresh(expiryMs)) {
      final minted = await WebTokenService.mintTokenForSpDc(
        _storage.spDc,
        client: _client,
      );
      token = minted.token;
      expiryMs = minted.expiryMs;
    }
    await _storage.writeSession(epoch, [
      _storage.markDesktopSession,
      () => _storage.setWebAccessToken(token, expiryMs),
      () => _storage.setAccessToken(token),
      () => _storage.setAccessTokenExpiry(expiryMs),
    ]);
    sessionExpired.value = false;
    try {
      await ensureClientToken();
    } catch (_) {}
    _storage.checkSession(epoch);
    try {
      await _loadProfile();
    } catch (_) {}
    _storage.checkSession(epoch);
  }

  // ---------------------------------------------------------------------------
  // 令牌续期
  // ---------------------------------------------------------------------------

  /// 返回有效 access_token；过期时用 `sp_dc` 重新铸造。
  Future<String> ensureAccessToken() {
    _storage.checkSession(_storage.sessionEpoch);
    if (_storage.accessToken.isNotEmpty &&
        _isFresh(_storage.accessTokenExpiry)) {
      return Future.value(_storage.accessToken);
    }
    return refreshAccessToken();
  }

  /// 强制续期（并发调用会合并）。
  Future<String> refreshAccessToken() {
    if (!_storage.isLoggedIn) {
      return Future.error(StateError('未登录，无法获取 access_token'));
    }
    if (sessionExpired.value) {
      return Future.error(const SessionExpiredException());
    }
    if (_refreshInFlight != null) return _refreshInFlight!;
    late final Future<String> pending;
    pending = _refresh().whenComplete(() {
      if (identical(_refreshInFlight, pending)) _refreshInFlight = null;
    });
    return _refreshInFlight = pending;
  }

  /// 等待进行中的续期落盘（关窗前调用）。
  Future<void> settle() async {
    final inFlight = _refreshInFlight;
    if (inFlight == null) return;
    try {
      await inFlight;
    } catch (_) {}
  }

  Future<String> _refresh() async {
    final epoch = _storage.sessionEpoch;
    // 没有 Web 会话：旧版本的桌面授权会话（只有 refresh_token）已不再支持，需要重新登录
    if (_storage.spDc.isEmpty) {
      sessionExpired.value = true;
      throw const SessionExpiredException();
    }
    try {
      final minted = await WebTokenService.mintTokenForSpDc(
        _storage.spDc,
        client: _client,
      );
      await _storage.writeSession(epoch, [
        _storage.markDesktopSession,
        () => _storage.setWebAccessToken(minted.token, minted.expiryMs),
        () => _storage.setAccessToken(minted.token),
        () => _storage.setAccessTokenExpiry(minted.expiryMs),
      ]);
      sessionExpired.value = false;
      return _storage.accessToken;
    } on WebTokenHttpException catch (e) {
      if (epoch == _storage.sessionEpoch && e.statusCode == 401) {
        sessionExpired.value = true;
        throw const SessionExpiredException();
      }
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // 账号资料
  // ---------------------------------------------------------------------------

  /// 先确定用户名，再走内部资料接口，失败回退公开 /v1/me（后者常被限流）。
  Future<void> _loadProfile() async {
    final epoch = _storage.sessionEpoch;
    _storage.checkSession(epoch);
    if (_storage.username.isEmpty) {
      // 旧版本按 `profile/me` 取到的是另一个账号的资料，先清掉，取不到新资料时宁可显示用户名
      await _storage.writeSession(epoch, [
        () => _storage.setDisplayName(''),
        () => _storage.setAvatarUrl(''),
      ]);
      try {
        final username = await _usernameResolver(
          _storage.accessToken,
          _storage.deviceId,
        );
        if (username.isNotEmpty) {
          await _storage.writeSession(epoch, [
            () => _storage.setUsername(username),
          ]);
        }
      } catch (_) {
        // AP 不可达时交给 /v1/me 回退（其响应的 id 即用户名）
      }
    }
    _storage.checkSession(epoch);
    final profile =
        await _profiles.fetchProfileView(
          username: _storage.username,
          accessToken: _storage.accessToken,
          clientToken: _storage.clientToken,
        ) ??
        await _profiles.fetchMe(_storage.accessToken);
    _storage.checkSession(epoch);
    if (profile == null) return;
    await _storage.writeSession(epoch, [
      if (profile.id.isNotEmpty && _storage.username.isEmpty)
        () => _storage.setUsername(profile.id),
      if (profile.email.isNotEmpty) () => _storage.setEmail(profile.email),
      () => _storage.setDisplayName(profile.displayName),
      () => _storage.setAvatarUrl(profile.avatarUrl),
    ]);
  }

  /// 令牌响应不含用户名：用 access_token 登录 AP，从 APWelcome 取 canonical username。
  /// 媒体库（rootlist / 收藏集合）与资料接口都按用户名寻址，缺它整个媒体库为空。
  static Future<String> _usernameFromAccessPoint(
    http.Client client,
    String accessToken,
    String deviceId,
  ) async {
    final ap = await SpotifyAccessPoint.connect(client: client);
    try {
      final welcome = await ap.authenticate(
        ApCredentials.accessToken(accessToken),
        deviceId: deviceId.isEmpty ? null : deviceId,
      );
      return welcome.canonicalUsername;
    } finally {
      ap.close();
    }
  }

  /// 恢复的会话缺资料时需要补拉：昵称或用户名缺失（如登录时资料接口失败）。
  bool get needsProfile =>
      isLoggedIn && (_storage.displayName.isEmpty || _storage.username.isEmpty);

  /// 补拉资料；失败静默。
  Future<void> ensureProfile() async {
    if (!needsProfile) return;
    try {
      await ensureAccessToken();
      await ensureClientToken();
      await _loadProfile();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // 登出
  // ---------------------------------------------------------------------------

  /// 登出：尽力通知服务端（`/api/logout/v1`），然后清除全部登录态（保留 device_id）。
  Future<void> logout() async {
    final epoch = _storage.sessionEpoch;
    // 已失效的会话不必再通知服务端（令牌早已过期）
    final expired = sessionExpired.value;
    sessionExpired.value = false;
    final token = _storage.accessToken;
    if (!expired && isLoggedIn && token.isNotEmpty) {
      try {
        await _client
            .post(
              Uri.parse(
                '${SpotifyEndpoints.defaultSpClientBase}/api/logout/v1',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                if (_storage.clientToken.isNotEmpty)
                  'client-token': _storage.clientToken,
                ...clientHeaders,
              },
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _storage.invalidateSession(epoch);
  }
}
