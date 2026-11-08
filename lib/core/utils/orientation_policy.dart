import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 屏幕方向策略：手机锁定竖屏，平板与桌面不限制。
///
/// 以物理屏幕最短边（逻辑像素）< 600 判定为手机，与 Material 的紧凑窗口断点一致；
/// 平板可自由横竖屏，桌面端调用无效果。
class OrientationPolicy {
  OrientationPolicy._();

  static const double _phoneShortestSide = 600;

  /// 在 runApp 之前调用。
  static Future<void> apply() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return;
    final view = views.first;
    final logical = view.physicalSize / view.devicePixelRatio;
    if (logical.shortestSide >= _phoneShortestSide) return;
    await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  }
}
