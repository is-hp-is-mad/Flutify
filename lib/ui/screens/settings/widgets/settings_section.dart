import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3ESwitch;

/// iOS「设置」风格的分组：小号灰色组标题 + 圆角卡片，行之间用发丝分隔线。
class SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  /// 卡片下方的小号灰色说明（iOS 分组页脚）。
  final String? footer;

  const SettingsSection({super.key, required this.title, required this.children, this.footer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Material(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: context.tokens.radius(16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, thickness: 0.5, indent: 16, color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                footer!,
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

/// 分组内的一行：标题 + 可选说明 + 右侧控件。
///
/// [below] 为较宽的控件（如分段选择器）：行宽 < [wideBreakpoint]（手机）时放在标题下方整行显示，
/// 更宽（桌面）时移到右侧、限宽 [_wideControlMaxWidth]，与 macOS「系统设置」一致。
class SettingsTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? below;
  final VoidCallback? onTap;

  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.below,
    this.onTap,
  });

  static const double wideBreakpoint = 460;
  static const double _wideControlMaxWidth = 300;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );

    Widget row(Widget? side) => Row(
          children: [
            Expanded(child: heading),
            if (side != null) ...[const SizedBox(width: 12), side],
          ],
        );

    final Widget body = below == null
        ? row(trailing)
        : LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= wideBreakpoint) {
                final width = (constraints.maxWidth * 0.55).clamp(0.0, _wideControlMaxWidth);
                return row(SizedBox(width: width, child: below));
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [row(trailing), const SizedBox(height: 10), below!],
              );
            },
          );

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 12, 12), child: body),
    );
    if (onTap == null) return content;
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      borderRadius: context.tokens.radius(16),
      child: content,
    );
  }
}

/// 开关行：整行可点。
class SettingsSwitchTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: SettingsTile(
        title: title,
        subtitle: subtitle,
        onTap: () => onChanged(!value),
        trailing: Semantics(toggled: value, child: M3ESwitch(value: value, onChanged: onChanged)),
      ),
    );
  }
}
