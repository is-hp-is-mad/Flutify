import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_glass/hyper_ui.dart';

void main() {
  Future<List<int>> pump(WidgetTester tester) async {
    final changes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 306,
            height: 56,
            child: HyperBottomBar(
              index: 0,
              onChanged: changes.add,
              surface: (child) => child,
              items: const [
                HyperBottomBarItem('a', Icons.home_outlined, Icons.home),
                HyperBottomBarItem('b', Icons.search, Icons.search),
                HyperBottomBarItem('c', Icons.star_border, Icons.star),
              ],
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('拖动胶囊切换 tab，松手时落到最近的一项', (tester) async {
    final changes = await pump(tester);
    await tester.drag(find.text('a'), const Offset(210, 0));
    await tester.pump();
    expect(changes, [2]);
  });

  testWidgets('拖动距离不足一半时回到原位，不切换', (tester) async {
    final changes = await pump(tester);
    await tester.drag(find.text('a'), const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
  });

  testWidgets('点击仍然切换', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('b'));
    expect(changes, [1]);
  });
}
