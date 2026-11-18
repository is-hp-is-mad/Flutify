import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 登录 WebView 异常请求脱敏日志工具：
/// - 记录网络/HTTP 错误码、请求方法、主框架标记、脱敏后的 URL 路径与响应体片段；
/// - 绝不输出 Cookie、Authorization、Bearer、sp_dc、access/refresh token、邮箱密码等隐私字段。
class WebViewErrorLogger {
  WebViewErrorLogger._();

  static final RegExp _sensitiveQueryKey = RegExp(
    r'^(code|token|access_token|refresh_token|id_token|client_token|sp_dc|state|sig|signature|nonce|verifier|code_verifier|code_challenge|challenge|session|cookie|secret|password|pass|pwd|auth|key|api_key|email|username|flow_ctx)$',
    caseSensitive: false,
  );

  static final RegExp _bearerRe = RegExp(
    r'Bearer\s+[A-Za-z0-9\-._~+/]+=*',
    caseSensitive: false,
  );

  static final RegExp _cookieAssignRe = RegExp(
    r'\b(sp_dc|sp_key|sp_t|sp_landing|cookie|set-cookie|authorization|x-csrf-token)\s*[:=]\s*[^\s;,&"]+',
    caseSensitive: false,
  );

  static final RegExp _jsonSecretRe = RegExp(
    r'"(access_token|refresh_token|id_token|client_token|sp_dc|password|secret|email|csrf_token|token)"\s*:\s*"[^"]*"',
    caseSensitive: false,
  );

  /// 脱敏 URL：保留 `scheme://host[:port]/path`，敏感查询参数值替换为 `<redacted>`，其余过长值截断。
  static String sanitizeUrl(String? raw) {
    if (raw == null || raw.isEmpty) return '<empty>';
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) {
      return raw.split('?').first;
    }
    final base = StringBuffer()..write(uri.scheme);
    if (uri.hasAuthority) {
      base.write('://');
      base.write(uri.host);
      if (uri.hasPort) {
        base.write(':${uri.port}');
      }
    } else {
      base.write(':');
    }
    base.write(uri.path);
    if (uri.queryParametersAll.isEmpty) {
      return base.toString();
    }
    final sanitizedParams = <String>[];
    uri.queryParametersAll.forEach((key, values) {
      for (final value in values) {
        if (_sensitiveQueryKey.hasMatch(key)) {
          sanitizedParams.add('$key=<redacted>');
        } else if (value.length > 48) {
          sanitizedParams.add('$key=${value.substring(0, 48)}...');
        } else {
          sanitizedParams.add('$key=$value');
        }
      }
    });
    return '$base?${sanitizedParams.join('&')}';
  }

  /// 脱敏响应体：剥离常见凭据与隐私字段并截断长度。
  static String sanitizeBody(Uint8List? data, {int maxChars = 600}) {
    if (data == null || data.isEmpty) return '<empty>';
    var text = utf8.decode(data, allowMalformed: true);
    text = text
        .replaceAll(_bearerRe, 'Bearer <redacted>')
        .replaceAllMapped(_cookieAssignRe, (m) => '${m.group(1)}=<redacted>')
        .replaceAllMapped(
          _jsonSecretRe,
          (m) => '"${m.group(1)}":"<redacted>"',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return '<empty>';
    if (text.length > maxChars) {
      return '${text.substring(0, maxChars)}...(truncated ${text.length}B)';
    }
    return text;
  }

  static void logResourceError({
    required String scope,
    required WebResourceRequest request,
    required WebResourceError error,
  }) {
    final method = request.method ?? 'GET';
    final mainFrame = request.isForMainFrame ?? false;
    final url = sanitizeUrl(request.url.toString());
    final desc = error.description.replaceAll(RegExp(r'\s+'), ' ').trim();
    debugPrint(
      '[$scope] WebView 请求失败: type=${error.type} '
      'mainFrame=$mainFrame $method $url | desc=$desc',
    );
  }

  static void logHttpError({
    required String scope,
    required WebResourceRequest request,
    required WebResourceResponse errorResponse,
  }) {
    final method = request.method ?? 'GET';
    final mainFrame = request.isForMainFrame ?? false;
    final url = sanitizeUrl(request.url.toString());
    final status = errorResponse.statusCode;
    final reason = (errorResponse.reasonPhrase ?? '').trim();
    final contentType = (errorResponse.contentType ?? '').trim();
    final body = sanitizeBody(errorResponse.data);
    debugPrint(
      '[$scope] WebView HTTP 错误: status=$status '
      '${reason.isEmpty ? '' : '($reason) '}mainFrame=$mainFrame '
      '$method $url'
      '${contentType.isEmpty ? '' : ' | type=$contentType'}'
      ' | body=$body',
    );
  }

  static void logConsoleError({
    required String scope,
    required ConsoleMessage message,
  }) {
    if (message.messageLevel != ConsoleMessageLevel.ERROR) return;
    final text = message.message
        .replaceAll(_bearerRe, 'Bearer <redacted>')
        .replaceAllMapped(_cookieAssignRe, (m) => '${m.group(1)}=<redacted>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return;
    final clipped = text.length > 400 ? '${text.substring(0, 400)}...' : text;
    debugPrint('[$scope] WebView console.error: $clipped');
  }
}
