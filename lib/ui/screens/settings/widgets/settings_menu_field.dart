import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../widgets/menu/desktop_menu.dart';

/// [SettingsMenuField] 的一个选项。
@immutable
class SettingsMenuOption<T> {
  final T value;
  final String label;
  final IconData? icon;

  const SettingsMenuOption({
    required this.value,
    required this.label,
    this.icon,
  });
}

/// 设置页的单选下拉：Material 3 Expressive 风格。
///
/// 触发器是整宽的 tonal 圆角按钮（surfaceContainerHighest），菜单是与触发器同宽的
/// surfaceContainer 圆角面板，选中项用 secondaryContainer 填充 + 对勾，
/// 焦点环用 primary 2dp 描边；圆角随设置页「圆角风格」缩放。
///
/// 取代 `DropdownButtonFormField`：后者是 M2 时代的表单下拉（输入框外观、
/// 菜单宽度与位置不跟随触发器、没有选中态容器），与其余设置项观感不一致。
/// [onChanged] 为空时整个控件禁用。
class SettingsMenuField<T> extends StatefulWidget {
  final T value;
  final List<SettingsMenuOption<T>> options;
  final ValueChanged<T>? onChanged;

  /// 读屏用的控件名（通常是所在设置项的标题）。
  final String semanticLabel;

  /// 触发器左侧图标；为空时只显示文字。
  final IconData? icon;

  /// 触发器按钮的 key，供测试定位。
  final Key? buttonKey;

  const SettingsMenuField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.semanticLabel,
    this.icon,
    this.buttonKey,
  });

  @override
  State<SettingsMenuField<T>> createState() => _SettingsMenuFieldState<T>();
}

class _SettingsMenuFieldState<T> extends State<SettingsMenuField<T>> {
  final _focusNode = FocusNode();
  bool _open = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// 柔光玻璃：从触发器本身弹出澎湃 OS 4 菜单（见 [DesktopMenu.show]），选中项打勾。
  Future<void> _openHyper(BuildContext anchor) async {
    setState(() => _open = true);
    final picked = await DesktopMenu.show<T>(
      anchor,
      DesktopMenu.anchorOf(anchor),
      [
        for (final option in widget.options)
          option.icon == null
              ? DesktopMenu.check<T>(
                  option.value,
                  option.label,
                  checked: option.value == widget.value,
                )
              : DesktopMenu.item<T>(
                  option.value,
                  option.icon!,
                  option.label,
                  iconColor: option.value == widget.value
                      ? Theme.of(anchor).colorScheme.primary
                      : null,
                ),
      ],
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (picked != null) widget.onChanged?.call(picked);
  }

  String get _currentLabel => widget.options
      .firstWhere(
        (o) => o.value == widget.value,
        orElse: () => widget.options.first,
      )
      .label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final radius = context.tokens.radius(16);
    final enabled = widget.onChanged != null;

    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        childFocusNode: _focusNode,
        crossAxisUnconstrained: false,
        alignmentOffset: const Offset(0, 4),
        onOpen: () => setState(() => _open = true),
        onClose: () => setState(() => _open = false),
        style: MenuStyle(
          minimumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 0)),
          maximumSize: WidgetStatePropertyAll(
            Size(constraints.maxWidth, double.infinity),
          ),
          backgroundColor: WidgetStatePropertyAll(colors.surfaceContainer),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: radius),
          ),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        ),
        menuChildren: [
          for (final option in widget.options)
            MenuItemButton(
              onPressed: enabled ? () => widget.onChanged!(option.value) : null,
              leadingIcon: option.icon == null ? null : Icon(option.icon),
              trailingIcon: option.value == widget.value
                  ? const Icon(Icons.check_rounded)
                  : const SizedBox(width: 24),
              style: MenuItemButton.styleFrom(
                minimumSize: const Size(0, 48),
                backgroundColor: option.value == widget.value
                    ? colors.secondaryContainer
                    : null,
                foregroundColor: option.value == widget.value
                    ? colors.onSecondaryContainer
                    : colors.onSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: context.tokens.radius(12),
                ),
              ),
              child: Text(option.label),
            ),
        ],
        builder: (context, controller, child) => Semantics(
          label: widget.semanticLabel,
          expanded: _open,
          child: FilledButton(
            key: widget.buttonKey,
            focusNode: _focusNode,
            onPressed: enabled
                ? () => context.tokens.hyperMaterial
                      ? _openHyper(context)
                      : controller.isOpen
                      ? controller.close()
                      : controller.open()
                : null,
            style:
                FilledButton.styleFrom(
                  backgroundColor: colors.surfaceContainerHighest,
                  foregroundColor: colors.onSurface,
                  textStyle: theme.textTheme.bodyLarge,
                  minimumSize: const Size.fromHeight(56),
                  padding: const EdgeInsets.all(16),
                  shape: RoundedRectangleBorder(borderRadius: radius),
                ).copyWith(
                  side: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.focused)
                        ? BorderSide(color: colors.primary, width: 2)
                        : BorderSide.none,
                  ),
                ),
            child: Row(
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon),
                  const SizedBox(width: 12),
                ],
                Expanded(child: Text(_currentLabel)),
                const SizedBox(width: 12),
                Icon(
                  _open
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
