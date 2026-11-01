import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/ui/screens/settings/widgets/settings_slider_tile.dart';
import 'package:flutify_app/ui/widgets/mini_player_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_glass/hyper_ui.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: ThemeData(
      extensions: [
        FlutifyTokens.from(
          const AppearanceSettings(glassMaterial: GlassMaterial.hyper),
          const Color(0xFF1ED760),
        ),
      ],
    ),
    home: Scaffold(
      body: Center(child: SizedBox(width: 306, child: child)),
    ),
  );

  testWidgets('分段控件可以拖动，松手落到最近一项', (tester) async {
    final changes = <int>[];
    await tester.pumpWidget(
      host(
        HySegmented(
          items: const ['a', 'b', 'c'],
          index: 0,
          onChanged: changes.add,
        ),
      ),
    );
    await tester.drag(find.text('a'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(changes, [2]);
  });

  testWidgets('设置滑杆：拖动时只预览，松手才提交', (tester) async {
    final previews = <double?>[];
    final commits = <double>[];
    await tester.pumpWidget(
      host(
        SettingsSliderTile(
          title: 't',
          labelOf: (v) => v.toStringAsFixed(1),
          value: 0,
          divisions: 10,
          onPreview: previews.add,
          onChanged: commits.add,
        ),
      ),
    );
    final bar = find.byType(GestureDetector).last;
    await tester.drag(bar, const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(commits, hasLength(1));
    expect(commits.single, greaterThan(0));
    expect(previews.last, isNull);
  });

  testWidgets('迷你条：距离不够弹回，够了才切歌', (tester) async {
    final swipes = <bool>[];
    await tester.pumpWidget(
      host(
        MiniPlayerSwipe(
          onSwipe: swipes.add,
          child: const SizedBox(height: 56, child: Text('row')),
        ),
      ),
    );
    await tester.timedDrag(
      find.text('row'),
      const Offset(-20, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(swipes, isEmpty);
    await tester.timedDrag(
      find.text('row'),
      const Offset(-80, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(swipes, [true]);
  });
}
