import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/ui/screens/settings/widgets/hyper_glass_preview.dart';
import 'package:flutify_app/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_glass/hyper_glass.dart';

/// 柔光玻璃预览：能渲染、按钮能展开 / 收起菜单，省电模式下光斑不再动。
void main() {
  Future<void> pump(WidgetTester tester, {bool powerSaving = false}) async {
    final tokens = FlutifyTokens.from(
      AppearanceSettings(powerSaving: powerSaving),
      const Color(0xFF1ED760),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [tokens]),
        home: const Scaffold(
          body: SizedBox(width: 420, child: HyperGlassPreview()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('menu morphs out of the blur button and closes again', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(HyperGlass), findsOneWidget);
    expect(find.text('浅色'), findsNothing);

    await tester.tap(find.text('模糊'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('浅色'), findsOneWidget);

    await tester.tap(find.text('浅色'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('浅色'), findsNothing);
  });

  testWidgets('power saving keeps the preview still', (tester) async {
    await pump(tester, powerSaving: true);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
