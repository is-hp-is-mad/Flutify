import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 透明系统栏（状态栏 / 手势导航栏）样式。
///
/// [background] 为系统栏下方内容的明暗：深色背景 → 浅色图标，浅色背景 → 深色图标。
/// 用法：`AnnotatedRegion<SystemUiOverlayStyle>(value: systemBarsStyle(...), child: ...)`。
SystemUiOverlayStyle systemBarsStyle(Brightness background) {
  final icons = background == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    // iOS 用 statusBarBrightness 表示「背景」明暗，与 Android 的图标明暗相反
    statusBarBrightness: background,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
  );
}
