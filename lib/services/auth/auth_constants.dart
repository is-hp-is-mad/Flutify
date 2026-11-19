import 'dart:io';
import 'dart:math';

/// Spotify 鉴权链路的常量与设备标识。
///
/// 桌面 OAuth / AP 使用 Windows 桌面配置，Web 播放使用独立配置和令牌。
/// 桌面版本统一用于 client-token、User-Agent 和 AP 握手 / 登录。
class SpotifyAuthConstants {
  SpotifyAuthConstants._();

  static const bool _isWeb = bool.fromEnvironment('dart.library.js_util');

  /// 桌面版 OAuth 使用的 client_id（官方桌面客户端 / librespot OAuth 同款，来自 librespot config.rs）。
  static const String desktopClientId = '65b708073fc0480ea92a077233ca87bd';

  // 版本信息（Windows 桌面端，对应 Spotify.exe 1.3.1.234）
  static const String desktopVersion = '1.3.1.234.g59d6bf59';

  /// 桌面端数字版本号：主.次.修订(2 位).构建(5 位) 拼接，如 1.3.1.234 → 130100234。
  static const String desktopBuildNumber = '130100234';
  static const String desktopPlatform = 'Win32_x86_64';
  static const String desktopUserAgent = 'Spotify/$desktopBuildNumber $desktopPlatform/0 (PC desktop)';

  // 端点
  /// Web 播放器（open.spotify.com）身份：client_id 取自 web-player 前端包，
  /// 版本号取自首页内嵌的 appServerConfig.clientVersion（2026-10-23 构建）。
  static const String webClientId = 'd8a5ed958d274c2e8ee717e6a4b0971d';
  static const String webClientVersion = '1.3.8.509.g26b6eac7300d';
  static const String webPlatform = 'WebPlayer';

  static const String windowsWebUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';
  static const String macosWebUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';
  static const String linuxWebUserAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';
  static const String androidWebUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  static String get _currentOs => _isWeb ? 'windows' : Platform.operatingSystem;

  /// 按当前运行平台返回对应的 Web 浏览器 UA（与 Rust `spotify_session::web_user_agent` 对齐）。
  static String get webUserAgent => webUserAgentForPlatform(_currentOs);

  /// 按指定平台名（`android` / `macos` / `linux` / `windows`）返回对应的 Web 浏览器 UA。
  static String webUserAgentForPlatform(String operatingSystem) => switch (operatingSystem) {
    'android' => androidWebUserAgent,
    'macos' => macosWebUserAgent,
    'linux' => linuxWebUserAgent,
    _ => windowsWebUserAgent,
  };

  /// 精简非 Chrome UA（用于拉取 `open.spotify.com` 播客 SSR 页面内嵌的 `initialState`），仍按当前平台匹配 OS。
  static String get podcastUserAgent => podcastUserAgentForPlatform(_currentOs);

  static String podcastUserAgentForPlatform(String operatingSystem) => switch (operatingSystem) {
    'android' => 'Mozilla/5.0 (Linux; Android 14; Mobile)',
    'macos' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
    'linux' => 'Mozilla/5.0 (X11; Linux x86_64)',
    _ => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
  };

  /// Web 播放器 `client-token` 请求中的平台字段，与当前 OS 及 UA 保持一致。
  static ({String os, String osVersion, String deviceType}) get jsSdkPlatform =>
      jsSdkPlatformFor(_currentOs);

  static ({String os, String osVersion, String deviceType}) jsSdkPlatformFor(
    String operatingSystem,
  ) => switch (operatingSystem) {
    'android' => (os: 'android', osVersion: '14', deviceType: 'smartphone'),
    'macos' => (os: 'osx', osVersion: '10.15.7', deviceType: 'computer'),
    'linux' => (os: 'linux', osVersion: 'x86_64', deviceType: 'computer'),
    _ => (os: 'windows', osVersion: 'NT 10.0', deviceType: 'computer'),
  };

  /// `track-playback/v1/devices` 注册请求中的 `platform_identifier`，与当前 OS 及 UA 对齐。
  static String get webPlatformIdentifier => webPlatformIdentifierFor(_currentOs);

  static String webPlatformIdentifierFor(String operatingSystem) => switch (operatingSystem) {
    'android' => 'web_player android 14;chrome 131.0.0.0;mobile',
    'macos' => 'web_player osx 10.15.7;chrome 154.0.0.0;desktop',
    'linux' => 'web_player linux x86_64;chrome 154.0.0.0;desktop',
    _ => 'web_player windows 10;chrome 154.0.0.0;desktop',
  };

  /// 清洗 Android WebView 默认 UA（去掉 `; wv` 与 `Version/x.y` 标记），使其与真实 Chromium Client Hints 一致。
  static String cleanAndroidWebViewUserAgent(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return androidWebUserAgent;
    final cleaned = trimmed
        .replaceAll(RegExp(r';\s*wv\b|\bwv;\s*'), '')
        .replaceAll(RegExp(r'\bVersion/\d+(?:\.\d+)*\s+'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return cleaned.isEmpty ? androidWebUserAgent : cleaned;
  }

  static const String clientTokenEndpoint = 'https://clienttoken.spotify.com/v1/clienttoken';

  /// 生成 40 位十六进制的设备 ID（Spotify device_id 格式）。
  static String generateDeviceId() {
    final rnd = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 40; i++) {
      sb.write(rnd.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }
}
