import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统里点开的 `spotify:` / `open.spotify.com` 链接（Windows、Android、macOS、Linux）。
///
/// 原生侧负责注册与转发：
/// - Windows：windows/runner/protocol_handler.cpp（HKCU 注册 + 单实例 WM_COPYDATA 转发）；
/// - Android：SpotifyLinkPlugin.kt（intent-filter + singleTask 的 onNewIntent）；
/// - macOS：Info.plist CFBundleURLTypes + AppDelegate 的 kAEGetURL（系统本身单实例）；
/// - Linux：.desktop 的 x-scheme-handler/spotify + GApplication 单实例的 open 转发。
/// 启动参数里的链接经 `initialLink` 取一次，运行中其他实例转发来的链接经 `openLink` 推送。
class SpotifyLinkHandler {
  SpotifyLinkHandler._();

  static const MethodChannel _channel = MethodChannel('flutify/protocol');

  static bool get isSupported =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isAndroid ||
          Platform.isMacOS ||
          Platform.isLinux);

  /// 能否在应用内「设为默认」：仅 Windows；Android 由系统的打开方式选择器决定。
  static bool get canSetDefault => !kIsWeb && Platform.isWindows;

  static void Function(String link)? _onLink;

  /// 没有主界面接收时（如未登录）到达的链接，等下次 [attach] 再投递。
  static String? _pending;

  static void _deliver(String link) {
    final onLink = _onLink;
    if (onLink == null) {
      _pending = link;
    } else {
      onLink(link);
    }
  }

  /// 主界面就绪后调用：之后到达的链接交给 [onLink]；启动参数里的链接立即投递一次。
  /// 主界面重建（如重新登录）时再次调用即可替换回调。
  static Future<void> attach(void Function(String link) onLink) async {
    if (!isSupported) return;
    _onLink = onLink;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openLink' && call.arguments is String) {
        _deliver(call.arguments as String);
      }
    });
    try {
      final initial = await _channel.invokeMethod<String>('initialLink');
      if (initial != null && initial.isNotEmpty) _deliver(initial);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
    final pending = _pending;
    _pending = null;
    if (pending != null) _deliver(pending);
  }

  /// 主界面销毁时调用；只在回调仍是自己时清除，避免误删新界面的回调。
  static void detach(void Function(String link) onLink) {
    if (_onLink == onLink) _onLink = null;
  }

  /// 系统当前用谁打开 `spotify:` 链接。
  static Future<SpotifyLinkStatus?> status() async {
    if (!canSetDefault) return null;
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      if (map == null) return null;
      return SpotifyLinkStatus(
        isDefault: map['isDefault'] == true,
        otherHandler: (map['otherHandler'] as String?) ?? '',
      );
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      return null;
    }
  }

  /// 设为默认（备份原处理程序）或恢复原处理程序。
  static Future<SpotifyLinkSetResult> setDefault(bool enable) async {
    if (!canSetDefault) return SpotifyLinkSetResult.failed;
    try {
      final result = await _channel.invokeMethod<String>('setDefault', enable);
      return switch (result) {
        'ok' => SpotifyLinkSetResult.ok,
        'userChoice' => SpotifyLinkSetResult.needsSystemSettings,
        _ => SpotifyLinkSetResult.failed,
      };
    } on PlatformException catch (_) {
      return SpotifyLinkSetResult.failed;
    } on MissingPluginException catch (_) {
      return SpotifyLinkSetResult.failed;
    }
  }
}

@immutable
class SpotifyLinkStatus {
  final bool isDefault;

  /// 不是 Flutify 时，当前处理程序的可执行文件名（如 `Spotify.exe`）；没有则为空。
  final String otherHandler;

  const SpotifyLinkStatus({required this.isDefault, required this.otherHandler});
}

enum SpotifyLinkSetResult {
  ok,

  /// 用户在 Windows「默认应用」里为 spotify: 选过别的程序：只能去系统设置里改。
  needsSystemSettings,
  failed,
}
