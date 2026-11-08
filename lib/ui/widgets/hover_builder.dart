import 'package:flutter/material.dart';

/// 鼠标悬停状态构建器：只重建自身子树，适合列表行、卡片上的悬停效果。
///
/// 触屏设备没有悬停事件，[builder] 始终收到 `false`，调用方需自行决定移动端的默认显示。
class HoverBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;

  /// 悬停状态翻转时回调（只在变化时触发，不在 build 里跑副作用）。
  final ValueChanged<bool>? onHoverChanged;

  const HoverBuilder({
    super.key,
    required this.builder,
    this.cursor = MouseCursor.defer,
    this.onHoverChanged,
  });

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovered = false;

  void _set(bool value) {
    if (_hovered != value) {
      setState(() => _hovered = value);
      widget.onHoverChanged?.call(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => _set(true),
      onExit: (_) => _set(false),
      child: widget.builder(context, _hovered),
    );
  }
}
