import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/ui/screens/home/widgets/home_chip_bar.dart';
import 'package:flutify_app/ui/widgets/filter_pill.dart';
import 'package:hyper_glass/hyper_ui.dart' show HyTextTabs;

void main() {
  testWidgets('HomeChipBar in hyperMaterial mode uses HyTextTabs and expands subChips with seamless reset', (tester) async {
    final chips = [
      const HomeChip(
        id: 'music',
        label: 'Music',
        subChips: [
          HomeChip(id: 'sub-following', label: 'Following'),
        ],
      ),
      const HomeChip(id: 'podcasts', label: 'Podcasts', subChips: []),
    ];

    String selected = '';

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
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

    // 初始状态下采用正统 HyTextTabs，主分类去胶囊化（无 FilterPill）
    expect(find.byType(HyTextTabs), findsOneWidget);
    expect(find.byType(FilterPill), findsNothing);
    // 英文拦截：Music -> 音乐，Podcasts -> 播客
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('播客'), findsOneWidget);

    // 点击主分类「音乐」
    await tester.tap(find.text('音乐'));
    await tester.pumpAndSettle();
    expect(selected, 'music');

    // 二级分类（subChips）展开为轻量二级选项，英文拦截：Following -> 已关注
    expect(find.byType(FilterPill), findsOneWidget);
    expect(find.text('已关注'), findsOneWidget);
    // 彻底去除了 Spotify 风格的 _ClearPill 独立关闭按钮
    expect(find.byIcon(Icons.close_rounded), findsNothing);

    // 点击二级选项「已关注」
    await tester.tap(find.text('已关注'));
    await tester.pumpAndSettle();
    expect(selected, 'sub-following');

    // 再次点击已选中的二级选项，无缝复位到一级分类「音乐」
    await tester.tap(find.text('已关注'));
    await tester.pumpAndSettle();
    expect(selected, 'music');

    // 点击当前选中的主分类「音乐」，无缝复位到全部（''）
    await tester.tap(find.text('音乐'));
    await tester.pumpAndSettle();
    expect(selected, '');
    expect(find.byType(FilterPill), findsNothing);

    // 向下滚动列表 200dp，pinned=false 时随列表向上滚动离开顶部视口
    await tester.drag(find.text('Content Section'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('音乐'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('HomeChipBar in non-hyper mode retains FilterPill behavior', (tester) async {
    final chips = [
      const HomeChip(id: 'music', label: 'Music', subChips: []),
      const HomeChip(id: 'podcasts', label: 'Podcasts', subChips: []),
    ];

    String selected = '';

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff277af7)),
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
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 非 hyperMaterial 模式下保留 FilterPill 胶囊
    expect(find.byType(FilterPill), findsNWidgets(3));
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('播客'), findsOneWidget);
  });

  testWidgets('HomeChipBar pinned: true with subChips lays out without overflow', (tester) async {
    final chips = [
      const HomeChip(
        id: 'music',
        label: 'Music',
        subChips: [
          HomeChip(id: 'sub-following', label: 'Following'),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
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
              HomeChipBar(
                chips: chips,
                selected: 'music',
                pinned: true,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('已关注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
