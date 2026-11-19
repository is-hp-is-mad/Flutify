import 'dart:async';

import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/services/auth/web_token_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/auth/web_login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Cookie 清理完成前不创建 WebView，失败可重试，关页后不再创建', (tester) async {
    SharedPreferences.setMockInitialValues({
      'auth_cookie_cleanup_pending': true,
    });
    final storage = await StorageService.init();
    var cleanup = Completer<void>();
    var calls = 0;
    storage.auth.clearWebViewCookies = () {
      calls++;
      return cleanup.future;
    };
    await tester.pumpWidget(
      Provider<WebTokenService>.value(
        value: WebTokenService(storage.auth),
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: AppLocale.delegates,
          home: const WebLoginScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(InAppWebView), findsNothing);
    cleanup.completeError(StateError('plugin unavailable'));
    await tester.pump();
    await tester.pump();
    expect(find.text('WebView Cookie 清理失败，请重试'), findsOneWidget);
    expect(find.byType(InAppWebView), findsNothing);
    cleanup = Completer<void>();
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(calls, 2);
    expect(find.byType(InAppWebView), findsNothing);
    await tester.pumpWidget(const SizedBox());
    cleanup.complete();
    await tester.pump();
    expect(find.byType(InAppWebView), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
