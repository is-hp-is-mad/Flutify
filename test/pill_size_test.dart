// 测量 FilterPill 在「主页标签栏」与「侧栏筛选行」两种上下文中的实际渲染高度。
import 'package:flutify_app/ui/screens/home/widgets/home_chip_bar.dart';
import 'package:flutify_app/ui/widgets/filter_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FilterPill renders the same size in chip bar and sidebar row', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // 侧栏用法：SizedBox(48) + 横向 ListView
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  children: [
                    FilterPill(label: '歌单', isSelected: false, onTap: () {}),
                  ],
                ),
              ),
              // 主页用法：横向 SingleChildScrollView + Row + 限高（与 HomeChipBar 内相同）
              SizedBox(
                height: 56,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Row(
                    children: [
                      SizedBox(
                        height: HomeChipBar.pillHeight,
                        child: FilterPill(label: '全部', isSelected: true, onTap: () {}),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final pills = tester.widgetList<FilterPill>(find.byType(FilterPill)).toList();
    expect(pills.length, 2);
    final sizes = [
      for (final p in pills) tester.getSize(find.byWidget(p)),
    ];
    // ignore: avoid_print
    print('sidebar pill: ${sizes[0]}, home pill: ${sizes[1]}');
    // 两边都与侧栏胶囊同高（32px）
    expect(sizes[0].height, moreOrLessEquals(HomeChipBar.pillHeight, epsilon: 0.5));
    expect(sizes[1].height, moreOrLessEquals(HomeChipBar.pillHeight, epsilon: 0.5));
  });
}
