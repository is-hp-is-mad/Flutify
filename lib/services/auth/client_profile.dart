import 'dart:io';

import 'auth_constants.dart';
import 'proto_codec.dart';

/// 向 Spotify 声明的客户端身份。
///
/// 令牌、client-token 与业务请求头必须属于同一个客户端，否则内部接口拒绝请求。
/// - [web]：Web 播放器（open.spotify.com），登录态（sp_dc 铸造的令牌）所属身份，业务请求都用它；
/// - [desktop]：Windows 桌面端，只剩 AP（接入点）协议握手使用。
enum SpotifyClientProfile {
  /// Windows 桌面端（AP 协议握手）。
  desktop,

  /// Web 播放器：Web 登录铸造的令牌所属身份。
  web;

  String get clientId => switch (this) {
    desktop => SpotifyAuthConstants.desktopClientId,
    web => SpotifyAuthConstants.webClientId,
  };

  /// client-token 请求中的 client_version。
  String get clientVersion => switch (this) {
    desktop => SpotifyAuthConstants.desktopVersion,
    web => SpotifyAuthConstants.webClientVersion,
  };

  String get userAgent => switch (this) {
    desktop => SpotifyAuthConstants.desktopUserAgent,
    web => SpotifyAuthConstants.webUserAgent,
  };

  /// 访问内部接口（spclient / identity 等）时附带的客户端头。键统一小写，便于调用方覆盖。
  Map<String, String> get headers => switch (this) {
    desktop => const {
      'app-platform': SpotifyAuthConstants.desktopPlatform,
      'spotify-app-version': SpotifyAuthConstants.desktopVersion,
    },
    web => const {
      'app-platform': SpotifyAuthConstants.webPlatform,
      'spotify-app-version': SpotifyAuthConstants.webClientVersion,
      'origin': 'https://open.spotify.com',
      'referer': 'https://open.spotify.com/',
    },
  };

  /// Web 播放器 client-token 请求里的 js_sdk_data（对齐 web-player 前端：未定义的字段不发送）。
  Map<String, String> jsSdkData(String deviceId) => {
    'device_brand': 'unknown',
    'device_model': 'unknown',
    'os': 'windows',
    'os_version': 'NT 10.0',
    'device_id': deviceId,
    'device_type': 'computer',
  };

  /// AP keyexchange.proto BuildInfo，与桌面 HTTP 配置共用版本。
  ProtoWriter apBuildInfo() => ProtoWriter()
    ..varintAlways(10, 0) // PRODUCT_CLIENT（proto2 required）
    ..varintAlways(20, 0) // PRODUCT_FLAG_NONE
    ..varintAlways(30, 0x27) // PLATFORM_WIN32_X86_64
    ..int64(40, int.parse(SpotifyAuthConstants.desktopBuildNumber));

  /// AP authentication.proto SystemInfo，使用同一声明的平台。
  /// 可选的 system_information_string 不发送应用名或计算机名。
  ProtoWriter apSystemInfo(String? deviceId) => ProtoWriter()
    ..varintAlways(10, 2) // CPU_X86_64
    ..varintAlways(60, 1) // OS_WINDOWS
    ..string(100, deviceId ?? '');

  /// 写入 ConnectivitySdkData.platform_specific_data 的 desktop_windows=4（NativeDesktopWindowsData），
  /// 字段取值对齐 librespot（x64 进程）。
  ProtoWriter platformData() => ProtoWriter()
    ..message(
      4,
      ProtoWriter()
        ..int32(1, 10) // os_version：Windows 10/11 均报告 10
        ..int32(3, _windowsBuild()) // os_build
        ..int32(4, 2) // platform_id：VER_PLATFORM_WIN32_NT
        ..int32(6, 9) // unknown_value_6
        ..int32(7, 332) // image_file_machine：IMAGE_FILE_MACHINE_I386
        ..int32(8, 34404) // pe_machine：IMAGE_FILE_MACHINE_AMD64
        ..boolValue(10, true), // unknown_value_10
    );

  /// 本机 Windows 构建号（如 26200）；非 Windows 或解析失败时用 Windows 10 22H2 的 19045。
  static int _windowsBuild() {
    if (!Platform.isWindows) return 19045;
    final match = RegExp(
      r'Build (\d+)',
    ).firstMatch(Platform.operatingSystemVersion);
    return int.tryParse(match?.group(1) ?? '') ?? 19045;
  }
}
