import 'package:flutify_app/l10n/app_locale.dart';
import 'package:flutify_app/services/auth/login_region_check.dart';
import 'package:flutify_app/services/auth/web_token_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/auth/web_login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('出口在中国大陆：不创建 WebView，提示后可以重新检测', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    var probes = 0;
    await tester.pumpWidget(
      Provider<WebTokenService>.value(
        value: WebTokenService(storage),
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocale.supportedLocales,
          localizationsDelegates: AppLocale.delegates,
          home: WebLoginScreen(
            regionProbe: () async {
              probes++;
              return const LoginRegion('CN');
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    expect(probes, 1);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.text('当前网络出口位于中国大陆'), findsOneWidget);
    expect(find.text('CN'), findsOneWidget);
    expect(find.text('重新检测'), findsOneWidget);
    expect(find.text('强制跳过'), findsOneWidget);

    // 重新检测仍是大陆出口：继续停在提示页，没有创建 WebView
    await tester.tap(find.text('重新检测'));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(probes, 2);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.text('当前网络出口位于中国大陆'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
