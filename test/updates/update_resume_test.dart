import 'package:flutify_app/services/storage/key_value_store.dart';
import 'package:flutify_app/services/storage/update_state_store.dart';
import 'package:flutify_app/services/updates/update_resume.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements KeyValueStore {
  final Map<String, Object> _v = {};
  @override
  String? getString(String key) => _v[key] as String?;
  @override
  Future<bool> setString(String key, String value) async => (_v[key] = value) == value;
  @override
  bool? getBool(String key) => _v[key] as bool?;
  @override
  Future<bool> setBool(String key, bool value) async => (_v[key] = value) == value;
  @override
  int? getInt(String key) => _v[key] as int?;
  @override
  Future<bool> setInt(String key, int value) async => (_v[key] = value) == value;
  @override
  double? getDouble(String key) => _v[key] as double?;
  @override
  Future<bool> setDouble(String key, double value) async => (_v[key] = value) == value;
  @override
  List<String>? getStringList(String key) => _v[key] as List<String>?;
  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _v[key] = value;
    return true;
  }

  @override
  bool containsKey(String key) => _v.containsKey(key);
  @override
  Future<bool> remove(String key) async => _v.remove(key) != null;
}

/// 更新后续播：只在「版本确实变了、且在时限内」续播一次。
void main() {
  late UpdateStateStore store;
  var now = DateTime(2026, 11, 19, 18);
  UpdateResume resume(String version) => UpdateResume(
    store,
    currentVersion: version,
    now: () => now,
    window: const Duration(minutes: 5),
  );

  setUp(() {
    store = UpdateStateStore(_MemoryStore());
    now = DateTime(2026, 11, 19, 18);
  });

  test('点更新后 5 分钟内打开新版本：续播，且标记只用一次', () async {
    await resume('v0.18.212-selftest').mark();
    now = now.add(const Duration(minutes: 4));
    expect(await resume('v0.18.213-selftest').consume(), isTrue);
    expect(await resume('v0.18.213-selftest').consume(), isFalse);
    expect(store.resumeAfterUpdateAt, isNull);
  });

  test('版本没变（系统安装器里取消了）：不续播并清除标记', () async {
    await resume('v0.18.212-selftest').mark();
    now = now.add(const Duration(minutes: 1));
    expect(await resume('v0.18.212-selftest').consume(), isFalse);
    expect(store.resumeAfterUpdateAt, isNull);
  });

  test('超过时限或时钟倒退：不续播', () async {
    await resume('v1').mark();
    now = now.add(const Duration(minutes: 6));
    expect(await resume('v2').consume(), isFalse);

    await resume('v1').mark();
    now = now.subtract(const Duration(hours: 1));
    expect(await resume('v2').consume(), isFalse);
  });

  test('没有标记：什么都不做', () async {
    expect(await resume('v2').consume(), isFalse);
  });
}
