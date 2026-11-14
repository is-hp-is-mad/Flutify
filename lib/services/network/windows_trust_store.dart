import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart uses bundled roots on Windows, while WebView2 uses Windows trust.
/// Add system-trusted roots before creating clients; never bypass TLS checks.
class WindowsTrustStore {
  static const channel = MethodChannel('flutify/windows_trust_store');

  static Future<void> initialize() async {
    if (!Platform.isWindows) return;
    await loadInto(SecurityContext.defaultContext);
  }

  static final Set<String> _asked = {};

  /// 握手被拒绝的证书交给 Windows 再判断一次：系统信任这条链时，把它的根证书补进 [context]。
  ///
  /// Windows 的根证书按需下载，[initialize] 只能读到本机已经用过的那些；
  /// 缺的那一个（issue #53 里是 Starfield G2）会让 Spotify 的所有请求握手失败，而同一台机器上的
  /// 浏览器 / WebView2 是好的。这里不放行本次连接（握手回调必须同步返回），根补上之后重试即可通过。
  /// 返回是否补上了新的根；同一张证书只问一次。
  static Future<bool> learnRootFor(
    X509Certificate certificate, {
    SecurityContext? context,
  }) async {
    if (!Platform.isWindows && context == null) return false;
    if (!_asked.add(base64Encode(certificate.sha1))) return false;
    try {
      final root = await channel.invokeMethod<Uint8List>(
        'rootFor',
        certificate.der,
      );
      if (root == null || root.isEmpty) {
        debugPrint('[TLS] Windows 也不信任这条证书链，保持拒绝');
        return false;
      }
      final pem =
          '-----BEGIN CERTIFICATE-----\n'
          '${base64Encode(root)}\n-----END CERTIFICATE-----\n';
      (context ?? SecurityContext.defaultContext).setTrustedCertificatesBytes(
        utf8.encode(pem),
      );
      debugPrint('[TLS] 已从 Windows 补入一个根证书，重试即可连接');
      return true;
    } on TlsException {
      debugPrint('[TLS] Windows 给出的根证书无法导入');
    } on PlatformException catch (e) {
      debugPrint('[TLS] 查询 Windows 证书链失败（${e.code}）');
    } on MissingPluginException {
      // 旧版 runner / 测试环境没有这个方法
    }
    return false;
  }

  @visibleForTesting
  static void resetLearned() => _asked.clear();

  @visibleForTesting
  static Future<int> loadInto(SecurityContext context) async {
    var loaded = 0;
    try {
      final certificates = await channel.invokeListMethod<Uint8List>('roots');
      for (final der in certificates ?? <Uint8List>[]) {
        try {
          final pem =
              '-----BEGIN CERTIFICATE-----\n'
              '${base64Encode(der)}\n-----END CERTIFICATE-----\n';
          context.setTrustedCertificatesBytes(utf8.encode(pem));
          loaded++;
        } on TlsException {
          // An unsupported system certificate must not discard the other roots.
          debugPrint('[TLS] Skipped an unsupported Windows root certificate');
        }
      }
      debugPrint('[TLS] Loaded $loaded Windows root certificates');
    } on PlatformException catch (e) {
      debugPrint(
        '[TLS] Windows roots unavailable (${e.code}); using Dart roots',
      );
    } on MissingPluginException {
      debugPrint('[TLS] Windows trust channel unavailable; using Dart roots');
    }
    return loaded;
  }
}
