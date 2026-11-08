import 'package:flutter/material.dart';

/// 渐变轨道滑杆（取色器用）：轨道本身就是取值范围的颜色预览，白边圆形滑块显示当前色。
///
/// 支持点按跳转与拖动；值域固定为 0~1。
class GradientTrackSlider extends StatelessWidget {
  final double value;
  final List<Color> colors;
  final Color thumbColor;
  final ValueChanged<double> onChanged;

  const GradientTrackSlider({
    super.key,
    required this.value,
    required this.colors,
    required this.thumbColor,
    required this.onChanged,
  });

  static const double _height = 28;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        // 滑块中心可达范围：两端各留半个滑块，滑块不会超出轨道
        const half = _height / 2;
        final usable = (width - _height).clamp(1.0, double.infinity);
        void update(double dx) => onChanged(((dx - half) / usable).clamp(0.0, 1.0));

        return MouseRegion(
          // 与 Material Slider 的 clickable 默认一致
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => update(d.localPosition.dx),
            onHorizontalDragStart: (d) => update(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
            child: SizedBox(
              height: _height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: colors),
                        borderRadius: BorderRadius.circular(half),
                      ),
                    ),
                  ),
                  Positioned(
                    left: value.clamp(0.0, 1.0) * usable,
                    top: 0,
                    child: Container(
                      width: _height,
                      height: _height,
                      decoration: BoxDecoration(
                        color: thumbColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4, offset: const Offset(0, 1))],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
