import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'desktop_window.dart';

/// Windows 11 分屏布局（鼠标停在最大化按钮上弹出的分屏选择器）的 Dart 一侧。
///
/// 原生实现见 `windows/runner/snap_layout.cpp`：系统只认顶层窗口返回 HTMAXBUTTON 的区域，
/// 所以自绘的最大化按钮要把自己的位置告诉原生端；该区域的鼠标消息随之交给系统，
/// Flutter 收不到，悬停 / 按下状态和点击由原生端通过 [hovered] / [pressed] / 点击回调传回。
class SnapLayoutBridge {
  SnapLayoutBridge._();

  static const MethodChannel _channel = MethodChannel('flutify/window');

  /// 原生端报告的悬停 / 按下状态（鼠标在最大化按钮上时 Flutter 自己收不到指针事件）。
  static final ValueNotifier<bool> hovered = ValueNotifier(false);
  static final ValueNotifier<bool> pressed = ValueNotifier(false);

  static bool _initialized = false;
  static Rect? _sent;
  static Rect? _pending;
  static bool _flushScheduled = false;

  /// 只在 Windows 的真实窗口中生效（测试、其他平台不做任何事）。
  static bool get supported => !kIsWeb && Platform.isWindows && DesktopWindow.enabled;

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'maximizeButtonState':
          final args = call.arguments as Map?;
          hovered.value = args?['hovered'] == true;
          pressed.value = args?['pressed'] == true;
        case 'maximizeButtonClick':
          await DesktopWindow.toggleMaximize();
      }
    });
  }

  /// 更新最大化按钮的位置（逻辑像素，相对 Flutter 视图）；null 表示按钮不在屏幕上。
  /// 同一帧内的多次更新只在帧结束后发送最后一次。
  static void report(Rect? rect) {
    if (!supported) return;
    _ensureInitialized();
    _pending = rect;
    if (_flushScheduled) return;
    _flushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      final rect = _pending;
      if (rect == _sent) return;
      _sent = rect;
      if (rect == null) {
        hovered.value = false;
        pressed.value = false;
      }
      _channel
          .invokeMethod<void>(
            'setMaximizeButton',
            rect == null ? null : {'left': rect.left, 'top': rect.top, 'width': rect.width, 'height': rect.height},
          )
          .catchError((Object _) {}); // 旧版 runner 没有这个通道时忽略
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

/// 包住自绘的最大化按钮：每次绘制时检查自己在窗口中的位置，变化了就告诉原生端；
/// 从界面移除时（如进入系统全屏）清除。
class SnapLayoutAnchor extends SingleChildRenderObjectWidget {
  const SnapLayoutAnchor({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSnapLayoutAnchor();
}

class _RenderSnapLayoutAnchor extends RenderProxyBox {
  Rect? _last;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (!SnapLayoutBridge.supported) return;
    final rect = localToGlobal(Offset.zero) & size;
    if (rect != _last) {
      _last = rect;
      SnapLayoutBridge.report(rect);
    }
  }

  @override
  void detach() {
    if (_last != null) {
      _last = null;
      SnapLayoutBridge.report(null);
    }
    super.detach();
  }
}
