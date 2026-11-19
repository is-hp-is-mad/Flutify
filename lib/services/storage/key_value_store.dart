import 'package:shared_preferences/shared_preferences.dart';

/// 轻量键值存储抽象（解耦业务 Store 与具体磁盘实现 / 测试内存实现）。
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<bool> setString(String key, String value);
  bool? getBool(String key);
  Future<bool> setBool(String key, bool value);
  int? getInt(String key);
  Future<bool> setInt(String key, int value);
  double? getDouble(String key);
  Future<bool> setDouble(String key, double value);
  List<String>? getStringList(String key);
  Future<bool> setStringList(String key, List<String> value);
  bool containsKey(String key);
  Future<bool> remove(String key);
}

/// 基于 [SharedPreferences] 的磁盘键值实现。
class SharedPreferencesStore implements KeyValueStore {
  final SharedPreferences _inner;

  SharedPreferencesStore(this._inner);

  @override
  String? getString(String key) => _inner.getString(key);

  @override
  Future<bool> setString(String key, String value) =>
      _inner.setString(key, value);

  @override
  bool? getBool(String key) => _inner.getBool(key);

  @override
  Future<bool> setBool(String key, bool value) => _inner.setBool(key, value);

  @override
  int? getInt(String key) => _inner.getInt(key);

  @override
  Future<bool> setInt(String key, int value) => _inner.setInt(key, value);

  @override
  double? getDouble(String key) => _inner.getDouble(key);

  @override
  Future<bool> setDouble(String key, double value) =>
      _inner.setDouble(key, value);

  @override
  List<String>? getStringList(String key) => _inner.getStringList(key);

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _inner.setStringList(key, value);

  @override
  bool containsKey(String key) => _inner.containsKey(key);

  @override
  Future<bool> remove(String key) => _inner.remove(key);
}

/// 纯内存隔离键值存储，用于 Mock / 自测 / 单元测试。
class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, Object> _store = {};

  MemoryKeyValueStore([Map<String, Object>? initial]) {
    if (initial != null) {
      for (final entry in initial.entries) {
        final v = entry.value;
        _store[entry.key] = v is List<String> ? List<String>.from(v) : v;
      }
    }
  }

  @override
  String? getString(String key) {
    final v = _store[key];
    return v is String ? v : null;
  }

  @override
  Future<bool> setString(String key, String value) async {
    _store[key] = value;
    return true;
  }

  @override
  bool? getBool(String key) {
    final v = _store[key];
    return v is bool ? v : null;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    _store[key] = value;
    return true;
  }

  @override
  int? getInt(String key) {
    final v = _store[key];
    return v is int ? v : null;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _store[key] = value;
    return true;
  }

  @override
  double? getDouble(String key) {
    final v = _store[key];
    return v is double ? v : (v is int ? v.toDouble() : null);
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    _store[key] = value;
    return true;
  }

  @override
  List<String>? getStringList(String key) {
    final v = _store[key];
    return v is List<String> ? List<String>.from(v) : null;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _store[key] = List<String>.from(value);
    return true;
  }

  @override
  bool containsKey(String key) => _store.containsKey(key);

  @override
  Future<bool> remove(String key) async {
    _store.remove(key);
    return true;
  }
}
