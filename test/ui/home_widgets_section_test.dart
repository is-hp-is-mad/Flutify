import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/services/widget/widget_bridge.dart';
import 'package:flutify_app/ui/screens/settings/sections/home_widgets_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  const channel = MethodChannel('flutify/widget_bridge');

  Widget app(WidgetBridge? bridge) => Provider<WidgetBridge?>.value(
    value: bridge,
    child: const MaterialApp(
      locale: Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: HomeWidgetsSection())),
    ),
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('没有小组件桥（非 Android）时不显示分组', (tester) async {
    await tester.pumpWidget(app(null));
    expect(find.text('桌面小组件'), findsNothing);
  });

  testWidgets('列出 4 款，点一款请求添加；桌面不支持时提示去小组件列表加', (tester) async {
    final pins = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'requestPin') return null;
          pins.add(call.arguments);
          return call.arguments == 'albumCard';
        });
    await tester.pumpWidget(app(WidgetBridge(artworkFile: (_) async => null)));

    expect(find.text('桌面小组件'), findsOneWidget);
    for (final name in ['播放条', '专辑卡片', '方形封面', '待播清单']) {
      expect(find.text(name), findsOneWidget);
    }

    await tester.tap(find.text('专辑卡片'));
    await tester.pumpAndSettle();
    expect(pins, ['albumCard']);
    expect(find.text('当前桌面不支持从应用内添加，请长按桌面在小组件列表里添加'), findsNothing);

    await tester.tap(find.text('待播清单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(pins, ['albumCard', 'upNext']);
    expect(find.text('当前桌面不支持从应用内添加，请长按桌面在小组件列表里添加'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });
}
