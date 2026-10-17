import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/platform/flutify_platform.dart';

/// 登录前的网络出口地区检测结果。
@immutable
class LoginRegion {
  const LoginRegion(this.code);

  /// 检测不到（网络不通、所有端点失败、测试环境、平台没有内嵌 WebView）。
  const LoginRegion.unknown() : code = null;

  /// 两位大写国家 / 地区代码；未检测到为 null。
  final String? code;

  bool get detected => code != null;

  /// 出口在中国大陆（loc=CN）。香港 HK、澳门 MO、台湾 TW 不算。
  bool get isMainlandChina => code == 'CN';
}

/// 从 Cloudflare `/cdn-cgi/trace` 的文本里取出 `loc=XX`；取不到返回 null。
String? parseTraceCountry(String? text) {
  if (text == null) return null;
  final match = RegExp(
    r'^loc=([A-Za-z]{2})\s*$',
    multiLine: true,
  ).firstMatch(text);
  return match?.group(1)?.toUpperCase();
}

typedef LoginRegionProbe = Future<LoginRegion> Function();

/// 登录页加载之前先确认当前网络出口的国家 / 地区。
///
/// 检测放在 **WebView 里**执行：用无头 WebView 打开 Cloudflare 的 trace 页，再在页面里跑脚本
/// 读出文本。这样请求走的是和登录页完全相同的网络路径（系统代理 / VPN / Android 网络访问
/// 控制），而不是 Dart 的 HttpClient，两者出口不一致时 Dart 侧的结果会不准，甚至被系统拦掉。
///
/// 任何失败（超时、插件不可用、页面打不开）都按「未知」处理，不拦截登录。
class LoginRegionCheck {
  LoginRegionCheck._();

  /// 依次尝试，取第一个成功读到国家代码的结果。
  static const List<String> endpoints = [
    'https://www.cloudflare.com/cdn-cgi/trace',
    'https://cloudflare.com/cdn-cgi/trace',
    'https://1.1.1.1/cdn-cgi/trace',
  ];

  /// 在页面里执行的脚本：返回 trace 文本（text/plain 页面会被浏览器包进 `<pre>`）。
  static const String readPageScript =
      "(document.body ? document.body.innerText : '') || "
      "(document.documentElement ? document.documentElement.innerText : '') || ''";

  static Future<LoginRegion> detect({
    WebViewEnvironment? environment,
    List<String> urls = endpoints,
    Duration perEndpoint = const Duration(seconds: 8),
  }) async {
    if (FlutifyPlatform.isTest || !FlutifyPlatform.supportsInAppWebView) {
      return const LoginRegion.unknown();
    }
    for (final url in urls) {
      final code = await _probe(url, environment, perEndpoint);
      if (code != null) return LoginRegion(code);
    }
    return const LoginRegion.unknown();
  }

  static Future<String?> _probe(
    String url,
    WebViewEnvironment? environment,
    Duration timeout,
  ) async {
    final result = Completer<String?>();
    void finish(String? value) {
      if (!result.isCompleted) result.complete(value);
    }

    HeadlessInAppWebView? view;
    try {
      view = HeadlessInAppWebView(
        // 与登录页共用同一个环境：同一用户数据目录只允许一个 WebView2 环境实例
        webViewEnvironment: environment,
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          cacheEnabled: false,
          clearCache: true,
        ),
        onLoadStop: (controller, _) async {
          if (result.isCompleted) return;
          try {
            final text = await controller.evaluateJavascript(
              source: readPageScript,
            );
            finish(parseTraceCountry(text?.toString()));
          } catch (_) {
            finish(null);
          }
        },
        onReceivedError: (_, request, _) {
          // 只有主页面失败才算这个端点失败；子资源（如 favicon）失败不影响
          if (request.isForMainFrame == false) return;
          finish(null);
        },
      );
      await view.run();
      return await result.future.timeout(timeout, onTimeout: () => null);
    } catch (e) {
      debugPrint('[login-region] $url 检测失败: $e');
      return null;
    } finally {
      try {
        await view?.dispose();
      } catch (_) {}
    }
  }
}
