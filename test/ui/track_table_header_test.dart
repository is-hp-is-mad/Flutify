import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/ui/screens/detail/widgets/collection_hero.dart';
import 'package:flutify_app/ui/widgets/track_table/track_sort.dart';
import 'package:flutify_app/ui/widgets/track_table/track_table_columns.dart';
import 'package:flutify_app/ui/widgets/track_table/track_table_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutify_app/l10n/app_localizations.dart';

void main() {
  setUp(() => ArtworkPalette.enabled = false);

  testWidgets('TrackTableHeader scrolls smoothly and pins at exactly 64dp under collapsed hero', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const columns = TrackTableColumns(
      compact: false,
      artist: true,
      album: true,
      addedAt: true,
    );

    TrackSort sort = const TrackSort(TrackSortKey.title);

    await tester.pumpWidget(
      MaterialApp(
        theme: MD3ETheme.dark,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CollectionTintScope(
            imageUrl: '',
            fallback: const Color(0xFF3A3A48),
            child: StatefulBuilder(
              builder: (context, setState) {
                return CustomScrollView(
                  slivers: [
                    const CollectionHero(
                      typeLabel: '歌单',
                      title: '测试歌单',
                      imageUrl: '',
                      collapsedAction: Icon(Icons.play_circle_fill_rounded, key: Key('bar-play')),
                    ),
                    const SliverToBoxAdapter(
                      child: SizedBox(key: Key('action-row'), height: 60),
                    ),
                    TrackTableHeader(
                      columns: columns,
                      sort: sort,
                      onSort: (key) => setState(() => sort = sort.tap(key)),
                    ),
                    SliverList.builder(
                      itemCount: 50,
                      itemBuilder: (_, i) => SizedBox(key: Key('track-$i'), height: 56, child: Text('Track $i')),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );

    // 展开状态下：屏幕上只有 1 个表头
    expect(find.byType(TrackTableHeaderContent), findsOneWidget);
    final initialPos = tester.getTopLeft(find.byType(TrackTableHeaderContent));
    // 初始位置在大头图 + action-row 下方（大于 300dp）
    expect(initialPos.dy, greaterThan(300));

    // 向上滚动 600dp，大头图收起为 64dp 顶栏，表头向上滑动到 64dp 处停住
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();

    // 依然只有这 1 个表头
    expect(find.byType(TrackTableHeaderContent), findsOneWidget);
    // 表头精确停留在 64dp（标题栏正下方）
    final pinnedPos = tester.getTopLeft(find.byType(TrackTableHeaderContent));
    expect(pinnedPos.dy, closeTo(64.0, 0.5));

    // 点击排序列测试排序回调响应
    await tester.tap(find.text('标题'));
    await tester.pumpAndSettle();
    expect(sort.descending, isTrue);
  });
}
