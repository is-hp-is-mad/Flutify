import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../hyper_surface.dart';
import '../liquid_glass.dart';

/// 沉浸式播放器及其二级菜单使用同一玻璃表面。
class GlassMenuScope extends InheritedTheme {
  const GlassMenuScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassMenuScope>() != null;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      GlassMenuScope(child: child);

  @override
  bool updateShouldNotify(GlassMenuScope oldWidget) => false;
}

/// 桌面端弹出菜单（曲目菜单、睡眠定时器、右栏 ⋯ 菜单共用），观感对齐 Spotify 桌面端：
/// 图标 + 文字 + 右侧快捷键提示 / 二级菜单箭头。
class DesktopMenu {
  DesktopMenu._();

  /// 在全局坐标 [position] 处弹出；返回选中的值。
  static Future<T?> show<T>(
    BuildContext context,
    Offset position,
    List<PopupMenuEntry<T>> items,
  ) {
    // 菜单显示在根 Navigator 的 Overlay 里：全局坐标需换算到它的本地坐标
    // （桌面窄窗口时它在标题条之下，并不从窗口原点开始）
    final overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay!.context.findRenderObject()!
            as RenderBox;
    final local = overlay.globalToLocal(position);
    final colorScheme = Theme.of(context).colorScheme;
    final glass = GlassMenuScope.of(context);
    return showMenu<T>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromRect(
        local & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      color: glass ? Colors.transparent : colorScheme.surfaceContainerHigh,
      surfaceTintColor: glass ? Colors.transparent : null,
      elevation: glass ? 0 : 8,
      menuPadding: glass ? EdgeInsets.zero : null,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 340),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: glass ? [_GlassMenuEntry<T>(items)] : items,
    );
  }

  /// 组件左下角的全局坐标（按钮触发的菜单从这里弹出）。
  static Offset anchorOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Offset.zero;
    return box.localToGlobal(box.size.bottomLeft(Offset.zero));
  }

  /// 菜单项。[shortcut] 为右侧灰色快捷键提示；[submenu] 为 true 时右侧显示 ▸。
  static PopupMenuItem<T> item<T>(
    T value,
    IconData icon,
    String label, {
    Color? iconColor,
    String? shortcut,
    bool submenu = false,
    bool enabled = true,
  }) {
    return PopupMenuItem<T>(
      value: value,
      height: 40,
      enabled: enabled,
      child: Builder(
        builder: (context) {
          final muted = Theme.of(context).colorScheme.onSurfaceVariant;
          return Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (shortcut != null) ...[
                const SizedBox(width: 16),
                Text(
                  shortcut,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
              if (submenu) ...[
                const SizedBox(width: 8),
                Icon(Icons.arrow_right_rounded, size: 20, color: muted),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 带勾选标记的选项（例如当前生效的定时器预设）。
  static PopupMenuItem<T> check<T>(
    T value,
    String label, {
    required bool checked,
  }) {
    return PopupMenuItem<T>(
      value: value,
      height: 40,
      child: Builder(
        builder: (context) => Row(
          children: [
            SizedBox(
              width: 20,
              child: checked
                  ? Icon(
                      Icons.check_rounded,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  /// 分组小标题（不可点击），例如「排序方式」「查看方式」。
  static PopupMenuItem<T> heading<T>(String label) {
    return PopupMenuItem<T>(
      enabled: false,
      height: 32,
      child: Builder(
        builder: (context) => Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  static const PopupMenuDivider divider = PopupMenuDivider(height: 8);
}

/// 保留 showMenu 的定位、滚动、键盘导航、Esc 与外部点击关闭行为；
/// 把标准菜单项放进一个玻璃容器，避免每一行单独模糊背景。
class _GlassMenuEntry<T> extends PopupMenuEntry<T> {
  final List<PopupMenuEntry<T>> items;
  const _GlassMenuEntry(this.items);

  @override
  double get height => items.fold(12.0, (total, item) => total + item.height);

  @override
  bool represents(T? value) => items.any((item) => item.represents(value));

  @override
  State<_GlassMenuEntry<T>> createState() => _GlassMenuEntryState<T>();
}

class _GlassMenuEntryState<T> extends State<_GlassMenuEntry<T>> {
  @override
  Widget build(BuildContext context) {
    final items = Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: widget.items),
      ),
    );
    if (context.tokens.hyperMaterial) {
      // 柔光玻璃：HyperOS 弹出菜单材质，跟随当前深浅色，不再强制深色
      return HyperBlendSurface(
        material: HyperBlendSurface.menu(context),
        borderRadius: context.tokens.radius(24),
        child: items,
      );
    }
    final theme = Theme.of(context);
    final dark = ColorScheme.fromSeed(
      seedColor: theme.colorScheme.primary,
      brightness: Brightness.dark,
    );
    return Theme(
      data: theme.copyWith(
        colorScheme: dark,
        textTheme: theme.textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        popupMenuTheme: PopupMenuThemeData(
          textStyle: theme.textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
        dividerColor: Colors.white24,
      ),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(20),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.30),
          child: items,
        ),
      ),
    );
  }
}
