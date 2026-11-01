import 'dart:convert';

import 'package:flutify_app/models/app_preferences.dart';
import 'package:flutify_app/models/shortcut_settings.dart';
import 'package:flutify_app/ui/widgets/keyboard_shortcuts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ctrlN = KeyCombo(LogicalKeyboardKey.keyN.keyId, control: true);

  test('旧设置没有快捷键字段时用默认键位', () {
    final prefs = AppPreferences.decode(jsonEncode({'startPage': 'library'}));
    expect(prefs.shortcuts, const ShortcutSettings());
    expect(prefs.closeToTray, isFalse);
  });

  test('改键、清除与全局键位都能往返序列化', () {
    final settings = ShortcutSettings(
      local: {AppShortcut.next: ctrlN, AppShortcut.shuffle: null},
      global: {AppShortcut.playPause: ctrlN},
      globalEnabled: true,
    );
    final prefs = AppPreferences(shortcuts: settings, closeToTray: true);
    final back = AppPreferences.decode(prefs.encode());
    expect(back.shortcuts, settings);
    expect(back.closeToTray, isTrue);
    expect(back, prefs);
    expect(AppShortcuts.comboOf(back.shortcuts, AppShortcut.next), ctrlN);
    expect(AppShortcuts.comboOf(back.shortcuts, AppShortcut.shuffle), isNull);
    expect(
      AppShortcuts.comboOf(back.shortcuts, AppShortcut.repeat),
      AppShortcuts.defaultOf(AppShortcut.repeat),
    );
  });

  test('写坏的字段回退到默认，不影响其他项', () {
    final settings = ShortcutSettings.fromJson({
      'local': {
        'next': 'bad',
        'nonsense': {'key': 1},
        'repeat': {'key': LogicalKeyboardKey.keyN.keyId, 'control': true},
      },
      'global': 'bad',
      'globalEnabled': 'yes',
    });
    expect(settings.local.keys, [AppShortcut.repeat]);
    expect(settings.global, isEmpty);
    expect(settings.globalEnabled, isFalse);
  });

  test('普通字母键只有播放暂停可用，全局必须带修饰键', () {
    final n = KeyCombo(LogicalKeyboardKey.keyN.keyId);
    final f5 = KeyCombo(LogicalKeyboardKey.f5.keyId);
    expect(n.usableFor(AppShortcut.next), isFalse);
    expect(n.usableFor(AppShortcut.playPause), isTrue);
    expect(n.usableFor(AppShortcut.playPause, global: true), isFalse);
    expect(f5.usableFor(AppShortcut.next), isTrue);
    expect(ctrlN.usableFor(AppShortcut.next, global: true), isTrue);
  });

  test('冲突检测忽略自身，能查到占用者', () {
    const settings = ShortcutSettings();
    final next = AppShortcuts.defaultOf(AppShortcut.next);
    expect(
      AppShortcuts.ownerOf(
        settings,
        next,
        except: AppShortcut.next,
        global: false,
      ),
      isNull,
    );
    expect(
      AppShortcuts.ownerOf(
        settings,
        next,
        except: AppShortcut.shuffle,
        global: false,
      ),
      AppShortcut.next,
    );
  });

  test('默认全局键位只含播放控制，数值与 Flutter 按键常量一致', () {
    expect(
      ShortcutSettings.defaultGlobal[AppShortcut.next]!.keyId,
      LogicalKeyboardKey.arrowRight.keyId,
    );
    expect(
      ShortcutSettings.defaultGlobal[AppShortcut.next]!.physicalId,
      PhysicalKeyboardKey.arrowRight.usbHidUsage,
    );
    expect(
      ShortcutSettings.defaultGlobal[AppShortcut.previous]!.physicalId,
      PhysicalKeyboardKey.arrowLeft.usbHidUsage,
    );
    expect(
      ShortcutSettings.defaultGlobal[AppShortcut.volumeUp]!.keyId,
      LogicalKeyboardKey.arrowUp.keyId,
    );
    expect(
      ShortcutSettings.defaultGlobal[AppShortcut.volumeDown]!.keyId,
      LogicalKeyboardKey.arrowDown.keyId,
    );
    expect(
      ShortcutSettings.defaultGlobal[AppShortcut.playPause]!.keyId,
      LogicalKeyboardKey.keyP.keyId,
    );
    expect(
      ShortcutSettings.defaultGlobal[AppShortcut.playPause]!.physicalId,
      PhysicalKeyboardKey.keyP.usbHidUsage,
    );
    expect(
      ShortcutSettings.defaultGlobal.keys.every((a) => a.supportsGlobal),
      isTrue,
    );
  });
}
