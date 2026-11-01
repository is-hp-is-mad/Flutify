import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Pressable;
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../core/theme/flutify_tokens.dart';
import 'app_button.dart';
import 'hyper_surface.dart';

/// 放进 `showDialog` 的 MD3E 对话框。
///
/// [M3EDialog] 只是一块带背景与圆角的容器，本身不居中、不限高；直接作为 `showDialog`
/// 的 builder 返回值时会被对话框路由拉伸到整个窗口。这里居中并留出屏幕边距，
/// 让它按内容大小显示（等同于 `M3EDialog.show` 的布局）。参数与 [M3EDialog] 一致。
///
/// 外观照搬 [M3EDialog]（同一套 `M3ETheme.dialogTheme` 取值），唯一区别是内容区包在
/// [Flexible] 里：[M3EDialog] 把内容直接放进 `Column(mainAxisSize: min)`，内容拿到的是
/// 无限高度，长内容里的 [SingleChildScrollView] 无法滚动、超出窗口的部分（连同按钮）被裁掉。
/// 与 [AlertDialog] 一样，标题与按钮固定，内容区在放不下时收缩并可滚动。
class FlutifyDialog extends StatelessWidget {
  const FlutifyDialog({
    super.key,
    required this.title,
    this.icon,
    this.content,
    this.contentPadding,
    this.actions = const <Widget>[],
    this.topDivider = false,
    this.bottomDivider = false,
  });

  final String title;
  final Widget? icon;
  final Widget? content;
  final EdgeInsets? contentPadding;
  final List<Widget> actions;
  final bool topDivider;
  final bool bottomDivider;

  @override
  Widget build(BuildContext context) {
    // 柔光玻璃在手机宽度下贴底显示（miuix 的 dialog-default），桌面仍居中
    final bottom =
        context.tokens.hyperMaterial &&
        MediaQuery.sizeOf(context).width < 600;
    return Align(
      alignment: bottom ? Alignment.bottomCenter : Alignment.center,
      child: Padding(
        padding: bottom
            ? const EdgeInsets.fromLTRB(16, 24, 16, 24)
            : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: Material(
          type: MaterialType.transparency,
          child: M3EComponentTheme(builder: _buildDialog),
        ),
      ),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final theme = M3ETheme.of(context);
    final dialogTheme = theme.dialogTheme;
    final scheme = theme.colorScheme;
    final padding = dialogTheme.padding;
    final hasActions = actions.isNotEmpty;
    final hasBelowHeader = content != null || hasActions;
    // 柔光玻璃：容器换成 HyperOS 弹窗混色模糊，去掉实色底与投影；标题居中，按钮等宽铺满
    final hyper = context.tokens.hyperMaterial;
    final align = icon == null && !hyper
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center;
    final dialog = Container(
      constraints: BoxConstraints(
        minWidth: dialogTheme.minWidth,
        maxWidth: dialogTheme.maxWidth,
      ),
      decoration: hyper
          ? null
          : BoxDecoration(
              color: dialogTheme.containerColor(scheme),
              borderRadius: dialogTheme.borderRadius,
              boxShadow: M3EElevation.shadows(
                M3EElevation.level3,
                shadowColor: scheme.shadow,
              ),
            ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: align,
        children: [
          Padding(
            padding: padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: align,
              children: [
                if (icon != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(
                      color: scheme.secondary,
                      size: dialogTheme.iconSize,
                    ),
                    child: icon!,
                  ),
                  SizedBox(height: dialogTheme.gapAfterIcon),
                ],
                Text(
                  title,
                  textAlign: icon == null && !hyper
                      ? TextAlign.start
                      : TextAlign.center,
                  style: hyper
                      ? Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600,
                        )
                      : theme.typeScale.headlineSmall.copyWith(
                          color: scheme.onSurface,
                        ),
                ),
              ],
            ),
          ),
          if (topDivider && hasBelowHeader)
            hyper
                ? Divider(height: 1, color: scheme.outlineVariant)
                : M3EDivider(color: scheme.outlineVariant),
          if (content != null)
            Flexible(
              child: Padding(
                padding:
                    contentPadding ??
                    (topDivider && bottomDivider
                        ? padding
                        : EdgeInsets.only(
                            left: padding.left,
                            right: padding.right,
                          )),
                child: DefaultTextStyle(
                  style: theme.typeScale.bodyMedium.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  child: content!,
                ),
              ),
            ),
          if (bottomDivider && hasActions)
            hyper
                ? Divider(height: 1, color: scheme.outlineVariant)
                : M3EDivider(color: scheme.outlineVariant),
          if (hasActions)
            Padding(
              padding: padding,
              child: hyper
                  ? _HyperActions(actions)
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (var i = 0; i < actions.length; i++) ...[
                          if (i > 0) SizedBox(width: dialogTheme.actionGap),
                          actions[i],
                        ],
                      ],
                    ),
            ),
        ],
      ),
    );
    if (!hyper) return dialog;
    return HyperBlendSurface(
      material: HyperBlendSurface.dialog(context),
      borderRadius: BorderRadius.circular(context.tokens.corner(32)),
      bloom: HyperBlendSurface.dialogBloom(context),
      child: dialog,
    );
  }
}

/// HyperOS 弹窗按钮：高 50、圆角 25、间距 12 的等宽胶囊，主按钮在右侧、实色。
///
/// 调用方传的是 [AppButton]：这里读它的标签与回调重新排版，MD3E 下原样显示。
/// 没有实色按钮时，多个按钮里的最后一个（确认）视为主按钮；其他类型的组件原样放进去。
class _HyperActions extends StatelessWidget {
  final List<Widget> actions;

  const _HyperActions(this.actions);

  @override
  Widget build(BuildContext context) {
    final hasFilled = actions.any(
      (a) => a is AppButton && a.style == M3EButtonStyle.filled,
    );
    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: switch (actions[i]) {
              final AppButton a => _HyperAction(
                primary: hasFilled
                    ? a.style == M3EButtonStyle.filled
                    : actions.length > 1 && i == actions.length - 1,
                onTap: a.enabled ? a.onPressed : null,
                child: a.content(),
              ),
              final other => Center(child: other),
            },
          ),
        ],
      ],
    );
  }
}

class _HyperAction extends StatelessWidget {
  final bool primary;
  final VoidCallback? onTap;
  final Widget? child;

  const _HyperAction({required this.primary, this.onTap, this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final foreground = primary ? scheme.onPrimary : scheme.onSurface;
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Pressable(
        onTap: onTap,
        child: Container(
          height: 50,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(25),
            color: primary
                ? scheme.primary
                : (dark ? const Color(0x1fffffff) : const Color(0x14000000)),
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: foreground, size: 20),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: foreground,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: FittedBox(fit: BoxFit.scaleDown, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
