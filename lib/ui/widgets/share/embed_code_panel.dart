import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../models/share_target.dart';
import 'copied_flash.dart';
import 'embed_web_view.dart';

/// 分享面板的「嵌入代码」区：尺寸 / 主题选项 → 真实嵌入播放器（WebView）→ iframe 代码 → 复制按钮。
///
/// 选项变化时预览与代码同步更新；代码块可选中、可滚动，复制后按钮就地变为「已复制」。
class EmbedCodePanel extends StatefulWidget {
  final ShareTarget target;

  const EmbedCodePanel({super.key, required this.target});

  @override
  State<EmbedCodePanel> createState() => _EmbedCodePanelState();
}

class _EmbedCodePanelState extends State<EmbedCodePanel> with CopiedFlash {
  EmbedSize _size = EmbedSize.standard;
  bool _dark = false;

  /// 代码块最大高度：约 5 行，更长时在块内滚动。
  static const double _codeMaxHeight = 104;

  String get _code => widget.target.embedCode(size: _size, dark: _dark);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final l10n = context.l10n;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(
          title: l10n.shareEmbedTitle,
          subtitle: l10n.shareEmbedSubtitle,
        ),
        const SizedBox(height: 14),
        // 选项：窄屏时自动换行，避免横向溢出
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<EmbedSize>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: EmbedSize.standard,
                  label: Text(l10n.shareEmbedStandard),
                ),
                ButtonSegment(
                  value: EmbedSize.compact,
                  label: Text(l10n.shareEmbedCompact),
                ),
              ],
              selected: {_size},
              onSelectionChanged: (value) =>
                  setState(() => _size = value.first),
            ),
            FilterChip(
              label: Text(l10n.shareEmbedDark),
              mouseCursor: SystemMouseCursors.click,
              avatar: Icon(
                Icons.dark_mode_rounded,
                size: 18,
                color: _dark ? null : colorScheme.onSurfaceVariant,
              ),
              showCheckmark: false,
              selected: _dark,
              shape: tokens.pillShape,
              onSelected: (value) => setState(() => _dark = value),
            ),
          ],
        ),
        const SizedBox(height: 14),
        EmbedWebView(
          key: ValueKey(widget.target.embedUrl(dark: _dark)),
          target: widget.target,
          size: _size,
          dark: _dark,
        ),
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(maxHeight: _codeMaxHeight),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLowest,
            borderRadius: tokens.radius(16),
            border: Border.all(
              color: colorScheme.outlineVariant.withAlpha(120),
            ),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _code,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'Consolas',
                fontFamilyFallback: const ['Menlo', 'Roboto Mono', 'monospace'],
                height: 1.45,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: M3EButton.icon(
            decoration: M3EButtonDecoration(
              backgroundColor: WidgetStatePropertyAll(tokens.accent),
              foregroundColor: WidgetStatePropertyAll(tokens.onAccent),
            ),
            onPressed: () => copyAndFlash(_code),
            icon: AnimatedSwitcher(
              duration: context.motion(const Duration(milliseconds: 220)),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                copied ? Icons.check_rounded : Icons.content_copy_rounded,
                key: ValueKey(copied),
                size: 18,
              ),
            ),
            label: Text(copied ? l10n.shareCopied : l10n.shareEmbedCopy),
          ),
        ),
      ],
    );
  }
}

/// 区块标题：代码图标徽章 + 标题 + 说明。
class _Heading extends StatelessWidget {
  final String title;
  final String subtitle;

  const _Heading({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tokens.accent.withAlpha(36),
            borderRadius: tokens.radius(12),
          ),
          child: Icon(Icons.code_rounded, size: 20, color: tokens.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
