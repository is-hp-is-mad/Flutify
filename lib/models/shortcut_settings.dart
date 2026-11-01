import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;

/// 可以自定义的快捷键。
enum AppShortcut {
  playPause,
  next,
  previous,
  volumeUp,
  volumeDown,
  shuffle,
  repeat,
  search,
  back,
  forward,
  immersive;

  /// 能设为全局快捷键（窗口不在前台也生效）的动作：只有播放控制。
  bool get supportsGlobal => index <= AppShortcut.volumeDown.index;
}

/// 一组按键。[physicalId] 只有全局快捷键用（系统注册按物理键），可能缺失。
@immutable
class KeyCombo {
  final int keyId;
  final int? physicalId;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  const KeyCombo(
    this.keyId, {
    this.physicalId,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  LogicalKeyboardKey get key => LogicalKeyboardKey(keyId);

  SingleActivator get activator => SingleActivator(
    key,
    control: control,
    alt: alt,
    shift: shift,
    meta: meta,
  );

  bool get hasCommandModifier => control || alt || meta;

  bool get isFunctionKey {
    final f1 = LogicalKeyboardKey.f1.keyId;
    final f24 = LogicalKeyboardKey.f24.keyId;
    return keyId >= f1 && keyId <= f24;
  }

  /// 不带修饰键的普通键会吞掉输入框里的文字，只有播放 / 暂停（输入框聚焦时会让路）可以用。
  bool usableFor(AppShortcut action, {bool global = false}) {
    if (hasCommandModifier || isFunctionKey) return true;
    return !global && action == AppShortcut.playPause;
  }

  /// 键帽文字，修饰键在前，名字用 Ctrl / Alt / Shift / Meta。
  List<String> get caps => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Meta',
    _keyName,
  ];

  String get _keyName {
    final k = key;
    if (k == LogicalKeyboardKey.space) return 'Space';
    if (k == LogicalKeyboardKey.arrowUp) return '↑';
    if (k == LogicalKeyboardKey.arrowDown) return '↓';
    if (k == LogicalKeyboardKey.arrowLeft) return '←';
    if (k == LogicalKeyboardKey.arrowRight) return '→';
    final label = k.keyLabel;
    if (label.trim().isNotEmpty) return label.toUpperCase();
    return k.debugName ?? '#$keyId';
  }

  Map<String, Object?> toJson() => {
    'key': keyId,
    if (physicalId != null) 'physical': physicalId,
    if (control) 'control': true,
    if (alt) 'alt': true,
    if (shift) 'shift': true,
    if (meta) 'meta': true,
  };

  static KeyCombo? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    if (key is! int) return null;
    final physical = json['physical'];
    return KeyCombo(
      key,
      physicalId: physical is int ? physical : null,
      control: json['control'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
      meta: json['meta'] == true,
    );
  }

  /// 物理键不参与比较：同一按键组合在不同键盘布局下 id 不同，但对用户是同一组。
  @override
  bool operator ==(Object other) =>
      other is KeyCombo &&
      other.keyId == keyId &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(keyId, control, alt, shift, meta);
}

/// 用户自定义的快捷键（存在 `AppPreferences` 里）。
///
/// [local] 只记改过的项，没有键表示用默认键位，值为 null 表示用户清除了这个快捷键；
/// 默认键位随平台变（见 `AppShortcuts`），所以不写进设置。
/// 解析规则与 `AppPreferences` 相同：缺失或写坏的字段回退到默认值。
@immutable
class ShortcutSettings {
  final Map<AppShortcut, KeyCombo?> local;
  final Map<AppShortcut, KeyCombo> global;
  final bool globalEnabled;

  const ShortcutSettings({
    this.local = const {},
    this.global = const {},
    this.globalEnabled = false,
  });

  /// 开启全局快捷键时的默认键位，与网易云音乐等播放器的习惯一致，不和常见软件冲突。
  static const Map<AppShortcut, KeyCombo> defaultGlobal = {
    AppShortcut.playPause: KeyCombo(
      0x00000000070, // p
      physicalId: 0x00070013,
      control: true,
      alt: true,
    ),
    AppShortcut.next: KeyCombo(
      0x00100000303, // arrowRight
      physicalId: 0x0007004f,
      control: true,
      alt: true,
    ),
    AppShortcut.previous: KeyCombo(
      0x00100000302, // arrowLeft
      physicalId: 0x00070050,
      control: true,
      alt: true,
    ),
    AppShortcut.volumeUp: KeyCombo(
      0x00100000304, // arrowUp
      physicalId: 0x00070052,
      control: true,
      alt: true,
    ),
    AppShortcut.volumeDown: KeyCombo(
      0x00100000301, // arrowDown
      physicalId: 0x00070051,
      control: true,
      alt: true,
    ),
  };

  /// 实际生效的全局键位。
  Map<AppShortcut, KeyCombo> get effectiveGlobal =>
      global.isEmpty ? defaultGlobal : global;

  ShortcutSettings copyWith({
    Map<AppShortcut, KeyCombo?>? local,
    Map<AppShortcut, KeyCombo>? global,
    bool? globalEnabled,
  }) => ShortcutSettings(
    local: local ?? this.local,
    global: global ?? this.global,
    globalEnabled: globalEnabled ?? this.globalEnabled,
  );

  Map<String, Object?> toJson() => {
    'local': {
      for (final e in local.entries) e.key.name: e.value?.toJson(),
    },
    'global': {
      for (final e in global.entries) e.key.name: e.value.toJson(),
    },
    'globalEnabled': globalEnabled,
  };

  static ShortcutSettings fromJson(Object? json) {
    if (json is! Map) return const ShortcutSettings();
    AppShortcut? action(Object? name) {
      for (final a in AppShortcut.values) {
        if (a.name == name) return a;
      }
      return null;
    }

    final local = <AppShortcut, KeyCombo?>{};
    final rawLocal = json['local'];
    if (rawLocal is Map) {
      for (final e in rawLocal.entries) {
        final a = action(e.key);
        if (a == null) continue;
        final combo = KeyCombo.fromJson(e.value);
        // 写坏的项当成没改过；只有明确的 null 才是用户清除
        if (combo != null || e.value == null) local[a] = combo;
      }
    }
    final global = <AppShortcut, KeyCombo>{};
    final rawGlobal = json['global'];
    if (rawGlobal is Map) {
      for (final e in rawGlobal.entries) {
        final a = action(e.key);
        final combo = KeyCombo.fromJson(e.value);
        if (a != null && combo != null && a.supportsGlobal) global[a] = combo;
      }
    }
    return ShortcutSettings(
      local: local,
      global: global,
      globalEnabled: json['globalEnabled'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutSettings &&
      mapEquals(other.local, local) &&
      mapEquals(other.global, global) &&
      other.globalEnabled == globalEnabled;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(local.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAllUnordered(global.entries.map((e) => Object.hash(e.key, e.value))),
    globalEnabled,
  );
}
