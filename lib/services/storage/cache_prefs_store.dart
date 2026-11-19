import 'key_value_store.dart';

/// 缓存目录、缓存上限与迁移路径持久化。
class CachePrefsStore {
  static const String _keyAudioCacheLimitMb = 'cache_audio_limit_mb';

  final KeyValueStore _prefs;

  CachePrefsStore(this._prefs);

  int get audioCacheLimitMb => _prefs.getInt(_keyAudioCacheLimitMb) ?? 512;
  Future<bool> setAudioCacheLimitMb(int value) =>
      _prefs.setInt(_keyAudioCacheLimitMb, value);

  String get audioCacheDirectory =>
      _prefs.getString('cache_audio_directory') ?? '';
  Future<bool> setAudioCacheDirectory(String value) =>
      _prefs.setString('cache_audio_directory', value);

  String? get cacheDirectory => _prefs.getString('cache_directory');
  Future<bool> setCacheDirectory(String value) =>
      _prefs.setString('cache_directory', value);

  String get cacheLocationsJson => _prefs.getString('cache_locations_v2') ?? '';
  Future<bool> setCacheLocationsJson(String value) =>
      _prefs.setString('cache_locations_v2', value);

  List<String> get previousCacheRoots =>
      _prefs.getStringList('cache_previous_roots') ?? const [];
  Future<bool> setPreviousCacheRoots(List<String> roots) =>
      _prefs.setStringList('cache_previous_roots', roots);
}
