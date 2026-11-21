import 'package:flutify_app/ui/widgets/flutify_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('长内容在矮窗口里可滚动，按钮仍可见', (tester) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlutifyDialog(
            icon: const Icon(Icons.download_done_rounded),
            title: '更新已就绪',
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 60; i++) Text('line $i'),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () {}, child: const Text('稍后')),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final action = find.text('稍后');
    expect(action, findsOneWidget);
    expect(tester.getBottomLeft(action).dy, lessThanOrEqualTo(500));
    expect(find.text('line 59').hitTestable(), findsNothing);

    await tester.dragUntilVisible(
      find.text('line 59'),
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    expect(find.text('line 59').hitTestable(), findsOneWidget);
  });

  testWidgets('短内容按内容高度显示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FlutifyDialog(title: '标题', content: Text('正文')),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final surface = find
        .descendant(of: find.byType(FlutifyDialog), matching: find.byType(Container))
        .first;
    expect(tester.getSize(surface).height, lessThan(300));
  });

  testWidgets('键盘弹起时对话框整体上移，输入框与按钮不被遮挡', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: FlutifyDialog(
          title: '反代',
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 6; i++) const SizedBox(height: 40),
                const TextField(key: ValueKey('field')),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () {}, child: const Text('应用'))],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(find.text('应用')).dy, lessThanOrEqualTo(440));

    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('field'))).dy,
      lessThanOrEqualTo(440),
    );
  });
}
