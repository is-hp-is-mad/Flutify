import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 保持屏幕常亮（Android：窗口 FLAG_KEEP_SCREEN_ON，见 ScreenAwakePlugin.kt）。
///
/// 按持有者计数：切换动画里新旧两个歌词界面会短暂同时存在，最后一个释放才恢复自动熄屏。
/// 其他平台什么都不做。
class ScreenAwake {
  ScreenAwake._();

  static const MethodChannel _channel = MethodChannel('flutify/screen_awake');

  static final Set<Object> _holders = {};

  @visibleForTesting
  static bool get isHeld => _holders.isNotEmpty;

  static void acquire(Object holder) {
    if (_holders.add(holder) && _holders.length == 1) _apply(true);
  }

  static void release(Object holder) {
    if (_holders.remove(holder) && _holders.isEmpty) _apply(false);
  }

  static void _apply(bool on) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.invokeMethod<void>('setKeepScreenOn', on).catchError((Object e) {
      debugPrint('[screen_awake] 设置常亮失败：$e');
    });
  }
}
