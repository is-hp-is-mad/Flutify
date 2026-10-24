import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 持久化封装：凭证、配置、媒体库与播放偏好。
class StorageService {
  static const String _keyAccessToken = 'sp_access_token';
  static const String _keyRefreshToken = 'sp_refresh_token';
  static const String _keyApiBaseUrl = 'sp_api_base_url';
  static const String _keySpClientToken = 'sp_spclient_token';
  static const String _keyProxyPassword = 'sp_proxy_password';

  // 会话凭据
  static const String _keyDeviceId = 'sp_device_id';
  static const String _keyUsername = 'sp_username';
  static const String _keyAccessTokenExpiry =
      'sp_access_token_expiry'; // epoch ms
  static const String _keyClientToken = 'sp_client_token';
  static const String _keyClientTokenExpiry =
      'sp_client_token_expiry'; // epoch ms
  static const String _keyClientTokenProfile = 'sp_client_token_profile';

  // Web 播放器会话（Widevine 真密钥所需的 access_token 来源）
  static const String _keySpDc = 'sp_dc'; // open.spotify.com 的登录 cookie
  static const String _keyWebAccessToken = 'sp_web_access_token';
  static const String _keyWebAccessTokenExpiry =
      'sp_web_access_token_expiry'; // epoch ms

  // 会话类型与账号展示信息
  static const String _keyAuthMethod = 'sp_auth_method';

  /// 唯一支持的会话类型：桌面版浏览器 OAuth。
  static const String _desktopSession = 'desktop';

  /// 已移除的登录方式（Login5 密码 / 短信 / 凭据导入、开发者应用 OAuth）留下的键，启动时清理。
  static const List<String> _legacyKeys = [
    'sp_stored_credential',
    'sp_client_id',
    'sp_client_secret',
  ];
  static const String _keyDisplayName = 'sp_display_name';
  static const String _keyAvatarUrl = 'sp_avatar_url';
  static const String _keyEmail = 'sp_email';

  static const String _keyRecentSearches = 'sp_recent_searches';
  static const String _keyVolume = 'sp_volume';
  static const String _keyPauseAfterFailures = 'play_pause_after_failures';
  static const String _keyImmersiveScreen =
      'ui_immersive_screen'; // 沉浸式歌词铺满整个屏幕
  static const String _keyImmersivePinned =
      'ui_immersive_pinned'; // 沉浸式歌词固定控制区（不自动收起）
  static const String _keyAppearance = 'ui_appearance'; // 外观设置 JSON
  static const String _keyPreferences =
      'app_prefs'; // 其余界面偏好 JSON（AppPreferences）
  static const String _keyLastTab = 'ui_last_tab'; // 上次所在 Tab（启动页「上次位置」）
  static const String _keyWindowBounds = 'ui_window_bounds'; // 桌面窗口位置 / 大小 JSON
  static const String _keyNormalize = 'play_normalize';
  static const String _keyFadeSeconds = 'play_fade_seconds';
  static const String _keyAudioCacheLimitMb = 'cache_audio_limit_mb';

  // 媒体库（JSON 序列化的实体列表）
  static const String keyLibraryLikedTracks = 'lib_liked_tracks';
  static const String keyLibraryPlaylists = 'lib_playlists';
  static const String keyLibraryArtists = 'lib_artists';
  static const String keyLibraryAlbums = 'lib_albums';

  /// 用户在本机创建 / 保存的歌单（不随账号同步；远端 rootlist 歌单缓存在 [keyLibraryPlaylists]）。
  static const String keyLibraryLocalPlaylists = 'lib_playlists_local';

  /// 歌单备份落盘键（各备份账号及已落盘的收藏曲目 / 歌单快照）。
  static const String keyPlaylistBackups = 'backup_accounts_v1';
  static const String _keyLibraryAccount = 'lib_account'; // 媒体库缓存所属账号
  static const String _keyLibrarySchema = 'lib_schema'; // 缓存结构版本（旧版含示例数据）

  final SharedPreferences _prefs;

  StorageService(this._prefs);

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

  /// Retry on startup / before login if the WebView plugin could not clear its
  /// cookie store. Never silently reuse that store after a failed cleanup.
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
    // A previous disk write may have failed along with the cookie cleanup.
    await clearLogin();
    await clear();
    if (!await _prefs.remove('auth_cookie_cleanup_pending')) {
      throw StateError('无法保存 Cookie 清理状态');
    }
    _cookieCleanupNeeded = false;
  }

  /// Local-only reset. A late 401 from an earlier session cannot log out a new
  /// login; concurrent rejections share the same cleanup operation.
  Future<void> invalidateSession(int epoch) {
    if (_sessionCleanup != null) return _sessionCleanup!;
    if (epoch != _sessionEpoch) return Future.value();
    ++_sessionEpoch;
    final done = Completer<void>();
    _sessionCleanup = done.future;
    unawaited(() async {
      var notified = false;
      try {
        // Clear the in-memory preference cache synchronously before any await.
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
        // Credentials stay cleared; the durable marker blocks login until the
        // cookie store can be cleared. Keep the original HTTP error visible.
        if (!notified) sessionInvalidated.value++;
      } finally {
        _sessionCleanup = null;
        done.complete();
      }
    }());
    return done.future;
  }

  String get updateMode => _prefs.getString('update_mode') ?? 'manual';
  Future<bool> setUpdateMode(String value) => _prefs.setString('update_mode', value);
  String get skippedUpdate => _prefs.getString('update_skipped') ?? '';
  Future<bool> setSkippedUpdate(String value) => _prefs.setString('update_skipped', value);
  String get lastUpdateCheck => _prefs.getString('update_last_check') ?? '';
  Future<bool> setLastUpdateCheck(String value) => _prefs.setString('update_last_check', value);

  static Future<StorageService> init() async {
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService(prefs);
    await storage.ensureReceiverDeviceId();
    await storage.dropLegacySession();
    return storage;
  }

  /// An installation ID, independent of machine name and login/logout. Two
  /// devices with the same host name must not replace one another in Connect.
  String get receiverDeviceId =>
      _prefs.getString('connect_receiver_device_id') ?? '';

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

  /// 旧版本的 Login5 / 开发者应用会话已不受支持：清掉其令牌（否则残留的 access_token 仍会被当作已配置），
  /// 用户重新用浏览器登录即可。
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

  // ---------------------------------------------------------------------------
  // Tokens & Configuration
  // ---------------------------------------------------------------------------
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

  /// 手动代理的认证密码（敏感信息单独按键存放；用户名不敏感，在 AppPreferences JSON 里）。
  /// 空串表示代理不需要认证。
  String get proxyPassword => _prefs.getString(_keyProxyPassword) ?? '';
  Future<bool> setProxyPassword(String value) =>
      _prefs.setString(_keyProxyPassword, value);

  // ---------------------------------------------------------------------------
  // 会话
  // ---------------------------------------------------------------------------
  /// 设备 ID：首次访问时生成并持久化（由调用方传入生成器，避免此层依赖）。
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

  /// 当前 client-token 以哪种客户端身份申请（与登录方式不一致时需重新申请）。
  String get clientTokenProfile =>
      _prefs.getString(_keyClientTokenProfile) ?? '';
  Future<bool> setClientTokenProfile(String value) =>
      _prefs.setString(_keyClientTokenProfile, value);

  /// 标记当前凭据属于桌面版浏览器登录会话。
  Future<bool> markDesktopSession() =>
      _prefs.setString(_keyAuthMethod, _desktopSession);

  // --- Web 播放器会话（sp_dc + 铸造的 web access_token） ---

  /// open.spotify.com 的 sp_dc cookie（Web 登录捕获；Widevine 真密钥的 token 来源）。
  String get spDc => _prefs.getString(_keySpDc) ?? '';
  Future<bool> setSpDc(String value) => _prefs.setString(_keySpDc, value);

  /// 铸造的 Web 播放器 access_token（60 分钟有效，由 WebTokenService 自动续期）。
  String get webAccessToken => _prefs.getString(_keyWebAccessToken) ?? '';
  int get webAccessTokenExpiry => _prefs.getInt(_keyWebAccessTokenExpiry) ?? 0;
  Future<bool> setWebAccessToken(String token, int expiryMs) async {
    final results = await Future.wait([
      _prefs.setString(_keyWebAccessToken, token),
      _prefs.setInt(_keyWebAccessTokenExpiry, expiryMs),
    ]);
    return results.every((ok) => ok);
  }

  /// 清除 Web 会话（sp_dc + 铸造的 token）。
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

  /// 是否已登录：桌面版或 Web 统一会话且持有 refresh_token 或 sp_dc。
  bool get isLoggedIn =>
      _prefs.getString(_keyAuthMethod) == _desktopSession &&
      (refreshToken.isNotEmpty || spDc.isNotEmpty);

  /// 清除全部登录态（登出）。device_id 保留（client-token 与之绑定）。
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

  // ---------------------------------------------------------------------------
  // Playback preferences
  // ---------------------------------------------------------------------------
  double get volume => _prefs.getDouble(_keyVolume) ?? 0.8;
  Future<bool> setVolume(double value) => _prefs.setDouble(_keyVolume, value);

  /// 连续多首无法播放时自动暂停（默认开启）。
  bool get pauseAfterFailures => _prefs.getBool(_keyPauseAfterFailures) ?? true;
  Future<bool> setPauseAfterFailures(bool value) =>
      _prefs.setBool(_keyPauseAfterFailures, value);

  /// 沉浸式歌词是否进入系统全屏（铺满整个屏幕）；默认 false，只铺满窗口。
  bool get immersiveScreenFullscreen =>
      _prefs.getBool(_keyImmersiveScreen) ?? false;
  Future<bool> setImmersiveScreenFullscreen(bool value) =>
      _prefs.setBool(_keyImmersiveScreen, value);

  /// 沉浸式歌词是否固定控制区（不自动收成底部迷你栏）；默认 false。
  bool get immersivePinned => _prefs.getBool(_keyImmersivePinned) ?? false;
  Future<bool> setImmersivePinned(bool value) =>
      _prefs.setBool(_keyImmersivePinned, value);

  /// 外观设置（JSON 字符串，解析见 AppearanceSettings.fromJson）；未保存过为空串。
  String get appearanceJson => _prefs.getString(_keyAppearance) ?? '';
  Future<bool> setAppearanceJson(String value) =>
      _prefs.setString(_keyAppearance, value);

  /// 界面偏好（JSON 字符串，解析见 AppPreferences.decode）；未保存过为空串。
  String get preferencesJson => _prefs.getString(_keyPreferences) ?? '';
  Future<bool> setPreferencesJson(String value) =>
      _prefs.setString(_keyPreferences, value);

  /// 上次所在的主 Tab 下标（0 主页 / 1 搜索 / 2 音乐库）。
  int get lastTab => _prefs.getInt(_keyLastTab) ?? 0;
  Future<bool> setLastTab(int value) => _prefs.setInt(_keyLastTab, value);

  /// 桌面窗口位置与大小（JSON，见 WindowBoundsMemory）；未保存过为空串。
  String get windowBoundsJson => _prefs.getString(_keyWindowBounds) ?? '';
  Future<bool> setWindowBoundsJson(String value) =>
      _prefs.setString(_keyWindowBounds, value);

  /// 音量均衡（按 Spotify 响度数据衰减偏响的歌），默认关闭。
  bool get normalizeVolume => _prefs.getBool(_keyNormalize) ?? false;
  Future<bool> setNormalizeVolume(bool value) =>
      _prefs.setBool(_keyNormalize, value);

  /// 歌曲间淡入淡出时长（秒），0 为关闭。
  int get fadeSeconds => _prefs.getInt(_keyFadeSeconds) ?? 0;
  Future<bool> setFadeSeconds(int value) =>
      _prefs.setInt(_keyFadeSeconds, value);

  /// 音频缓存上限（MB），默认 512。
  int get audioCacheLimitMb => _prefs.getInt(_keyAudioCacheLimitMb) ?? 512;
  Future<bool> setAudioCacheLimitMb(int value) =>
      _prefs.setInt(_keyAudioCacheLimitMb, value);

  String get audioCacheDirectory =>
      _prefs.getString('cache_audio_directory') ?? '';
  Future<bool> setAudioCacheDirectory(String value) =>
      _prefs.setString('cache_audio_directory', value);

  String? get cacheDirectory => _prefs.getString('cache_directory');
  String get cacheLocationsJson => _prefs.getString('cache_locations_v2') ?? '';
  Future<bool> setCacheLocationsJson(String value) =>
      _prefs.setString('cache_locations_v2', value);
  Future<bool> setCacheDirectory(String value) =>
      _prefs.setString('cache_directory', value);
  List<String> get previousCacheRoots =>
      _prefs.getStringList('cache_previous_roots') ?? const [];
  Future<bool> setPreviousCacheRoots(List<String> roots) =>
      _prefs.setStringList('cache_previous_roots', roots);

  // ---------------------------------------------------------------------------
  // Generic JSON list persistence (used by LibraryProvider)
  // ---------------------------------------------------------------------------
  bool hasKey(String key) => _prefs.containsKey(key);

  Future<bool> removeKey(String key) => _prefs.remove(key);

  /// 媒体库缓存所属账号（canonical username）；账号变化时缓存作废。
  String get libraryAccount => _prefs.getString(_keyLibraryAccount) ?? '';
  Future<bool> setLibraryAccount(String value) =>
      _prefs.setString(_keyLibraryAccount, value);

  /// 媒体库缓存结构版本：低于当前版本说明缓存来自带示例数据的旧版，需要迁移。
  int get librarySchema => _prefs.getInt(_keyLibrarySchema) ?? 0;
  Future<bool> setLibrarySchema(int value) =>
      _prefs.setInt(_keyLibrarySchema, value);

  /// 读取 JSON 对象列表；单条损坏的数据会被跳过而不是让整个列表失效。
  List<Map<String, dynamic>> readJsonList(String key) {
    final raw = _prefs.getStringList(key);
    if (raw == null) return const [];
    final result = <Map<String, dynamic>>[];
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) result.add(decoded);
      } catch (_) {}
    }
    return result;
  }

  Future<bool> writeJsonList(String key, Iterable<Map<String, dynamic>> items) {
    return _prefs.setStringList(key, items.map(jsonEncode).toList());
  }

  // ---------------------------------------------------------------------------
  // Search History
  // ---------------------------------------------------------------------------
  List<String> get recentSearches =>
      _prefs.getStringList(_keyRecentSearches) ?? [];
  Future<bool> addRecentSearch(String query) {
    final clean = query.trim();
    if (clean.isEmpty) return Future.value(false);
    final list = recentSearches;
    list.remove(clean);
    list.insert(0, clean);
    if (list.length > 20) list.removeLast();
    return _prefs.setStringList(_keyRecentSearches, list);
  }

  Future<bool> removeRecentSearch(String query) {
    final list = recentSearches..remove(query);
    return _prefs.setStringList(_keyRecentSearches, list);
  }

  Future<bool> clearRecentSearches() => _prefs.remove(_keyRecentSearches);
}
