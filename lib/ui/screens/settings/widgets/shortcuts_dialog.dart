import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/shortcut_settings.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../shell/desktop/desktop_integration.dart';
import '../../../shell/desktop/desktop_window.dart';
import '../../../widgets/app_modal.dart';
import '../../../widgets/app_switch.dart';
import '../../../widgets/flutify_dialog.dart';
import '../../../widgets/keyboard_shortcuts.dart';
import '../../../widgets/track_menu.dart';
import '../../../widgets/app_button.dart';

/// 键盘快捷键（设置页「关于」）：改键、全局快捷键，以及不能改的按键一览。
///
/// 点击键帽开始录入，按下新组合即保存；Esc 取消，Backspace 清除。
/// 修饰键键帽按平台渲染（macOS ⌘/⌥，其余 Ctrl/Alt），见 [PlatformShortcuts]。
class ShortcutsDialog extends StatefulWidget {
  const ShortcutsDialog({super.key});

  static Future<void> show(BuildContext context) => showAppDialog<void>(
    context: context,
    builder: (_) => const ShortcutsDialog(),
  );

  static String labelOf(AppLocalizations l10n, AppShortcut action) =>
      switch (action) {
        AppShortcut.playPause => l10n.shortcutPlayPause,
        AppShortcut.next => l10n.shortcutNext,
        AppShortcut.previous => l10n.shortcutPrevious,
        AppShortcut.volumeUp => l10n.shortcutVolumeUp,
        AppShortcut.volumeDown => l10n.shortcutVolumeDown,
        AppShortcut.shuffle => l10n.shortcutShuffle,
        AppShortcut.repeat => l10n.shortcutRepeat,
        AppShortcut.search => l10n.shortcutSearch,
        AppShortcut.back => l10n.shortcutBack,
        AppShortcut.forward => l10n.shortcutForward,
        AppShortcut.immersive => l10n.shortcutImmersive,
      };

  /// 不能改的按键：全屏歌词里的固定按键与悬停曲目时的字母键。
  static List<(List<String>, String)> fixedEntries(AppLocalizations l10n) => [
    // macOS 另有 ⌘⇧F（Mac 键盘上 F11 默认是「显示桌面」，要配合 fn）
    if (PlatformShortcuts.useMeta) (['⌘', '⇧', 'F'], l10n.shortcutImmersive),
    (['F11'], l10n.shortcutImmersiveMode),
    (['Esc'], l10n.shortcutExitImmersive),
    // 曲目快捷键（TrackHotkeys）：鼠标悬停在曲目行上按键
    for (final action in TrackAction.values)
      if (action.hint != null)
        (
          PlatformShortcuts.keyCaps(action.hint!),
          l10n.shortcutOnHoveredTrack(_trackLabel(l10n, action)),
        ),
  ];

  static String _trackLabel(AppLocalizations l10n, TrackAction action) =>
      switch (action) {
        TrackAction.addToPlaylist => l10n.trackAddToPlaylist,
        TrackAction.like => l10n.likeAdd,
        TrackAction.queue => l10n.trackAddToQueue,
        TrackAction.sleepTimer => l10n.sleepTimer,
        TrackAction.artist => l10n.trackGoToArtist(1),
        TrackAction.album => l10n.trackGoToAlbum,
        TrackAction.radio => l10n.trackGoToRadio,
        TrackAction.credits => l10n.trackViewCredits,
        TrackAction.share => l10n.commonShare,
      };

  @override
  State<ShortcutsDialog> createState() => _ShortcutsDialogState();
}

class _ShortcutsDialogState extends State<ShortcutsDialog> {
  /// 正在录入的项：(动作, 是否全局)。
  (AppShortcut, bool)? _recording;
  String? _problem;

  void _save(ShortcutSettings next) {
    final provider = context.read<PreferencesProvider?>();
    provider?.update(provider.prefs.copyWith(shortcuts: next));
  }

  void _start(AppShortcut action, bool global) => setState(() {
    _recording = (action, global);
    _problem = null;
  });

  void _stop() => setState(() => _recording = null);

  void _onKey(KeyDownEvent event) {
    final target = _recording;
    if (target == null) return;
    final (action, global) = target;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) return _stop();
    final settings = AppShortcuts.of(context);
    if (!global &&
        (key == LogicalKeyboardKey.backspace ||
            key == LogicalKeyboardKey.delete)) {
      _save(settings.copyWith(local: {...settings.local, action: null}));
      return _stop();
    }
    if (_modifiers.contains(key)) return; // 等主键
    final kb = HardwareKeyboard.instance;
    final combo = KeyCombo(
      key.keyId,
      physicalId: event.physicalKey.usbHidUsage,
      control: kb.isControlPressed,
      alt: kb.isAltPressed,
      shift: kb.isShiftPressed,
      meta: kb.isMetaPressed,
    );
    final l10n = context.l10n;
    if (!combo.usableFor(action, global: global)) {
      setState(() => _problem = l10n.shortcutNeedsModifier);
      return;
    }
    final owner = AppShortcuts.ownerOf(
      settings,
      combo,
      except: action,
      global: global,
    );
    if (owner != null) {
      setState(
        () => _problem = l10n.shortcutConflict(
          ShortcutsDialog.labelOf(l10n, owner),
        ),
      );
      return;
    }
    _save(
      global
          ? settings.copyWith(
              global: {...settings.effectiveGlobal, action: combo},
            )
          : settings.copyWith(local: {...settings.local, action: combo}),
    );
    _stop();
  }

  static final Set<LogicalKeyboardKey> _modifiers = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  Widget _row(BuildContext context, String label, Widget keys) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 16),
          keys,
        ],
      ),
    );
  }

  Widget _editable(AppShortcut action, KeyCombo? combo, bool global) {
    final recording = _recording == (action, global);
    return _ComboButton(
      caps: combo == null ? null : AppShortcuts.capsOf(combo),
      recording: recording,
      onTap: () => recording ? _stop() : _start(action, global),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings =
        context.select<PreferencesProvider?, ShortcutSettings?>(
          (p) => p?.prefs.shortcuts,
        ) ??
        const ShortcutSettings();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return FlutifyDialog(
      title: l10n.settingsShortcuts,
      content: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: 460,
          child: Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (_recording == null) return KeyEventResult.ignored;
              if (event is KeyDownEvent) _onKey(event);
              return KeyEventResult.handled;
            },
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.shortcutEditHint, style: muted),
                  if (_problem != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _problem!,
                      style: muted?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 6),
                  for (final action in AppShortcut.values)
                    _row(
                      context,
                      ShortcutsDialog.labelOf(l10n, action),
                      _editable(
                        action,
                        AppShortcuts.comboOf(settings, action),
                        false,
                      ),
                    ),
                  if (DesktopWindow.enabled && GlobalHotkeys.supported) ...[
                    const Divider(height: 24),
                    _row(
                      context,
                      l10n.shortcutGlobalSection,
                      AppSwitch(
                        value: settings.globalEnabled,
                        onChanged: (v) =>
                            _save(settings.copyWith(globalEnabled: v)),
                      ),
                    ),
                    Text(l10n.shortcutGlobalHint, style: muted),
                    if (settings.globalEnabled)
                      for (final action in AppShortcut.values)
                        if (action.supportsGlobal)
                          _row(
                            context,
                            ShortcutsDialog.labelOf(l10n, action),
                            _editable(
                              action,
                              settings.effectiveGlobal[action],
                              true,
                            ),
                          ),
                  ],
                  const Divider(height: 24),
                  for (final (keys, label) in ShortcutsDialog.fixedEntries(
                    l10n,
                  ))
                    _row(context, label, _Caps(keys)),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        AppButton.text(
          onPressed: () => _save(const ShortcutSettings()),
          child: Text(l10n.shortcutResetAll),
        ),
        AppButton.filled(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

/// 可点击的键帽组：录入中显示提示，没有设置时显示「未设置」。
class _ComboButton extends StatelessWidget {
  final List<String>? caps;
  final bool recording;
  final VoidCallback onTap;

  const _ComboButton({
    required this.caps,
    required this.recording,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelMedium;
    return InkWell(
      borderRadius: context.tokens.radius(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: recording
            ? Text(
                l10n.shortcutPressKeys,
                style: text?.copyWith(color: scheme.primary),
              )
            : caps == null
            ? Text(
                l10n.shortcutNone,
                style: text?.copyWith(color: scheme.onSurfaceVariant),
              )
            : _Caps(caps!),
      ),
    );
  }
}

class _Caps extends StatelessWidget {
  final List<String> keys;

  const _Caps(this.keys);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          _KeyCap(keys[i]),
        ],
      ],
    );
  }
}

/// 键帽：浅色凹槽 + 等宽数字，类似 macOS 菜单里的快捷键标注。
class _KeyCap extends StatelessWidget {
  final String label;

  const _KeyCap(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: context.tokens.radius(6),
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant, width: 1.5),
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
