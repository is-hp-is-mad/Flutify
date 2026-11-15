import 'package:flutify_app/ui/shell/shell_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 外壳边框开关：按 Tab Navigator 记录隐藏请求，只影响请求所在的 Tab。
void main() {
  testWidgets('隐藏请求只作用于所在 Tab，撤回后恢复', (tester) async {
    final tabA = GlobalKey<NavigatorState>();
    final tabB = GlobalKey<NavigatorState>();
    Widget nav(GlobalKey<NavigatorState> key) => Navigator(
      key: key,
      onGenerateRoute: (_) =>
          MaterialPageRoute(builder: (_) => const SizedBox()),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            Expanded(child: nav(tabA)),
            Expanded(child: nav(tabB)),
          ],
        ),
      ),
    );
    final chrome = ShellChrome.instance;
    final owner = Object();
    var notified = 0;
    void listener() => notified++;
    chrome.addListener(listener);
    addTearDown(() {
      chrome.removeListener(listener);
      chrome.request(owner, null, hide: false);
    });

    chrome.request(owner, tabA.currentState, hide: true);
    expect(chrome.hiddenFor(tabA.currentState), isTrue);
    expect(chrome.hiddenFor(tabB.currentState), isFalse);
    expect(notified, 1);

    chrome.request(owner, tabA.currentState, hide: true);
    expect(notified, 1, reason: '重复请求不通知');

    chrome.request(owner, tabA.currentState, hide: false);
    expect(chrome.hiddenFor(tabA.currentState), isFalse);
    expect(notified, 2);
  });
}
