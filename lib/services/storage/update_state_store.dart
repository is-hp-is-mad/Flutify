import 'key_value_store.dart';

/// 应用内更新策略与版本忽略状态持久化。
class UpdateStateStore {
  final KeyValueStore _prefs;

  UpdateStateStore(this._prefs);

  String get updateMode => _prefs.getString('update_mode') ?? 'manual';
  Future<bool> setUpdateMode(String value) =>
      _prefs.setString('update_mode', value);

  String get updateChannel => _prefs.getString('update_channel') ?? '';
  Future<bool> setUpdateChannel(String value) =>
      _prefs.setString('update_channel', value);

  String get skippedUpdate => _prefs.getString('update_skipped') ?? '';
  Future<bool> setSkippedUpdate(String value) =>
      _prefs.setString('update_skipped', value);

  String get lastUpdateCheck => _prefs.getString('update_last_check') ?? '';
  Future<bool> setLastUpdateCheck(String value) =>
      _prefs.setString('update_last_check', value);

  /// 「更新后续播」标记：点安装时正在播放，记下时间（毫秒时间戳）与当时的版本；启动时消费一次。
  int? get resumeAfterUpdateAt => _prefs.getInt('update_resume_at');
  String get resumeAfterUpdateFrom => _prefs.getString('update_resume_from') ?? '';
  Future<void> setResumeAfterUpdate(int atMs, String fromVersion) async {
    await _prefs.setInt('update_resume_at', atMs);
    await _prefs.setString('update_resume_from', fromVersion);
  }

  /// 「有歌单没同步到 Spotify」提示已在哪个版本弹过（每个版本最多弹一次）。
  String get playlistSyncPromptedVersion =>
      _prefs.getString('playlist_sync_prompted_version') ?? '';
  Future<bool> setPlaylistSyncPromptedVersion(String value) =>
      _prefs.setString('playlist_sync_prompted_version', value);

  Future<void> clearResumeAfterUpdate() async {
    await _prefs.remove('update_resume_at');
    await _prefs.remove('update_resume_from');
  }
}
