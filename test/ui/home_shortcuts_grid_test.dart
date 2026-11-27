import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/home_feed.dart';
import 'package:flutify_app/ui/screens/home/widgets/home_shortcuts_grid.dart';
import 'package:flutify_app/ui/widgets/cover_image.dart';
import 'package:flutify_app/ui/widgets/hover_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  HomeItem shortcut(String title) => HomeItem(
    kind: HomeItemKind.playlist,
    uri: 'spotify:playlist:${title.hashCode}',
    title: title,
  );

  Future<void> pump(WidgetTester tester, {required bool desktop, required double textScale}) async {
    tester.view.physicalSize = Size(desktop ? 1000 : 390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MediaQuery(
          data: MediaQueryData(size: Size(desktop ? 1000 : 390, 800), textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: CustomScrollView(
              slivers: [
                HomeShortcutsGrid(
                  items: [shortcut('Remember Our Summer'), shortcut('Chilled Dance Hits')],
                  desktop: desktop,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // 封面必须贴满卡片左侧（上、下、左三边对齐），卡片圆角才能裁出封面的左上 / 左下角；
  // 手机上两行标题比 56 高时，封面曾悬在卡片中间，露出不对齐的直角。
  for (final (desktop, scale) in [(false, 1.0), (false, 1.3), (true, 1.0), (true, 1.3)]) {
    testWidgets('封面与卡片同高并贴左（${desktop ? '桌面' : '手机'}，字号 ×$scale）', (tester) async {
      await pump(tester, desktop: desktop, textScale: scale);
      final tile = tester.getRect(find.byType(HoverBuilder).first);
      final cover = tester.getRect(find.byType(CoverImage).first);
      expect(cover.height, moreOrLessEquals(tile.height, epsilon: 0.01));
      expect(cover.width, moreOrLessEquals(tile.height, epsilon: 0.01));
      expect(cover.topLeft, offsetMoreOrLessEquals(tile.topLeft, epsilon: 0.01));
    });
  }
}
