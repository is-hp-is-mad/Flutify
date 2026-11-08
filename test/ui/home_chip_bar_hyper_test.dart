import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/ui/screens/home/widgets/home_chip_bar.dart';
import 'package:flutify_app/ui/widgets/filter_pill.dart';

void main() {
  testWidgets('HomeChipBar follows Xiaomi HyperOS spec: scrolls away when pinned=false and renders HyperOS chips', (tester) async {
    final chips = [
      const HomeChip(id: 'music', label: '音乐', subChips: []),
      const HomeChip(id: 'podcasts', label: '播客', subChips: []),
    ];

    String selected = '';

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff277af7)),
          extensions: const [
            FlutifyTokens(
              accent: Color(0xff277af7),
              onAccent: Colors.white,
              glassSigma: 20,
              glassTint: 0.1,
              glassOpacity: 0.5,
              cornerScale: 1.0,
              squareCorners: false,
              hyperMaterial: true,
            ),
          ],
        ),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              StatefulBuilder(
                builder: (context, setState) => HomeChipBar(
                  chips: chips,
                  selected: selected,
                  pinned: false,
                  onSelected: (id) => setState(() => selected = id),
                ),
              ),
              const SliverToBoxAdapter(
                child: SizedBox(
                  height: 1000,
                  child: Text('Content Section'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 初始状态下全部标签可见
    expect(find.byType(FilterPill), findsNWidgets(3)); // 全部、音乐、播客
    final initialPillRect = tester.getRect(find.text('音乐'));
    expect(initialPillRect.top, greaterThan(0));

    // 验证 FilterPill 遵循 HyperOS 药丸高度与圆角
    final pillBox = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.widgetWithText(FilterPill, '音乐'),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = pillBox.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(18));

    // 向下滚动列表 200dp
    await tester.drag(find.text('Content Section'), const Offset(0, -200));
    await tester.pumpAndSettle();

    // 验证：pinned=false 时，Tab 随列表向上滚动离开顶部视口，不会像旧版本那样强行吸顶
    expect(find.text('音乐'), findsNothing);

    expect(tester.takeException(), isNull);
  });
}
