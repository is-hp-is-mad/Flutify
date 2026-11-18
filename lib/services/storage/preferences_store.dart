import 'key_value_store.dart';

/// 界面外观、交互偏好、窗口状态及代理密码持久化。
class PreferencesStore {
  static const String _keyProxyPassword = 'sp_proxy_password';
  static const String _keyImmersiveScreen = 'ui_immersive_screen';
  static const String _keyImmersivePinned = 'ui_immersive_pinned';
  static const String _keyWatchFeedOnboarding = 'watch_feed_onboarding_shown';
  static const String _keyWatchFeedPivotHint = 'watch_feed_pivot_hint_shown';
  static const String _keyAppearance = 'ui_appearance';
  static const String _keyPreferences = 'app_prefs';
  static const String _keyLastTab = 'ui_last_tab';
  static const String _keyWindowBounds = 'ui_window_bounds';

  final KeyValueStore _prefs;

  PreferencesStore(this._prefs);

  String get proxyPassword => _prefs.getString(_keyProxyPassword) ?? '';
  Future<bool> setProxyPassword(String value) =>
      _prefs.setString(_keyProxyPassword, value);

  bool get immersiveScreenFullscreen =>
      _prefs.getBool(_keyImmersiveScreen) ?? false;
  Future<bool> setImmersiveScreenFullscreen(bool value) =>
      _prefs.setBool(_keyImmersiveScreen, value);

  bool get watchFeedOnboardingShown =>
      _prefs.getBool(_keyWatchFeedOnboarding) ?? false;
  Future<bool> setWatchFeedOnboardingShown(bool value) =>
      _prefs.setBool(_keyWatchFeedOnboarding, value);

  bool get watchFeedPivotHintShown =>
      _prefs.getBool(_keyWatchFeedPivotHint) ?? false;
  Future<bool> setWatchFeedPivotHintShown(bool value) =>
      _prefs.setBool(_keyWatchFeedPivotHint, value);

  bool get immersivePinned => _prefs.getBool(_keyImmersivePinned) ?? false;
  Future<bool> setImmersivePinned(bool value) =>
      _prefs.setBool(_keyImmersivePinned, value);

  String get appearanceJson => _prefs.getString(_keyAppearance) ?? '';
  Future<bool> setAppearanceJson(String value) =>
      _prefs.setString(_keyAppearance, value);

  String get preferencesJson => _prefs.getString(_keyPreferences) ?? '';
  Future<bool> setPreferencesJson(String value) =>
      _prefs.setString(_keyPreferences, value);

  int get lastTab => _prefs.getInt(_keyLastTab) ?? 0;
  Future<bool> setLastTab(int value) => _prefs.setInt(_keyLastTab, value);

  String get windowBoundsJson => _prefs.getString(_keyWindowBounds) ?? '';
  Future<bool> setWindowBoundsJson(String value) =>
      _prefs.setString(_keyWindowBounds, value);
}
