import 'key_value_store.dart';

/// 播放器行为偏好（音量、音量均衡、淡入淡出、失败后暂停、自动播放）。
class PlaybackPrefsStore {
  static const String _keyVolume = 'sp_volume';
  static const String _keyPauseAfterFailures = 'play_pause_after_failures';
  static const String _keyAutoplay = 'play_autoplay';
  static const String _keyNormalize = 'play_normalize';
  static const String _keyFadeSeconds = 'play_fade_seconds';

  final KeyValueStore _prefs;

  PlaybackPrefsStore(this._prefs);

  double get volume => _prefs.getDouble(_keyVolume) ?? 0.8;
  Future<bool> setVolume(double value) => _prefs.setDouble(_keyVolume, value);

  bool get pauseAfterFailures => _prefs.getBool(_keyPauseAfterFailures) ?? true;
  Future<bool> setPauseAfterFailures(bool value) =>
      _prefs.setBool(_keyPauseAfterFailures, value);

  bool get autoplay => _prefs.getBool(_keyAutoplay) ?? true;
  Future<bool> setAutoplay(bool value) => _prefs.setBool(_keyAutoplay, value);

  bool get normalizeVolume => _prefs.getBool(_keyNormalize) ?? false;
  Future<bool> setNormalizeVolume(bool value) =>
      _prefs.setBool(_keyNormalize, value);

  int get fadeSeconds => _prefs.getInt(_keyFadeSeconds) ?? 0;
  Future<bool> setFadeSeconds(int value) =>
      _prefs.setInt(_keyFadeSeconds, value);
}
