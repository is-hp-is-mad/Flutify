import 'dart:async';

import 'package:flutify_app/core/theme/flutify_tokens.dart';
import 'package:flutify_app/ui/widgets/apple_music_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('com.flutify/apple_music_background');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'create' ? 42 : null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Widget host({
    bool enabled = true,
    bool reduced = false,
    bool powerSaving = false,
    bool disableAnimations = false,
  }) => MaterialApp(
    theme: ThemeData(
      extensions: [FlutifyTokens.fallback.copyWith(powerSaving: powerSaving)],
    ),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: TickerMode(
          enabled: enabled,
          child: AppleMusicBackground(imageUrl: '', reducedEffects: reduced),
        ),
      ),
    ),
  );

  Future<void> flushMicrotasks() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.value();
    }
  }

  testWidgets('one native texture survives tab changes and pauses offscreen', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byType(Texture), findsOneWidget);
    expect(calls.where((c) => c.method == 'create').length, 1);
    await tester.pumpWidget(host(reduced: true));
    await tester.pumpAndSettle();
    expect(
      calls
          .lastWhere((c) => c.method == 'configure')
          .arguments['reducedEffects'],
      true,
    );
    await tester.pumpWidget(host(enabled: false));
    await tester.pumpAndSettle();
    expect(
      calls.lastWhere((c) => c.method == 'configure').arguments['active'],
      false,
    );
    expect(calls.where((c) => c.method == 'create').length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'dispose').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late native creation after unmount releases its texture', (
    tester,
  ) async {
    final create = Completer<int>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'create' ? create.future : null;
        });
    await tester.pumpWidget(host());
    await tester.pumpWidget(const SizedBox.shrink());
    create.complete(77);
    await tester.pumpAndSettle();
    expect(calls.last.method, 'dispose');
    expect(calls.last.arguments['id'], 77);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid background lifecycle changes pause native work without another frame',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere((call) => call.method == 'configure')
            .arguments['active'],
        true,
      );
      calls.clear();

      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await flushMicrotasks();

        expect(
          calls
              .lastWhere((call) => call.method == 'configure')
              .arguments['active'],
          false,
        );
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );

  testWidgets(
    'creation completed in the background never replays cached active state',
    (tester) async {
      final create = Completer<int>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'create' ? create.future : null;
          });

      try {
        await tester.pumpWidget(host());
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        create.complete(73);
        await flushMicrotasks();

        final configurations = calls.where(
          (call) => call.method == 'configure',
        );
        expect(configurations, isNotEmpty);
        expect(configurations.last.arguments['id'], 73);
        expect(configurations.last.arguments['active'], false);
        expect(
          configurations.where((call) => call.arguments['active'] == true),
          isEmpty,
        );
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );

  for (final mode in ['power saving', 'disabled animations']) {
    testWidgets('$mode pauses and resumes the existing native texture', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          powerSaving: mode == 'power saving',
          disableAnimations: mode == 'disabled animations',
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'create').length, 1);
      expect(
        calls
            .lastWhere((call) => call.method == 'configure')
            .arguments['active'],
        false,
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'create').length, 1);
      expect(
        calls
            .lastWhere((call) => call.method == 'configure')
            .arguments['active'],
        true,
      );
      expect(find.byType(Texture), findsOneWidget);
    });
  }
}
