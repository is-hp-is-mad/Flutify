import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutify_app/ui/shell/shell_chrome.dart';

void main() {
  testWidgets('页面底色只在本页是当前页时上报，离开后撤回', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    const color = Color(0xFF3A1F2B);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('home')),
      ),
    );
    final navigator = navigatorKey.currentState!;
    final chrome = ShellChrome.instance;
    expect(chrome.backdropFor(navigator), isNull);

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const ShellBackdrop(color: color, child: Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    expect(chrome.backdropFor(navigator), color);

    // 上面再压一页：底色撤回
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(chrome.backdropFor(navigator), isNull);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(chrome.backdropFor(navigator), color);

    navigator.pop();
    await tester.pumpAndSettle();
    expect(chrome.backdropFor(navigator), isNull);
  });
}
