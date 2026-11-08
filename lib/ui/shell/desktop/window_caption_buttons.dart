import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../../l10n/l10n.dart';
import 'desktop_window.dart';
import 'snap_layout_bridge.dart';

/// Windows 11 风格的窗口按钮组：最小化 / 最大化（还原）/ 关闭。
///
/// - 每个按钮 46 宽（默认 40 高），图形用 CustomPainter 以 1px 细线绘制（对齐 Segoe Fluent Icons 的比例）；
/// - 悬停为半透明底色，关闭按钮悬停为系统红 #C42B1C、图形变白；
/// - 监听窗口最大化状态，切换「最大化 / 向下还原」图形。
class WindowCaptionButtons extends StatefulWidget {
  /// 按钮高度：桌面顶栏用 40，窄窗口标题条用更矮的 32。
  final double height;

  const WindowCaptionButtons({super.key, this.height = 40});

  /// 三个按钮的总宽度，顶栏据此在右侧留出空位。
  static const double width = _CaptionButton.width * 3;

  @override
  State<WindowCaptionButtons> createState() => _WindowCaptionButtonsState();
}

class _WindowCaptionButtonsState extends State<WindowCaptionButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          tooltip: l10n.windowMinimize,
          glyph: _Glyph.minimize,
          height: widget.height,
          onPressed: windowManager.minimize,
        ),
        // Windows 11：悬停弹出分屏布局，悬停 / 按下 / 点击由原生端接管（见 SnapLayoutBridge）
        SnapLayoutAnchor(
          child: _CaptionButton(
            tooltip: _maximized ? l10n.windowRestore : l10n.windowMaximize,
            glyph: _maximized ? _Glyph.restore : _Glyph.maximize,
            height: widget.height,
            onPressed: DesktopWindow.toggleMaximize,
            nativeState: true,
          ),
        ),
        _CaptionButton(
          tooltip: l10n.windowClose,
          glyph: _Glyph.close,
          destructive: true,
          height: widget.height,
          onPressed: windowManager.close,
        ),
      ],
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

class _CaptionButton extends StatefulWidget {
  final String tooltip;
  final _Glyph glyph;
  final bool destructive;
  final double height;
  final VoidCallback onPressed;

  /// 悬停 / 按下状态同时取原生端报告的值（最大化按钮在分屏布局区域内收不到指针事件）。
  final bool nativeState;

  const _CaptionButton({
    required this.tooltip,
    required this.glyph,
    required this.height,
    required this.onPressed,
    this.destructive = false,
    this.nativeState = false,
  });

  static const double width = 46;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _pressed = false;

  static const Color _closeRed = Color(0xFFC42B1C);

  @override
  Widget build(BuildContext context) {
    if (!widget.nativeState) return _build(context, _hover, _pressed);
    return ListenableBuilder(
      listenable: Listenable.merge([SnapLayoutBridge.hovered, SnapLayoutBridge.pressed]),
      builder: (context, _) => _build(
        context,
        _hover || SnapLayoutBridge.hovered.value,
        _pressed || SnapLayoutBridge.pressed.value,
      ),
    );
  }

  Widget _build(BuildContext context, bool hover, bool pressed) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color background;
    final Color foreground;
    if (widget.destructive && (hover || pressed)) {
      background = pressed ? _closeRed.withAlpha(230) : _closeRed;
      foreground = Colors.white;
    } else {
      background = pressed
          ? colorScheme.onSurface.withAlpha(20)
          : hover
              ? colorScheme.onSurface.withAlpha(14)
              : Colors.transparent;
      foreground = colorScheme.onSurface.withAlpha(hover ? 255 : 210);
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = _pressed = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: _CaptionButton.width,
            height: widget.height,
            color: background,
            child: CustomPaint(painter: _GlyphPainter(widget.glyph, foreground)),
          ),
        ),
      ),
    );
  }
}

/// 10×10 的线性图形，居中绘制在按钮内；坐标取 .5 使 1px 线条落在像素中心。
class _GlyphPainter extends CustomPainter {
  final _Glyph glyph;
  final Color color;

  _GlyphPainter(this.glyph, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..isAntiAlias = glyph == _Glyph.close;
    final o = Offset((size.width / 2).floorToDouble() - 5 + 0.5, (size.height / 2).floorToDouble() - 5 + 0.5);

    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(o + const Offset(0, 5), o + const Offset(10, 5), paint);
      case _Glyph.maximize:
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(o.dx, o.dy, 10, 10), const Radius.circular(1.5)),
          paint..isAntiAlias = true,
        );
      case _Glyph.restore:
        paint.isAntiAlias = true;
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(o.dx, o.dy + 2, 8, 8), const Radius.circular(1.5)),
          paint,
        );
        final back = Path()
          ..moveTo(o.dx + 2, o.dy + 2)
          ..lineTo(o.dx + 2, o.dy + 1)
          ..quadraticBezierTo(o.dx + 2, o.dy, o.dx + 3, o.dy)
          ..lineTo(o.dx + 9, o.dy)
          ..quadraticBezierTo(o.dx + 10, o.dy, o.dx + 10, o.dy + 1)
          ..lineTo(o.dx + 10, o.dy + 7)
          ..quadraticBezierTo(o.dx + 10, o.dy + 8, o.dx + 9, o.dy + 8)
          ..lineTo(o.dx + 8, o.dy + 8);
        canvas.drawPath(back, paint);
      case _Glyph.close:
        canvas.drawLine(o, o + const Offset(10, 10), paint);
        canvas.drawLine(o + const Offset(10, 0), o + const Offset(0, 10), paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
