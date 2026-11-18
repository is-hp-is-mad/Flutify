import 'package:shared_preferences/shared_preferences.dart';

import 'storage/auth_session_store.dart';
import 'storage/cache_prefs_store.dart';
import 'storage/key_value_store.dart';
import 'storage/library_cache_store.dart';
import 'storage/playback_prefs_store.dart';
import 'storage/preferences_store.dart';
import 'storage/update_state_store.dart';

export 'storage/auth_session_store.dart';
export 'storage/cache_prefs_store.dart';
export 'storage/key_value_store.dart';
export 'storage/library_cache_store.dart';
export 'storage/playback_prefs_store.dart';
export 'storage/preferences_store.dart';
export 'storage/update_state_store.dart';

/// 持久化存储装配根：按职责拆分为独立 Store，避免单一 God Object 被全树耦合。
class StorageService {
  final KeyValueStore kv;
  final AuthSessionStore auth;
  final PreferencesStore preferences;
  final PlaybackPrefsStore playback;
  final CachePrefsStore cache;
  final LibraryCacheStore library;
  final UpdateStateStore updates;

  StorageService._(this.kv)
      : auth = AuthSessionStore(kv),
        preferences = PreferencesStore(kv),
        playback = PlaybackPrefsStore(kv),
        cache = CachePrefsStore(kv),
        library = LibraryCacheStore(kv),
        updates = UpdateStateStore(kv);

  factory StorageService(SharedPreferences prefs) =>
      StorageService._(SharedPreferencesStore(prefs));

  /// 创建纯内存隔离存储，用于 Mock / 自测模式（不读写磁盘，也不污染真实登录态与设置）。
  factory StorageService.ephemeral([Map<String, Object>? initial]) {
    final storage = StorageService._(MemoryKeyValueStore(initial));
    storage.auth.ensureReceiverDeviceIdSync();
    return storage;
  }

  static Future<StorageService> init() async {
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService(prefs);
    await storage.auth.ensureReceiverDeviceId();
    await storage.auth.dropLegacySession();
    return storage;
  }
}
