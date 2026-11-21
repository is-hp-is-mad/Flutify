import 'dart:math' as math;

import 'package:flutify_app/ui/widgets/menu/apple_more_menu_route.dart';
import 'package:flutify_app/ui/widgets/menu/desktop_menu.dart';
import 'package:flutify_app/ui/widgets/menu/mobile_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ⋯ 更多菜单：团块 → 菜单形变、分层收回、原位二级菜单与返回值。
void main() {
  const screen = Size(390, 844);
  final shell = find.byKey(const ValueKey('apple-more-menu-shell'));

  Future<Rect> pump(
    WidgetTester tester, {
    required ValueChanged<String?> onResult,
    Alignment alignment = Alignment.topRight,
    bool withSubmenu = false,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Align(
              alignment: alignment,
              child: AppleMoreMenuSource(
                child: Builder(
                  builder: (context) => IconButton(
                    key: const ValueKey('more'),
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () async => onResult(
                      await AppleMoreMenu.show<String>(
                        context,
                        [
                          MobileMenu.item('add', Icons.add, 'Add to Playlist'),
                          MobileMenu.item(
                            'sort',
                            Icons.sort,
                            'Sort By',
                            submenu: true,
                          ),
                          MobileMenu.divider,
                          MobileMenu.item(
                            'delete',
                            Icons.delete_outline,
                            'Delete from Library',
                            destructive: true,
                          ),
                        ],
                        submenus: withSubmenu
                            ? {
                                'sort': AppleSubmenu(
                                  title: 'Sort By',
                                  items: () => [
                                    MobileMenu.item(
                                      'title',
                                      Icons.title,
                                      'Title',
                                    ),
                                    MobileMenu.item(
                                      'artist',
                                      Icons.person,
                                      'Artist',
                                    ),
                                  ],
                                ),
                              }
                            : const {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return tester.getRect(find.byKey(const ValueKey('more')));
  }

  double sourceOpacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('more')),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  testWidgets('opens as a blob on the button and grows left and down', (
    tester,
  ) async {
    final button = await pump(tester, onResult: (_) {});
    await tester.tap(find.byKey(const ValueKey('more')));
    await tester.pump();

    // First frame: a near-round blob centred on the ⋯ button.
    final blob = tester.getRect(shell);
    expect((blob.center - button.center).distance, lessThan(8));
    expect(blob.width, lessThan(80));
    expect((blob.width - blob.height).abs(), lessThan(24));

    // The shell stretches sideways first, then down.
    await tester.pump(const Duration(milliseconds: 80));
    final early = tester.getRect(shell);
    expect(early.width, greaterThan(blob.width));
    expect(early.right, greaterThan(button.center.dx));
    expect(early.width / 250, greaterThan(early.height / 160));
    expect(sourceOpacity(tester), lessThan(0.05));

    // The menu settles to its measured size, hugging the button's corner.
    await tester.pumpAndSettle();
    final menu = tester.getRect(shell);
    expect(menu.width, 250);
    // Hugs the button's corner, kept 12 dp inside the screen edge.
    expect(menu.right, closeTo(390 - 12, 0.5));
    expect(menu.left, lessThan(button.left));
    expect(menu.top, closeTo(math.max(button.top - 4, 12), 0.5));
    expect(menu.height, greaterThan(150));
    expect(find.text('Delete from Library'), findsOneWidget);
    expect(sourceOpacity(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse: content leaves first, then the shell, then ⋯', (
    tester,
  ) async {
    String? result = 'unset';
    final button = await pump(tester, onResult: (v) => result = v);
    await tester.tap(find.byKey(const ValueKey('more')));
    await tester.pumpAndSettle();
    final open = tester.getRect(shell);

    await tester.tapAt(const Offset(20, 800)); // outside: dismiss
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // Content already fading, shell still nearly the full menu, ⋯ hidden.
    final contentOpacity = tester
        .widget<Opacity>(
          find
              .ancestor(
                of: find.text('Add to Playlist'),
                matching: find.byType(Opacity),
              )
              .first,
        )
        .opacity;
    expect(contentOpacity, lessThan(0.6));
    expect(tester.getRect(shell).height, greaterThan(open.height * 0.6));
    expect(sourceOpacity(tester), 0);

    await tester.pump(const Duration(milliseconds: 110));
    final absorbing = tester.getRect(shell);
    expect(absorbing.height, lessThan(open.height * 0.5));
    expect(
      (absorbing.center - button.center).distance,
      lessThan((open.center - button.center).distance),
    );

    await tester.pumpAndSettle();
    expect(shell, findsNothing);
    expect(sourceOpacity(tester), 1);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing mid-open continues from the current shape', (
    tester,
  ) async {
    await pump(tester, onResult: (_) {});
    await tester.tap(find.byKey(const ValueKey('more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final before = tester.getRect(shell);
    Navigator.of(tester.element(shell)).pop();
    await tester.pump();
    final after = tester.getRect(shell);
    expect((after.width - before.width).abs(), lessThan(2));
    expect((after.height - before.height).abs(), lessThan(2));
    await tester.pumpAndSettle();
    expect(shell, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting an item returns its value exactly once', (
    tester,
  ) async {
    final results = <String?>[];
    await pump(tester, onResult: results.add);
    await tester.tap(find.byKey(const ValueKey('more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Playlist'));
    await tester.pumpAndSettle();
    expect(results, ['add']);
    expect(shell, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a submenu switches level inside the same menu and back', (
    tester,
  ) async {
    final results = <String?>[];
    await pump(tester, onResult: results.add, withSubmenu: true);
    await tester.tap(find.byKey(const ValueKey('more')));
    await tester.pumpAndSettle();
    final shellElement = tester.element(shell);

    await tester.tap(find.text('Sort By'));
    await tester.pumpAndSettle();
    // Same shell, never closed: no result yet, child level visible.
    expect(results, isEmpty);
    expect(identical(tester.element(shell), shellElement), isTrue);
    expect(find.text('Title'), findsOneWidget);
    expect(find.byKey(const ValueKey('apple-more-menu-back')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('apple-more-menu-back')));
    await tester.pumpAndSettle();
    expect(find.text('Title'), findsNothing);
    expect(find.text('Delete from Library'), findsOneWidget);

    await tester.tap(find.text('Sort By'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Artist'));
    await tester.pumpAndSettle();
    expect(results, ['artist']);
    expect(shell, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menus near the bottom grow upwards and stay on screen', (
    tester,
  ) async {
    final button = await pump(
      tester,
      onResult: (_) {},
      alignment: Alignment.bottomLeft,
    );
    await tester.tap(find.byKey(const ValueKey('more')));
    await tester.pumpAndSettle();
    final menu = tester.getRect(shell);
    // Anchored on the button, clamped inside the screen inset.
    expect(menu.bottom, lessThanOrEqualTo(844 - 12));
    expect(menu.bottom, greaterThan(button.center.dy));
    expect(menu.left, greaterThanOrEqualTo(12));
    expect(menu.top, greaterThanOrEqualTo(12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('popup menu button with morph uses the morph menu on phones', (
    tester,
  ) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              FlutifyPopupMenuButton<String>(
                morph: true,
                icon: const Icon(Icons.more_horiz),
                onSelected: (v) => picked = v,
                itemBuilder: (_) => [
                  MobileMenu.item('delete', Icons.delete, 'Delete'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(shell, findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(picked, 'delete');
    expect(tester.takeException(), isNull);
  });
}
