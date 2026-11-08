import 'package:flutter/material.dart';

/// 两块面板之间的拖动条（占用 8px 间距本身，不额外占宽）。
///
/// 悬停时光标变为左右调整，并在中间显示一条 2px 的细线提示可拖动；
/// 拖动中实时回调水平位移，松手时回调 [onDragEnd]（用于持久化宽度）。
class PanelResizeHandle extends StatefulWidget {
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  const PanelResizeHandle({super.key, required this.onDrag, required this.onDragEnd});

  @override
  State<PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<PanelResizeHandle> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: SizedBox(
          width: 8,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 2,
              margin: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(
                color: active ? Theme.of(context).colorScheme.outline : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
