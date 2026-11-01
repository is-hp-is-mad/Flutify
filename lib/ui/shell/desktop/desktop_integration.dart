import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../../models/shortcut_settings.dart';
import 'desktop_window.dart';

/// 全局快捷键：窗口不在前台也生效，由系统注册。
class GlobalHotkeys {
  GlobalHotkeys._();

  static ShortcutSettings? _applied;

  /// Linux 不支持：见 packages/hotkey_manager_linux/FLUTIFY_PATCH.md。
  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS);

  /// 按 [settings] 重新注册；没有变化时什么都不做。[handlers] 给出每个动作的回调。
  /// 返回注册失败（多半被其他软件占用）的动作。
  static Future<List<AppShortcut>> apply(
    ShortcutSettings settings,
    Map<AppShortcut, VoidCallback> handlers,
  ) async {
    if (!supported || !DesktopWindow.enabled || settings == _applied) {
      return const [];
    }
    _applied = settings;
    final failed = <AppShortcut>[];
    try {
      await hotKeyManager.unregisterAll();
    } catch (e) {
      debugPrint('[hotkey] 注销失败：$e');
    }
    if (!settings.globalEnabled) return failed;
    for (final entry in settings.effectiveGlobal.entries) {
      final handler = handlers[entry.key];
      if (handler == null) continue;
      final combo = entry.value;
      final physical = combo.physicalId;
      try {
        await hotKeyManager.register(
          HotKey(
            identifier: entry.key.name,
            key: physical != null ? PhysicalKeyboardKey(physical) : combo.key,
            modifiers: [
              if (combo.control) HotKeyModifier.control,
              if (combo.alt) HotKeyModifier.alt,
              if (combo.shift) HotKeyModifier.shift,
              if (combo.meta) HotKeyModifier.meta,
            ],
          ),
          keyDownHandler: (_) => handler(),
        );
      } catch (e) {
        debugPrint('[hotkey] ${entry.key.name} 注册失败：$e');
        failed.add(entry.key);
      }
    }
    return failed;
  }
}

/// Windows 系统托盘：开启「关闭时最小化到托盘」后显示图标，右键菜单控制播放和退出。
class DesktopTray with TrayListener {
  DesktopTray._();

  static final DesktopTray instance = DesktopTray._();

  static const String _iconAsset = 'assets/tray/tray.ico';

  bool _shown = false;
  Map<String, VoidCallback> _actions = const {};

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// 按 [enabled] 显示或移除托盘图标，并同步关闭按钮的行为。
  Future<void> apply({
    required bool enabled,
    required List<(String, String?, VoidCallback)> items,
  }) async {
    if (!supported || !DesktopWindow.enabled) return;
    DesktopWindow.closeToTray = enabled;
    if (!enabled) {
      if (!_shown) return;
      _shown = false;
      trayManager.removeListener(this);
      await trayManager.destroy();
      return;
    }
    try {
      if (!_shown) {
        _shown = true;
        trayManager.addListener(this);
        await trayManager.setIcon(_iconAsset);
        await trayManager.setToolTip('Flutify');
        DesktopWindow.addBeforeCloseHook(trayManager.destroy);
      }
      _actions = {for (final (key, _, action) in items) key: action};
      await trayManager.setContextMenu(
        Menu(
          items: [
            for (final (key, label, _) in items)
              label == null
                  ? MenuItem.separator()
                  : MenuItem(key: key, label: label),
          ],
        ),
      );
    } catch (e) {
      // 托盘建不起来时不能隐藏窗口，否则用户再也找不回它
      debugPrint('[tray] 初始化失败：$e');
      DesktopWindow.closeToTray = false;
    }
  }

  @override
  void onTrayIconMouseDown() => DesktopWindow.showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) => _actions[menuItem.key]?.call();
}
