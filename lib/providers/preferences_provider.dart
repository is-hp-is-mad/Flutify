import 'package:flutter/foundation.dart';

import '../models/app_preferences.dart';
import '../services/storage_service.dart';

/// 界面偏好（语言 / 歌词样式 / 启动页 / 窗口记忆 / Connect）的唯一来源。
///
/// 修改即时生效并持久化；订阅方用 `context.select` 只取自己关心的字段。
/// 沉浸式歌词「铺满整个屏幕」沿用早先的独立存储键，这里只做读写桥接。
class PreferencesProvider extends ChangeNotifier {
  final StorageService _storage;
  AppPreferences _prefs;

  PreferencesProvider(this._storage) : _prefs = AppPreferences.decode(_storage.preferencesJson);

  AppPreferences get prefs => _prefs;

  void update(AppPreferences next) {
    if (next == _prefs) return;
    _prefs = next;
    _storage.setPreferencesJson(next.encode());
    notifyListeners();
  }

  /// 沉浸式歌词默认是否进入系统全屏（关闭时只铺满窗口）。
  bool get immersiveScreen => _storage.immersiveScreenFullscreen;

  void setImmersiveScreen(bool value) {
    if (value == immersiveScreen) return;
    _storage.setImmersiveScreenFullscreen(value);
    notifyListeners();
  }
}
