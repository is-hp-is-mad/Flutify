import 'dart:convert';

import 'key_value_store.dart';

/// 媒体库快照缓存、歌单备份索引及搜索历史持久化。
class LibraryCacheStore {
  static const String keyLibraryLikedTracks = 'lib_liked_tracks';
  static const String keyLibraryPlaylists = 'lib_playlists';
  static const String keyLibraryArtists = 'lib_artists';
  static const String keyLibraryAlbums = 'lib_albums';
  static const String keyLibraryLocalPlaylists = 'lib_playlists_local';
  static const String keyPlaylistBackups = 'backup_accounts_v1';

  static const String _keyLibraryAccount = 'lib_account';
  static const String _keyLibrarySchema = 'lib_schema';
  static const String _keyRecentSearches = 'sp_recent_searches';

  final KeyValueStore _prefs;

  LibraryCacheStore(this._prefs);

  bool hasKey(String key) => _prefs.containsKey(key);

  Future<bool> removeKey(String key) => _prefs.remove(key);

  String get libraryAccount => _prefs.getString(_keyLibraryAccount) ?? '';
  Future<bool> setLibraryAccount(String value) =>
      _prefs.setString(_keyLibraryAccount, value);

  String get ownerUsername => _prefs.getString('sp_username') ?? '';
  String get ownerDisplayName => _prefs.getString('sp_display_name') ?? '';

  int get librarySchema => _prefs.getInt(_keyLibrarySchema) ?? 0;
  Future<bool> setLibrarySchema(int value) =>
      _prefs.setInt(_keyLibrarySchema, value);

  /// 读取 JSON 对象列表；单条损坏的数据会被跳过而不是让整个列表失效。
  List<Map<String, dynamic>> readJsonList(String key) {
    final raw = _prefs.getStringList(key);
    if (raw == null) return const [];
    final result = <Map<String, dynamic>>[];
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) result.add(decoded);
      } catch (_) {}
    }
    return result;
  }

  Future<bool> writeJsonList(String key, Iterable<Map<String, dynamic>> items) {
    return _prefs.setStringList(key, items.map(jsonEncode).toList());
  }

  List<String> get recentSearches =>
      _prefs.getStringList(_keyRecentSearches) ?? [];

  Future<bool> addRecentSearch(String query) {
    final clean = query.trim();
    if (clean.isEmpty) return Future.value(false);
    final list = recentSearches;
    list.remove(clean);
    list.insert(0, clean);
    if (list.length > 20) list.removeLast();
    return _prefs.setStringList(_keyRecentSearches, list);
  }

  Future<bool> removeRecentSearch(String query) {
    final list = recentSearches..remove(query);
    return _prefs.setStringList(_keyRecentSearches, list);
  }

  Future<bool> clearRecentSearches() => _prefs.remove(_keyRecentSearches);
}
