import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/models/appearance.dart';
import 'package:flutify_app/ui/widgets/app_button.dart';
import 'package:flutify_app/ui/widgets/app_modal.dart';
import 'package:flutify_app/ui/widgets/app_switch.dart';
import 'package:flutify_app/ui/widgets/flutify_dialog.dart';
import 'package:flutify_app/ui/widgets/hyper_surface.dart';
import 'package:flutify_app/ui/widgets/toast/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_glass/hyper_ui.dart' show HySwitch, Pressable;
import 'package:material_3_expressive/material_3_expressive.dart';

/// 两种材质各走一遍同一批入口：MD3E 必须和原来一样，柔光玻璃全部换成混色模糊表面。
void main() {
  Future<BuildContext> pump(WidgetTester tester, GlassMaterial material) async {
    late BuildContext captured;
    final tokens = FlutifyTokens.from(
      AppearanceSettings(glassMaterial: material),
      const Color(0xFF1ED760),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [tokens]),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              captured = context;
              return Center(
                child: AppSwitch(value: true, onChanged: (_) {}),
              );
            },
          ),
        ),
      ),
    );
    return captured;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget dialog(BuildContext context) => FlutifyDialog(
    title: 'title',
    actions: [
      AppButton.text(
        onPressed: () => Navigator.pop(context, 'cancel'),
        child: const Text('cancel'),
      ),
      AppButton.filled(
        onPressed: () => Navigator.pop(context, 'ok'),
        child: const Text('ok'),
      ),
    ],
  );

  testWidgets('MD3E 保持原来的控件', (tester) async {
    final context = await pump(tester, GlassMaterial.liquid);
    expect(find.byType(M3ESwitch), findsOneWidget);

    showAppDialog<String>(context: context, builder: dialog);
    await settle(tester);
    expect(find.byType(HyperBlendSurface), findsNothing);
    expect(find.byType(M3EButton), findsNWidgets(2));
    Navigator.of(context, rootNavigator: true).pop();
    await settle(tester);

    showAppBottomSheet<void>(
      context: context,
      builder: (_) => const Text('sheet'),
    );
    await settle(tester);
    expect(find.text('sheet'), findsOneWidget);
    expect(find.byType(HyperBlendSurface), findsNothing);
    Navigator.of(context, rootNavigator: true).pop();
    await settle(tester);

    AppToast.show(context, 'toast');
    await settle(tester);
    expect(find.byType(ToastContent), findsOneWidget);
    expect(find.byType(HyperBlendSurface), findsNothing);
  });

  testWidgets('柔光玻璃换成混色模糊表面', (tester) async {
    final context = await pump(tester, GlassMaterial.hyper);
    expect(find.byType(HySwitch), findsOneWidget);
    expect(find.byType(M3ESwitch), findsNothing);

    final result = showAppDialog<String>(context: context, builder: dialog);
    await settle(tester);
    expect(find.byType(HyperBlendSurface), findsOneWidget);
    expect(find.byType(M3EButton), findsNothing);
    await tester.tap(
      find.descendant(of: find.byType(Pressable), matching: find.text('ok')),
    );
    await settle(tester);
    expect(await result, 'ok');
    expect(find.byType(HyperBlendSurface), findsNothing);

    showAppBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const Text('sheet'),
    );
    await settle(tester);
    expect(find.text('sheet'), findsOneWidget);
    expect(find.byType(HyperBlendSurface), findsOneWidget);
    Navigator.of(context, rootNavigator: true).pop();
    await settle(tester);

    var acted = false;
    AppToast.show(
      context,
      'toast',
      actionLabel: 'act',
      onAction: () => acted = true,
    );
    await settle(tester);
    expect(find.byType(ToastContent), findsNothing);
    expect(find.byType(HyperBlendSurface), findsOneWidget);
    await tester.tap(find.text('act'));
    await settle(tester);
    expect(acted, isTrue);
  });

  testWidgets('柔光玻璃下没有实色按钮时，确认按钮是主按钮', (tester) async {
    final context = await pump(tester, GlassMaterial.hyper);
    showAppDialog<void>(
      context: context,
      builder: (_) => FlutifyDialog(
        title: 'title',
        actions: [
          AppButton.text(onPressed: () {}, child: const Text('cancel')),
          AppButton.text(onPressed: () {}, child: const Text('sign out')),
        ],
      ),
    );
    await settle(tester);
    expect(find.byType(Pressable), findsNWidgets(2));
    final primary = Theme.of(context).colorScheme.primary;
    Color? colorOf(String text) {
      final box = tester.widget<Container>(
        find
            .ancestor(of: find.text(text), matching: find.byType(Container))
            .first,
      );
      return (box.decoration! as BoxDecoration).color;
    }

    expect(colorOf('sign out'), primary);
    expect(colorOf('cancel'), isNot(primary));
  });
}
