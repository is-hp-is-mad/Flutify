import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'hyper_glass_renderer.dart' show HyperGlassRenderer, shaderRoot;

/// `miuix.theme.token.ShadowToken`. The values reach `View.setMiShadow` unscaled, so they are physical pixels
/// of a 3x screen.
class ShadowToken {
  const ShadowToken(this.offsetY, this.radius);
  final double offsetY, radius;

  static const color = Color(0x59000000), dispersion = 0.5;
  static const low = ShadowToken(0, 44);
  static const regular = ShadowToken(2, 64);
}

/// libhwui's view shadow around a rounded [child]. Its `smoothstep(0.1, 1, alpha)` is why the system's shadow is so
/// much lighter than its #59000000 suggests: the darkest point is about 12%, which a BoxShadow cannot express.
class ViewShadow extends SingleChildRenderObjectWidget {
  const ViewShadow({
    super.key,
    this.token = ShadowToken.regular,
    required this.radius,
    this.opacity = 1,
    this.hollow = false,
    super.child,
  });
  final ShadowToken token;
  final double radius, opacity;

  /// Leaves the area under [child] out of the shadow: a BackdropFilter child would otherwise blur it into itself.
  final bool hollow;

  static ui.FragmentProgram? _program;

  /// Called by `HyperGlass.init`.
  static Future<void> load() async {
    _program = await ui.FragmentProgram.fromAsset('${shaderRoot}shaders/mi_view_shadow.frag');
  }

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderViewShadow()
    ..token = token
    ..radius = radius
    ..opacity = opacity
    ..hollow = hollow;

  @override
  void updateRenderObject(BuildContext context, _RenderViewShadow ro) => ro
    ..token = token
    ..radius = radius
    ..opacity = opacity
    ..hollow = hollow
    ..markNeedsPaint();
}

class _RenderViewShadow extends RenderProxyBox {
  ShadowToken token = ShadowToken.regular;
  double radius = 0, opacity = 1;
  bool hollow = false;
  ui.FragmentShader? _shader;
  ui.Image? _image;

  @override
  void paint(PaintingContext context, Offset offset) {
    final program = ViewShadow._program;
    if (program != null && opacity > 0.001 && !size.isEmpty) {
      final blur = token.radius / 3;
      // past this the gaussian is under the smoothstep's 0.1 edge
      final reach = blur * 3;
      final area = (Offset.zero & size).inflate(reach);
      final s = program.fragmentShader();
      var i = 0;
      void f(double v) => s.setFloat(i++, v);
      f(reach + size.width / 2);
      f(reach + size.height / 2);
      f(ShadowToken.color.r);
      f(ShadowToken.color.g);
      f(ShadowToken.color.b);
      f(ShadowToken.color.a);
      f(0);
      f(token.offsetY / 3);
      f(blur);
      f(radius);
      f(ShadowToken.dispersion);
      f(size.width / 2);
      f(size.height / 2);
      f(opacity);
      final canvas = context.canvas;
      final paint = Paint()..shader = s;
      if (hollow) {
        canvas
          ..save()
          ..clipPath(
            Path()
              ..fillType = PathFillType.evenOdd
              ..addRect(area.shift(offset))
              ..addRRect(RRect.fromRectAndRadius(offset & size, Radius.circular(radius))),
          );
      }
      if (ui.ImageFilter.isShaderFilterSupported) {
        // Impeller's FlutterFragCoord is in device space, so it is rendered at the origin first
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(Offset.zero & area.size, paint);
        final pic = rec.endRecording();
        final img = pic.toImageSync(area.width.ceil(), area.height.ceil());
        pic.dispose();
        canvas.drawImage(img, offset + area.topLeft, Paint());
        HyperGlassRenderer.deferDispose(image: _image);
        _image = img;
      } else {
        canvas
          ..save()
          ..translate(offset.dx + area.left, offset.dy + area.top)
          ..drawRect(Offset.zero & area.size, paint)
          ..restore();
      }
      if (hollow) canvas.restore();
      HyperGlassRenderer.deferDispose(shader: _shader);
      _shader = s; // the recorded frame still reads it
    }
    super.paint(context, offset);
  }

  @override
  void dispose() {
    HyperGlassRenderer.deferDispose(shader: _shader, image: _image);
    _shader = null;
    _image = null;
    super.dispose();
  }
}
