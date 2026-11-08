import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_hero.dart';
import 'package:flutify_app/ui/widgets/cover_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 详情页大头图：宽 / 窄两种布局、长标题不溢出、滚动后吸顶标题栏出现、移动端返回键。
void main() {
  setUp(() => ArtworkPalette.enabled = false);

  Future<void> pumpHero(
    WidgetTester tester, {
    required Size size,
    String title = 'After Hours',
    ThemeData? theme,
    bool pushed = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final page = Scaffold(
      body: CollectionTintScope(
        imageUrl: '',
        fallback: const Color(0xFF3A3A48),
        child: CustomScrollView(
          slivers: [
            CollectionHero(
              typeLabel: '专辑',
              title: title,
              imageUrl: '',
              meta: const Text('The Weeknd · 2020 · 14 首歌曲'),
              collapsedAction: const Icon(Icons.play_circle_fill_rounded, key: Key('bar-action')),
            ),
            const SliverToBoxAdapter(child: CollectionHeroFade(child: SizedBox(height: 80))),
            SliverList.builder(itemCount: 40, itemBuilder: (_, i) => SizedBox(height: 56, child: Text('row $i'))),
          ],
        ),
      ),
    );

    await tester.pumpWidget(MaterialApp(
      theme: theme ?? MD3ETheme.dark,
      home: pushed ? const Scaffold() : page,
    ));
    if (pushed) {
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute(builder: (_) => page));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('wide: 232px cover beside the title, no back button in the desktop shell', (tester) async {
    await pumpHero(tester, size: const Size(1280, 800), pushed: true);

    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('After Hours'), findsWidgets);
    expect(find.byTooltip('返回'), findsNothing);
    expect(find.byTooltip('Back'), findsNothing);
    // 封面在标题左侧，且为 232px
    final cover = find.byType(CoverImage);
    expect(tester.getSize(cover), const Size(232, 232));
    expect(tester.getTopRight(cover).dx, lessThan(tester.getTopLeft(find.text('专辑')).dx));
  });

  testWidgets('long titles shrink instead of overflowing', (tester) async {
    await pumpHero(
      tester,
      size: const Size(900, 700),
      title: '一首非常非常长的歌单标题用来测试自动缩小字号是否会溢出 Extended Deluxe Edition Remastered',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling collapses into a pinned bar with the play action', (tester) async {
    await pumpHero(tester, size: const Size(1280, 800));

    final barAction = find.byKey(const Key('bar-action'));
    Opacity barOpacity() => tester.widget<Opacity>(find.ancestor(of: barAction, matching: find.byType(Opacity)).first);
    expect(barOpacity().opacity, 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(barOpacity().opacity, closeTo(1, 0.001));
  });

  testWidgets('narrow (mobile): centered cover and a back button', (tester) async {
    await pumpHero(tester, size: const Size(390, 844), pushed: true, theme: MD3ETheme.light);

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    // 封面水平居中
    final cover = find.byType(CoverImage);
    expect(tester.getCenter(cover).dx, closeTo(390 / 2, 1));
    expect(find.text('专辑'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
