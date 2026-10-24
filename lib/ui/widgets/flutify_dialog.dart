import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

/// 放进 `showDialog` 的 MD3E 对话框。
///
/// [M3EDialog] 只是一块带背景与圆角的容器，本身不居中、不限高；直接作为 `showDialog`
/// 的 builder 返回值时会被对话框路由拉伸到整个窗口。这里居中并留出屏幕边距，
/// 让它按内容大小显示（等同于 `M3EDialog.show` 的布局）。参数与 [M3EDialog] 一致。
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
          child: M3EDialog(
            title: title,
            icon: icon,
            content: content,
            contentPadding: contentPadding,
            actions: actions,
            topDivider: topDivider,
            bottomDivider: bottomDivider,
          ),
        ),
      ),
    );
  }
}
