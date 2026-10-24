import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/keyboard_shortcuts.dart';
import '../../../widgets/track_menu.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;
import '../../../widgets/flutify_dialog.dart';

/// 键盘快捷键一览（设置页「关于」）。
///
/// 与 `MainShell._shortcuts`、沉浸式歌词的按键处理保持一致；改快捷键时两处一起改。
/// 修饰键键帽按平台渲染（macOS ⌘/⌥，其余 Ctrl/Alt），见 [PlatformShortcuts]。
class ShortcutsDialog extends StatelessWidget {
  const ShortcutsDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const ShortcutsDialog(),
  );

  /// 按键组合（每个元素是一个键帽）与说明。
  static List<(List<String>, String)> entries(AppLocalizations l10n) => [
    (['Space'], l10n.shortcutPlayPause),
    ([PlatformShortcuts.cap('Ctrl'), '→'], l10n.shortcutNext),
    ([PlatformShortcuts.cap('Ctrl'), '←'], l10n.shortcutPrevious),
    ([PlatformShortcuts.cap('Ctrl'), '↑'], l10n.shortcutVolumeUp),
    ([PlatformShortcuts.cap('Ctrl'), '↓'], l10n.shortcutVolumeDown),
    ([PlatformShortcuts.cap('Ctrl'), 'S'], l10n.shortcutShuffle),
    ([PlatformShortcuts.cap('Ctrl'), 'R'], l10n.shortcutRepeat),
    ([PlatformShortcuts.cap('Ctrl'), 'K'], l10n.shortcutSearch),
    ([PlatformShortcuts.cap('Alt'), '←'], l10n.shortcutBack),
    ([PlatformShortcuts.cap('Alt'), '→'], l10n.shortcutForward),
    // macOS 另有 ⌘⇧F（Mac 键盘上 F11 默认是「显示桌面」，要配合 fn）
    if (PlatformShortcuts.useMeta) (['⌘', '⇧', 'F'], l10n.shortcutImmersive),
    (['F11'], l10n.shortcutImmersive),
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
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return FlutifyDialog(
      title: l10n.settingsShortcuts,
      content: Material(type: MaterialType.transparency, child: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (keys, label) in entries(l10n))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(label, style: theme.textTheme.bodyMedium),
                      ),
                      const SizedBox(width: 16),
                      for (var i = 0; i < keys.length; i++) ...[
                        if (i > 0) const SizedBox(width: 4),
                        _KeyCap(keys[i]),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      )),
      actions: [
        M3EButton.text(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonClose),
        ),
      ]);
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
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
