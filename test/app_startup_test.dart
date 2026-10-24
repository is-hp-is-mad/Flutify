import 'dart:async';

import 'package:flutify_app/core/widgets/app_startup.dart';
import 'package:flutify_app/ui/widgets/flutify_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'first frame is visible while initialization waits, then opens app',
    (tester) async {
      final pending = Completer<Widget>();
      await tester.pumpWidget(
        AppStartup(
          initialize: (report) {
            report('准备缓存目录');
            return pending.future;
          },
        ),
      );
      await tester.pump();
      expect(find.text('Flutify'), findsNothing);
      expect(find.text('准备缓存目录'), findsNothing);
      expect(_anySpinner, findsNothing);
      pending.complete(const MaterialApp(home: Text('Ready')));
      await tester.pumpAndSettle();
      expect(find.text('Ready'), findsOneWidget);
      expect(_anySpinner, findsNothing);
    },
  );

  testWidgets('startup failure shows phase and copies useful diagnostics', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      AppStartup(
        initialize: (report) async {
          report('准备缓存目录');
          throw StateError('cache unavailable');
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('启动失败：准备缓存目录'), findsOneWidget);
    expect(find.text('Bad state: cache unavailable'), findsOneWidget);
    expect(_anySpinner, findsNothing);
    // File I/O in readLogTail needs real async execution in a widget test.
    await tester.runAsync(() async {
      await tester.tap(find.text('复制诊断信息'));
      for (var i = 0; copied == null && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(copied, contains('准备缓存目录'));
    expect(copied, contains('cache unavailable'));
  });

  testWidgets(
    'stalled initialization exposes diagnostics and can still finish',
    (tester) async {
      final pending = Completer<Widget>();
      await tester.pumpWidget(
        AppStartup(
          initialize: (report) {
            report('连接系统媒体控制');
            return pending.future;
          },
        ),
      );
      await tester.pump(const Duration(seconds: 21));
      expect(find.text('复制诊断信息'), findsNothing);
      expect(_anySpinner, findsNothing);
      await tester.pump(const Duration(seconds: 40));
      expect(find.textContaining('初始化超时'), findsOneWidget);
      expect(find.text('复制诊断信息'), findsOneWidget);
      pending.complete(const MaterialApp(home: Text('Ready')));
      await tester.pumpAndSettle();
      expect(find.text('Ready'), findsOneWidget);
    },
  );
}

/// 启动期间不应出现任何加载圈（原生或 MD3E 版本）。
final Finder _anySpinner = find.byWidgetPredicate(
  (w) =>
      w is CircularProgressIndicator ||
      w is FlutifySpinner ||
      w is FlutifyLoadingIndicator,
);
