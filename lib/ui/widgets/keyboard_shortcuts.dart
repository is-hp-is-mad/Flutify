import 'package:flutter/services.dart' show KeyEvent, HardwareKeyboard, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../models/shortcut_settings.dart';
import '../../providers/preferences_provider.dart';
import '../shell/desktop/desktop_window.dart';

/// 桌面快捷键的按平台策略与提示文字渲染。
///
/// macOS 桌面真实运行（[DesktopWindow.macNativeWindow]）时主修饰键用 ⌘（Cmd）替代 Ctrl，
/// 提示文字按 macOS 惯例紧凑排（⌘K / ⌥⇧B）；Windows / Linux / 测试（DesktopWindow 未
/// 初始化）一律沿用 Ctrl / Alt 版本，行为与之前逐字节一致。
///
/// 纯单键快捷键（Space、F11、Esc、悬停曲目的字母键）不走这里，各平台不变。
abstract final class PlatformShortcuts {
  /// 主修饰键是否取 macOS 的 meta（⌘）。
  static bool get useMeta => DesktopWindow.macNativeWindow;

  /// 「主修饰键 + [key]」的按平台快捷键：macOS 为 ⌘+key，其余为 Ctrl+key。
  static SingleActivator primary(
    LogicalKeyboardKey key, {
    bool shift = false,
  }) => SingleActivator(key, control: !useMeta, meta: useMeta, shift: shift);

  /// 修饰键名按平台替换为键帽标签：Ctrl → ⌘ / Ctrl，Alt → ⌥ / Alt，Shift → ⇧ / Shift。
  static String cap(String key) => switch (key) {
    'Ctrl' => useMeta ? '⌘' : key,
    'Alt' => useMeta ? '⌥' : key,
    'Shift' => useMeta ? '⇧' : key,
    _ => key,
  };

  /// 快捷键提示拆成键帽序列（快捷键一览用）：'Ctrl K'、'Alt+Shift+B' 均可，
  /// 修饰键名按平台替换（见 [cap]）。
  static List<String> keyCaps(String hint) => [
    for (final token in hint.split(RegExp(r'[+ ]')))
      if (token.isNotEmpty) cap(token),
  ];

  /// 单行快捷键提示（菜单右侧标注用）：macOS 按惯例去掉分隔符、按 ⌥⇧⌘ 顺序紧凑排
  /// （'Ctrl K' → ⌘K，'Alt+Shift+B' → ⌥⇧B）；其余平台原样返回。
  static String hintText(String hint) {
    if (!useMeta) return hint;
    final caps = keyCaps(hint);
    caps.sort(_macCapOrder);
    return caps.join();
  }

  /// macOS 修饰键显示顺序：⌥(0) ⇧(1) ⌘(2)，其余键排在最后。
  static int _macRank(String capStr) => switch (capStr) {
    '⌥' => 0,
    '⇧' => 1,
    '⌘' => 2,
    _ => 3,
  };

  static int _macCapOrder(String a, String b) => _macRank(a) - _macRank(b);
}

/// 用户可自定义的快捷键：默认键位随平台（macOS 主修饰键是 ⌘）。
abstract final class AppShortcuts {
  /// 当前设置；测试等没有 [PreferencesProvider] 的环境用默认键位。
  static ShortcutSettings of(BuildContext context) =>
      context.read<PreferencesProvider?>()?.prefs.shortcuts ??
      const ShortcutSettings();

  static KeyCombo _primary(LogicalKeyboardKey key) => KeyCombo(
    key.keyId,
    control: !PlatformShortcuts.useMeta,
    meta: PlatformShortcuts.useMeta,
  );

  static KeyCombo defaultOf(AppShortcut action) => switch (action) {
    AppShortcut.playPause => KeyCombo(LogicalKeyboardKey.space.keyId),
    AppShortcut.next => _primary(LogicalKeyboardKey.arrowRight),
    AppShortcut.previous => _primary(LogicalKeyboardKey.arrowLeft),
    AppShortcut.volumeUp => _primary(LogicalKeyboardKey.arrowUp),
    AppShortcut.volumeDown => _primary(LogicalKeyboardKey.arrowDown),
    AppShortcut.shuffle => _primary(LogicalKeyboardKey.keyS),
    AppShortcut.repeat => _primary(LogicalKeyboardKey.keyR),
    AppShortcut.search => _primary(LogicalKeyboardKey.keyK),
    AppShortcut.back => KeyCombo(LogicalKeyboardKey.arrowLeft.keyId, alt: true),
    AppShortcut.forward => KeyCombo(
      LogicalKeyboardKey.arrowRight.keyId,
      alt: true,
    ),
    AppShortcut.immersive => KeyCombo(LogicalKeyboardKey.f11.keyId),
  };

  /// 生效的键位；用户清除了这个快捷键时为 null。
  static KeyCombo? comboOf(ShortcutSettings settings, AppShortcut action) =>
      settings.local.containsKey(action)
      ? settings.local[action]
      : defaultOf(action);

  static SingleActivator? activator(
    ShortcutSettings settings,
    AppShortcut action,
  ) => comboOf(settings, action)?.activator;

  /// 键帽文字，修饰键按平台替换（见 [PlatformShortcuts.cap]）。
  static List<String> capsOf(KeyCombo combo) => [
    for (final cap in combo.caps)
      cap == 'Meta' ? (PlatformShortcuts.useMeta ? '⌘' : 'Win') : PlatformShortcuts.cap(cap),
  ];

  /// 按键事件是否就是 [combo]（修饰键要完全一致）。
  static bool matches(KeyCombo combo, KeyEvent event) {
    final kb = HardwareKeyboard.instance;
    return event.logicalKey.keyId == combo.keyId &&
        kb.isControlPressed == combo.control &&
        kb.isAltPressed == combo.alt &&
        kb.isShiftPressed == combo.shift &&
        kb.isMetaPressed == combo.meta;
  }

  /// 已经用了 [combo] 的其他动作。
  static AppShortcut? ownerOf(
    ShortcutSettings settings,
    KeyCombo combo, {
    required AppShortcut except,
    required bool global,
  }) {
    for (final action in AppShortcut.values) {
      if (action == except) continue;
      final other = global
          ? settings.effectiveGlobal[action]
          : comboOf(settings, action);
      if (other == combo) return action;
    }
    return null;
  }
}
