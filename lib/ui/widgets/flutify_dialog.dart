import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../core/theme/flutify_tokens.dart';
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
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
    final align = icon == null
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center;
    // 柔光玻璃：容器换成 HyperOS 弹窗混色模糊，去掉实色底与投影
    final hyper = context.tokens.hyperMaterial;
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
                  textAlign: icon == null ? TextAlign.start : TextAlign.center,
                  style: theme.typeScale.headlineSmall.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          if (topDivider && hasBelowHeader)
            M3EDivider(color: scheme.outlineVariant),
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
            M3EDivider(color: scheme.outlineVariant),
          if (hasActions)
            Padding(
              padding: padding,
              child: Row(
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
      borderRadius: dialogTheme.borderRadius,
      child: dialog,
    );
  }
}
