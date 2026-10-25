import 'package:flutter/material.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../liquid_artwork_background.dart';
import 'hyper_menu_route.dart';
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
    final hyper = context.tokens.hyperMaterial;
    final glass = GlassMenuScope.of(context);
    if (hyper) {
      // 澎湃 OS 4 弹出菜单：从按钮本身变形展开（见 HyperMenuRoute）
      final navigator = Navigator.of(context, rootNavigator: true);
      return navigator.push(
        HyperMenuRoute<T>(
          anchor: _anchorRect(context, overlay, position),
          items: items,
          theme: _menuTheme(context),
          capturedThemes: InheritedTheme.capture(
            from: context,
            to: navigator.context,
          ),
        ),
      );
    }
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

  /// 菜单变形的起点（Overlay 坐标）：位置贴着触发组件时（按钮菜单）就是组件本身，
  /// 否则（右键菜单）是指针处的一个小方块。
  static Rect _anchorRect(BuildContext context, RenderBox overlay, Offset position) {
    final local = overlay.globalToLocal(position);
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(overlay),
        Offset.zero & box.size,
      );
      if (rect.inflate(2).contains(local)) return rect;
    }
    return Rect.fromCenter(center: local, width: 24, height: 24);
  }

  /// 柔光玻璃菜单的主题：播放页里按流动背景的实际亮度选深 / 浅，其余地方用应用主题。
  static ThemeData _menuTheme(BuildContext context) {
    final app = Theme.of(overlayContext(context));
    final lum = LiquidArtworkBackground.luminance.value;
    if (!GlassMenuScope.of(context) || lum == null) return app;
    final brightness = lum < 0.4 ? Brightness.dark : Brightness.light;
    if (brightness == app.brightness) return app;
    final scheme = ColorScheme.fromSeed(
      seedColor: app.colorScheme.primary,
      brightness: brightness,
    );
    // 文字、图标颜色也要跟着换，否则会沿用应用主题的深字 / 浅字
    return app.copyWith(
      brightness: brightness,
      colorScheme: scheme,
      textTheme: app.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      iconTheme: IconThemeData(color: scheme.onSurface),
      popupMenuTheme: PopupMenuThemeData(
        labelTextStyle: WidgetStatePropertyAll(
          app.textTheme.labelLarge?.copyWith(color: scheme.onSurface),
        ),
      ),
    );
  }

  /// 根 Navigator 的 Overlay 所在 context：这里的 Theme 是应用本身的主题。
  static BuildContext overlayContext(BuildContext context) =>
      Navigator.of(context, rootNavigator: true).overlay!.context;

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

/// 与 [PopupMenuButton] 参数一致的菜单按钮：材质为「柔光玻璃」时从按钮本身弹出澎湃 OS 4
/// 菜单（[DesktopMenu.show] → HyperMenuRoute），否则原样使用 [PopupMenuButton]。
class FlutifyPopupMenuButton<T> extends StatelessWidget {
  const FlutifyPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.initialValue,
    this.tooltip,
    this.icon,
    this.child,
    this.position,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final T? initialValue;
  final String? tooltip;
  final Widget? icon;
  final Widget? child;
  final PopupMenuPosition? position;

  @override
  Widget build(BuildContext context) {
    if (!context.tokens.hyperMaterial) {
      return PopupMenuButton<T>(
        itemBuilder: itemBuilder,
        onSelected: onSelected,
        initialValue: initialValue,
        tooltip: tooltip,
        icon: icon,
        position: position,
        child: child,
      );
    }
    return Builder(
      builder: (anchor) {
        Future<void> open() async {
          final value = await DesktopMenu.show<T>(
            anchor,
            DesktopMenu.anchorOf(anchor),
            itemBuilder(anchor),
          );
          if (value != null) onSelected?.call(value);
        }

        if (child == null) {
          return IconButton(
            icon: icon ?? const Icon(Icons.more_vert_rounded),
            tooltip: tooltip,
            onPressed: open,
          );
        }
        return Tooltip(
          message: tooltip ?? '',
          child: InkWell(
            borderRadius: context.tokens.radius(12),
            onTap: open,
            child: child,
          ),
        );
      },
    );
  }
}
