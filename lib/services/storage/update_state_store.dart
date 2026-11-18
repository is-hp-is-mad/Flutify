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
}
