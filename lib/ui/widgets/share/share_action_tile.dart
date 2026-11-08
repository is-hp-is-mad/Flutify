import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import 'copied_flash.dart';

/// 分享面板的快捷操作卡片（复制链接 / 复制 URI / 网页打开）。
///
/// MD3E 风格：色调容器 + 图标徽章；复制成功时徽章由圆形形变为圆角方形、
/// 图标换成对勾、文字换成「已复制」，卡片底色同步染上强调色。
class ShareActionTile extends StatefulWidget {
  final IconData icon;
  final String label;

  /// 点击后要复制的文本；为空时只执行 [onTap]（如「网页打开」）。
  final String? copyText;

  /// 自定义动作；返回非空文本时复制它并展示「已复制」（如打开浏览器失败、退回复制链接）。
  final Future<String?> Function()? onTap;

  const ShareActionTile({super.key, required this.icon, required this.label, this.copyText, this.onTap});

  @override
  State<ShareActionTile> createState() => _ShareActionTileState();
}

class _ShareActionTileState extends State<ShareActionTile> with CopiedFlash {
  /// 图标徽章边长。
  static const double _badge = 44;

  Future<void> _handleTap() async {
    final text = widget.copyText;
    if (text != null) {
      await copyAndFlash(text);
      return;
    }
    final fallback = await widget.onTap?.call();
    if (fallback != null && mounted) await copyAndFlash(fallback);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final duration = context.motion(const Duration(milliseconds: 260));
    final accent = tokens.accent;

    return Semantics(
      button: true,
      label: widget.label,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: copied
              ? Color.alphaBlend(accent.withAlpha(40), colorScheme.surfaceContainerHighest)
              : colorScheme.surfaceContainerHighest,
          borderRadius: tokens.radius(20),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: tokens.radius(20),
            mouseCursor: widget.copyText != null || widget.onTap != null
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            onTap: _handleTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: duration,
                    curve: Curves.easeOutBack,
                    width: _badge,
                    height: _badge,
                    decoration: BoxDecoration(
                      color: copied ? accent : accent.withAlpha(36),
                      // 圆形 → 圆角方形：MD3E 的形状形变反馈
                      borderRadius: BorderRadius.circular(copied ? tokens.corner(14) : _badge / 2),
                    ),
                    child: AnimatedSwitcher(
                      duration: duration,
                      transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                      child: Icon(
                        copied ? Icons.check_rounded : widget.icon,
                        key: ValueKey(copied),
                        size: 22,
                        color: copied ? tokens.onAccent : accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: duration,
                    child: Text(
                      copied ? context.l10n.shareCopied : widget.label,
                      key: ValueKey(copied),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
