import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Pressable;

/// 移动端柔光玻璃弹出菜单的条目（仍由 [DesktopMenu.show] → HyperMenuRoute 弹出），
/// 版式参照 iOS 长按菜单：顶部一排图标在上、文字在下的快捷操作，下面按组排列的大号菜单行，
/// 行内可带灰色副标题（专辑名、艺人名等，最多两行）。
class MobileMenu {
  MobileMenu._();

  static const double _hPad = 20;

  /// 菜单行：图标 + 标题，可选副标题；[submenu] 为 true 时右侧显示 ›。
  /// 提供 [onTap] 时点击不关闭当前菜单，而是交由回调在上方弹出子菜单。
  static PopupMenuEntry<T> item<T>(
    T value,
    IconData icon,
    String label, {
    String? subtitle,
    Color? iconColor,
    bool submenu = false,
    void Function(BuildContext itemContext)? onTap,
  }) {
    final hasSubtitle = subtitle != null && subtitle.isNotEmpty;
    final rowHeight = hasSubtitle ? 60.0 : 50.0;
    Widget buildRow(BuildContext context) {
      final scheme = Theme.of(context).colorScheme;
      return Row(
        children: [
          Icon(icon, size: 24, color: iconColor ?? scheme.onSurface),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, color: scheme.onSurface),
                ),
                if (hasSubtitle) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (submenu) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ],
      );
    }

    if (onTap != null) {
      return _MobileSubmenuEntry<T>(
        value: value,
        height: rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: _hPad),
        onTap: onTap,
        builder: buildRow,
      );
    }

    return PopupMenuItem<T>(
      value: value,
      height: rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: _hPad),
      child: Builder(builder: buildRow),
    );
  }

  /// 组与组之间的分隔线（左右留出与菜单行相同的边距）。
  static const PopupMenuDivider divider = PopupMenuDivider(
    height: 13,
    indent: _hPad,
    endIndent: _hPad,
  );
}

/// 快捷操作按钮：图标在上、文字在下。
class MobileMenuAction<T> {
  const MobileMenuAction(
    this.value,
    this.icon,
    this.label, {
    this.color,
    this.onTap,
  });

  final T value;
  final IconData icon;
  final String label;
  final Color? color;
  final void Function(BuildContext actionContext)? onTap;
}

/// 菜单顶部的一排快捷操作，点按后与普通菜单项一样以 [MobileMenuAction.value] 关闭菜单。
class MobileMenuActionRow<T> extends PopupMenuEntry<T> {
  const MobileMenuActionRow(this.actions, {super.key});

  final List<MobileMenuAction<T>> actions;

  @override
  double get height => 68;

  @override
  bool represents(T? value) => actions.any((a) => a.value == value);

  @override
  State<MobileMenuActionRow<T>> createState() => _MobileMenuActionRowState<T>();
}

class _MobileMenuActionRowState<T> extends State<MobileMenuActionRow<T>> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      child: Row(
        children: [
          for (final action in widget.actions)
            Expanded(
              child: Semantics(
                button: true,
                label: action.label,
                excludeSemantics: true,
                child: Builder(
                  builder: (actionContext) => Pressable(
                    onTap: action.onTap != null
                        ? () => action.onTap!(actionContext)
                        : () => Navigator.of(actionContext).pop(action.value),
                    child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        action.icon,
                        size: 26,
                        color: action.color ?? scheme.onSurface,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        action.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: scheme.onSurface),
                      ),
                    ],
                  ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 点击后不自动关闭当前菜单的条目，用于在现有菜单上方叠开二级菜单。
class _MobileSubmenuEntry<T> extends PopupMenuEntry<T> {
  const _MobileSubmenuEntry({
    required this.value,
    required this.height,
    required this.padding,
    required this.onTap,
    required this.builder,
  });

  final T value;
  @override
  final double height;
  final EdgeInsetsGeometry padding;
  final void Function(BuildContext itemContext) onTap;
  final WidgetBuilder builder;

  @override
  bool represents(T? value) => this.value == value;

  @override
  State<_MobileSubmenuEntry<T>> createState() => _MobileSubmenuEntryState<T>();
}

class _MobileSubmenuEntryState<T> extends State<_MobileSubmenuEntry<T>> {
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => widget.onTap(context),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.height),
        child: Padding(
          padding: widget.padding,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: widget.builder(context),
          ),
        ),
      ),
    );
  }
}
