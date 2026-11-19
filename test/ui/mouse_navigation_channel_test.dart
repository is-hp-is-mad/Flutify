import 'dart:io';

import 'package:flutify_app/services/input/mouse_navigation_channel.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// macOS 原生侧键通道：Logi Options+ 把鼠标侧键作为 swipe 事件发送，
/// 原生端转成 `back` / `forward` 后应驱动与顶栏 ‹ › 相同的内容历史桥。
void main() {
  const channel = MethodChannel('flutify/mouse_navigation');

  testWidgets('原生 back / forward 驱动内容历史桥', (tester) async {
    if (!Platform.isMacOS) return; // 通道只在 macOS 注册

    var back = 0;
    var forward = 0;
    AppRoutes.navigateBack = () => back++;
    AppRoutes.navigateForward = () => forward++;
    addTearDown(() {
      AppRoutes.navigateBack = null;
      AppRoutes.navigateForward = null;
    });
    installMacOSMouseNavigation(
      onBack: () => AppRoutes.navigateBack?.call(),
      onForward: () => AppRoutes.navigateForward?.call(),
    );

    Future<void> fromNative(String method) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, null)),
          (_) {},
        );

    await fromNative('back');
    await fromNative('forward');
    await fromNative('unknown');

    expect(back, 1);
    expect(forward, 1);
    expect(tester.takeException(), isNull);
  });
}
