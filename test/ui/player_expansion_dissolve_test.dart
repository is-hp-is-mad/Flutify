import 'package:flutify_app/ui/screens/player/player_expansion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 柔光玻璃的迷你条是透明的：收起时外壳要在落地前溶解，不能以实色落地再突然变透明。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool translucent,
    required double value,
  }) async {
    final animation = AlwaysStoppedAnimation<double>(value);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerExpansionTransition(
          animation: animation,
          origin: PlayerExpansionOrigin(
            bounds: const Rect.fromLTWH(24, 500, 344, 56),
            color: Colors.brown,
            borderRadius: BorderRadius.circular(28),
            compactChild: const SizedBox(),
            translucent: translucent,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  double opacity(WidgetTester tester) => tester
      .widget<Opacity>(find.byKey(const ValueKey('player-expansion-dissolve')))
      .opacity;

  testWidgets('透明胶囊：贴近胶囊时外壳完全透明，展开后完全不透明', (tester) async {
    await pump(tester, translucent: true, value: 0);
    expect(opacity(tester), 0);
    await pump(tester, translucent: true, value: 1);
    expect(opacity(tester), 1);
  });

  testWidgets('实色胶囊（MD3E）不做溶解', (tester) async {
    await pump(tester, translucent: false, value: 0);
    expect(find.byKey(const ValueKey('player-expansion-dissolve')), findsNothing);
    expect(find.byKey(const ValueKey('player-expansion-surface')), findsOneWidget);
  });
}
