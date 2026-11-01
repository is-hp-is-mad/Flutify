import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Pressable;
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../core/theme/flutify_tokens.dart';

/// 按钮：MD3E 时就是 [M3EButton]（参数一一对应），柔光玻璃时是 miuix 的胶囊按钮
/// （按压收缩，没有水波纹和形状变形）。
class AppButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final M3EButtonStyle style;
  final M3EButtonSize size;
  final M3EButtonShape shape;
  final bool enabled;
  final M3EButtonDecoration? decoration;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;
  final String? tooltip;

  const AppButton({
    super.key,
    required this.onPressed,
    this.child,
    this.style = M3EButtonStyle.filled,
    this.size = M3EButtonSize.sm,
    this.shape = M3EButtonShape.round,
    this.enabled = true,
    this.decoration,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.tooltip,
  }) : icon = null,
       label = null;

  const AppButton.filled({
    super.key,
    required this.onPressed,
    this.child,
    this.size = M3EButtonSize.sm,
    this.shape = M3EButtonShape.round,
    this.enabled = true,
    this.decoration,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.tooltip,
  }) : style = M3EButtonStyle.filled,
       icon = null,
       label = null;

  const AppButton.outlined({
    super.key,
    required this.onPressed,
    this.child,
    this.size = M3EButtonSize.sm,
    this.shape = M3EButtonShape.round,
    this.enabled = true,
    this.decoration,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.tooltip,
  }) : style = M3EButtonStyle.outlined,
       icon = null,
       label = null;

  const AppButton.text({
    super.key,
    required this.onPressed,
    this.child,
    this.size = M3EButtonSize.sm,
    this.shape = M3EButtonShape.round,
    this.enabled = true,
    this.decoration,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.tooltip,
  }) : style = M3EButtonStyle.text,
       icon = null,
       label = null;

  const AppButton.icon({
    super.key,
    required this.onPressed,
    required Widget this.icon,
    required Widget this.label,
    this.style = M3EButtonStyle.filled,
    this.size = M3EButtonSize.sm,
    this.shape = M3EButtonShape.round,
    this.enabled = true,
    this.decoration,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.tooltip,
  }) : child = null;

  /// 柔光玻璃按钮的内容：图标 + 文字或 [child]。弹窗按钮也用它。
  Widget content() {
    final icon = this.icon;
    if (icon == null) return child ?? const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [icon, const SizedBox(width: 6), Flexible(child: label!)],
    );
  }

  double get _height => switch (size.name) {
    'xs' => 32,
    'sm' => 40,
    _ => 48,
  };

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    if (!tokens.hyperMaterial) {
      final icon = this.icon;
      if (icon != null) {
        return M3EButton.icon(
          onPressed: onPressed,
          icon: icon,
          label: label!,
          style: style,
          size: size,
          shape: shape,
          enabled: enabled,
          decoration: decoration,
          focusNode: focusNode,
          autofocus: autofocus,
          semanticLabel: semanticLabel,
          tooltip: tooltip,
        );
      }
      return M3EButton(
        onPressed: onPressed,
        style: style,
        size: size,
        shape: shape,
        enabled: enabled,
        decoration: decoration,
        focusNode: focusNode,
        autofocus: autofocus,
        semanticLabel: semanticLabel,
        tooltip: tooltip,
        child: child,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final filled = style == M3EButtonStyle.filled;
    final text = style == M3EButtonStyle.text;
    final foreground =
        decoration?.foregroundColor?.resolve(const {}) ??
        (filled
            ? scheme.onPrimary
            : text
            ? scheme.primary
            : scheme.onSurface);
    final background =
        decoration?.backgroundColor?.resolve(const {}) ??
        (filled
            ? scheme.primary
            : text
            ? Colors.transparent
            : (dark ? const Color(0x1fffffff) : const Color(0x14000000)));
    final tap = enabled ? onPressed : null;
    final height = _height;
    Widget button = Opacity(
      opacity: tap == null ? 0.4 : 1,
      child: Pressable(
        onTap: tap,
        child: Container(
          constraints: BoxConstraints(minHeight: height),
          padding: EdgeInsets.symmetric(horizontal: text ? 12 : 20),
          decoration: BoxDecoration(
            color: background,
            borderRadius: shape == M3EButtonShape.round
                ? BorderRadius.circular(height / 2)
                : tokens.radius(12),
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: foreground, size: 20),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: foreground,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: content(),
              ),
            ),
          ),
        ),
      ),
    );
    button = Semantics(
      button: true,
      enabled: tap != null,
      label: semanticLabel,
      child: MouseRegion(
        cursor: tap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: button,
      ),
    );
    final message = tooltip;
    return message == null ? button : Tooltip(message: message, child: button);
  }
}

/// 复选框：MD3E 时是 [M3ECheckbox]，柔光玻璃时是 miuix 的圆角方块。
class AppCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;

  const AppCheckbox({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    if (!tokens.hyperMaterial) {
      return M3ECheckbox(value: value, onChanged: onChanged);
    }
    final changed = onChanged;
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Opacity(
      opacity: changed == null ? 0.4 : 1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: changed == null ? null : () => changed(!value),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: value
                  ? scheme.primary
                  : (dark ? const Color(0x33ffffff) : const Color(0x14000000)),
              borderRadius: BorderRadius.circular(7),
            ),
            child: value
                ? Icon(Icons.check_rounded, color: scheme.onPrimary, size: 17)
                : null,
          ),
        ),
      ),
    );
  }
}
