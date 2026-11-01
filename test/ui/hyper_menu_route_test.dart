import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/ui/widgets/hyper_surface.dart';
import 'package:flutify_app/ui/widgets/menu/desktop_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 柔光玻璃弹出菜单：选中值照常返回；放不下时按 miuix 的规则贴底或翻到锚点上方。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Alignment alignment,
    required ValueChanged<int?> onResult,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tokens = FlutifyTokens.from(
      const AppearanceSettings(glassMaterial: GlassMaterial.hyper),
      const Color(0xFF1ED760),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [tokens]),
        home: Scaffold(
          body: Align(
            alignment: alignment,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  onResult(
                    await DesktopMenu.show<int>(
                      context,
                      DesktopMenu.anchorOf(context),
                      [
                        for (var i = 0; i < 6; i++)
                          DesktopMenu.item(i, Icons.star, 'item $i'),
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('selecting an item returns its value and closes the menu', (
    tester,
  ) async {
    int? result;
    await pump(
      tester,
      alignment: Alignment.topLeft,
      onResult: (v) => result = v,
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text('item 3'), findsOneWidget);

    await tester.tap(find.text('item 3'));
    await settle(tester);
    expect(result, 3);
    expect(find.text('item 3'), findsNothing);
  });

  testWidgets('opens down from the top of the anchor', (tester) async {
    await pump(tester, alignment: Alignment.topLeft, onResult: (_) {});
    await tester.tap(find.text('open'));
    await settle(tester);
    final button = tester.getRect(find.byType(TextButton).first);
    final surface = tester.getRect(find.byType(HyperBlendSurface));
    expect(surface.top, moreOrLessEquals(button.top.clamp(12, 600)));
    expect(surface.right, lessThanOrEqualTo(800));
  });

  testWidgets('moves above the anchor when there is no room below', (
    tester,
  ) async {
    await pump(tester, alignment: Alignment.bottomRight, onResult: (_) {});
    await tester.tap(find.text('open'));
    await settle(tester);
    final button = tester.getRect(find.byType(TextButton).first);
    final surface = tester.getRect(find.byType(HyperBlendSurface));
    expect(surface.bottom, moreOrLessEquals(button.top));
    expect(surface.right, moreOrLessEquals(button.right.clamp(0, 788)));
  });

  test('blur values are LM radii, not gaussian sigmas', () {
    expect(HyperBlendSurface.blurSigma(60), moreOrLessEquals(6.75));
    expect(HyperBlendSurface.blurSigma(100), moreOrLessEquals(11.25));
  });
}
