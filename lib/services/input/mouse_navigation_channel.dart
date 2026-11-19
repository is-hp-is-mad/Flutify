import 'dart:io';

import 'package:flutter/services.dart';

/// macOS 鼠标侧键前进 / 后退的原生通道（MethodChannel `flutify/mouse_navigation`）。
///
/// Logi Options+ 等驱动把 MX 系列侧键作为「页面滑动」(NSEventTypeSwipe) 发送，
/// Flutter 引擎不处理 swipe 事件（原生端见 macos/Runner/MainFlutterWindow.swift 的
/// MouseNavigationChannel）；原生端监听后经本通道推送 `back` / `forward`，
/// 由调用方注入的回调驱动导航历史。
void installMacOSMouseNavigation({
  VoidCallback? onBack,
  VoidCallback? onForward,
}) {
  if (!Platform.isMacOS) return;
  const channel = MethodChannel('flutify/mouse_navigation');
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'back':
        onBack?.call();
      case 'forward':
        onForward?.call();
    }
    return null;
  });
}
