import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/ui/widgets/app_button.dart';
import 'package:flutify_app/ui/widgets/flutify_progress.dart';
import 'package:flutify_app/ui/widgets/hyper_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

/// 柔光玻璃下不能留 MD3E 的痕迹；MD3E 下主题和控件不受影响。
void main() {
  const accent = Color(0xFF1ED760);
  const hyper = AppearanceSettings(glassMaterial: GlassMaterial.hyper);

  for (final brightness in Brightness.values) {
    test('柔光玻璃主题：$brightness 下是中性色、没有水波纹', () {
      final theme = MD3ETheme.build(brightness, hyper, accent);
      final s = theme.colorScheme;
      expect(theme.splashFactory, NoSplash.splashFactory);
      expect(s.primary, MD3ETheme.build(brightness, AppearanceSettings.defaults, accent).colorScheme.primary);
      expect(s.surface.r, closeTo(s.surface.g, 0.001));
      expect(s.surfaceContainerHigh.g, closeTo(s.surfaceContainerHigh.b, 0.001));
      expect(s.surfaceTint, Colors.transparent);
    });
  }

  testWidgets('Tooltip 用 MiSans，不退回系统字体', (tester) async {
    final key = GlobalKey<TooltipState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MD3ETheme.build(Brightness.light, hyper, accent),
        home: Scaffold(
          body: Center(
            child: Tooltip(key: key, message: 'tip', child: const Text('x')),
          ),
        ),
      ),
    );
    key.currentState!.ensureTooltipVisible();
    await tester.pump();
    final text = tester.widget<RichText>(
      find.descendant(of: find.byType(Overlay), matching: find.byType(RichText)).last,
    );
    expect(text.text.toPlainText(), 'tip');
    final family = text.text.style?.fontFamily;
    expect(family, 'MiSansHyper');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('顶栏是渐变模糊：逐条减弱，省电模式不模糊', (tester) async {
    Future<void> pump(AppearanceSettings settings) => tester.pumpWidget(
      MaterialApp(
        theme: MD3ETheme.build(Brightness.light, settings, accent),
        home: const SizedBox(height: 90, child: HyperAppBarBackground()),
      ),
    );

    await pump(hyper);
    final filters = find.byType(BackdropFilter);
    expect(filters, findsNWidgets(HyperAppBarBackground.bandRadii.length));
    final radii = HyperAppBarBackground.bandRadii;
    for (var i = 1; i < radii.length; i++) {
      expect(radii[i], lessThan(radii[i - 1]));
    }

    await pump(
      const AppearanceSettings(
        glassMaterial: GlassMaterial.hyper,
        powerSaving: true,
      ),
    );
    await tester.pumpAndSettle(); // MaterialApp 的主题切换有动画
    expect(find.byType(BackdropFilter), findsNothing);
  });

  test('MD3E 主题不受影响', () {
    final theme = MD3ETheme.build(
      Brightness.light,
      AppearanceSettings.defaults,
      accent,
    );
    expect(theme.splashFactory, isNot(NoSplash.splashFactory));
  });

  Future<void> pump(WidgetTester tester, AppearanceSettings settings) =>
      tester.pumpWidget(
        MaterialApp(
          theme: MD3ETheme.build(Brightness.light, settings, accent),
          home: Scaffold(
            body: Column(
              children: [
                AppButton.filled(onPressed: () {}, child: const Text('a')),
                AppButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add),
                  label: const Text('b'),
                  style: M3EButtonStyle.outlined,
                ),
                AppCheckbox(value: true, onChanged: (_) {}),
                const FlutifySpinner(),
                const FlutifyLinearProgress(value: 0.5),
              ],
            ),
          ),
        ),
      );

  testWidgets('柔光玻璃下不再用 M3E 控件', (tester) async {
    await pump(tester, hyper);
    expect(find.byType(M3EButton), findsNothing);
    expect(find.byType(M3ECheckbox), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
  });

  testWidgets('MD3E 下仍是 M3E 控件', (tester) async {
    await pump(tester, AppearanceSettings.defaults);
    expect(find.byType(M3EButton), findsNWidgets(2));
    expect(find.byType(M3ECheckbox), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
