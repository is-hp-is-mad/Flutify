import 'dart:math';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 将包含的 Sliver 在视口垂直方向裁剪，使其绘制内容不会超出指定顶部位置（例如吸顶栏下方）。
class SliverTopClip extends SingleChildRenderObjectWidget {
  final double top;

  const SliverTopClip({super.key, required this.top, required Widget sliver})
      : super(child: sliver);

  @override
  RenderSliverTopClip createRenderObject(BuildContext context) {
    return RenderSliverTopClip(top: top);
  }

  @override
  void updateRenderObject(BuildContext context, RenderSliverTopClip renderObject) {
    renderObject.top = top;
  }
}

class RenderSliverTopClip extends RenderProxySliver {
  double _top;

  RenderSliverTopClip({required double top}) : _top = top;

  double get top => _top;
  set top(double value) {
    if (_top == value) return;
    _top = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child != null && child!.geometry!.visible) {
      // offset.dy 是当前 Sliver 在当前绘制坐标系中的起始 Y 偏移量。
      // 我们确保子 Sliver 绘制的内容不越过屏幕上的 top 像素线。
      final double clipTopInSliver = max(0.0, top - offset.dy);
      final double width = constraints.crossAxisExtent;
      final double height = constraints.remainingPaintExtent;

      if (clipTopInSliver >= height) {
        // 完全被裁出视口，无需绘制
        layer = null;
        return;
      }

      final Rect clipRect = Rect.fromLTRB(0.0, clipTopInSliver, width, height);

      layer = context.pushClipRect(
        needsCompositing,
        offset,
        clipRect,
        super.paint,
        oldLayer: layer as ClipRectLayer?,
      );
    }
  }
}
