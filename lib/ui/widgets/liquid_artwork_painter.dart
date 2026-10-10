import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// 流动封面背景的绘制器。配方与 Android 原生背景（AppleMusicBackgroundPlugin.kt）保持一致，
/// 两端看到的是同一种模糊：
///
/// - 在 1/[downscale] 分辨率、屏幕 1.3 倍大的离屏画布上合成：黑底 + 三份封面
///   （边长为画布长边 1.3 倍，周期 -120s / 90s / 70s 各自旋转，后两份有固定偏移），
///   封面饱和度 [saturation]；
/// - 再叠一层固定的压暗/提亮（深色 50% 黑 + 5% 白；浅色 30% 黑 + 10% 白）；
/// - 模糊半径对应 Android RenderScript 的 radius 25（σ≈10.6 个小像素），边缘夹取；
/// - 放大到屏幕 1.3 倍并居中裁切（-15% 偏移），与原生端的绘制方式相同。
///
/// 小分辨率合成 + 双线性放大，像素工作量约为屏幕分辨率下的 1/64。
class LiquidArtworkPainter extends CustomPainter {
  static const double downscale = 8;

  /// RenderScript `ScriptIntrinsicBlur` 的 σ = 0.4 * radius + 0.6，radius 取其上限 25。
  static const double blurSigma = 0.4 * 25 + 0.6;
  static const double saturation = 2.5;

  /// 每份封面的旋转周期（毫秒），负数为逆时针。与原生端一致。
  static const List<double> periodsMs = [-120000, 90000, 70000];

  /// 与原生端相同的灰度权重（Android ColorMatrix.setSaturation）。
  static const List<double> _luma = [0.213, 0.715, 0.072];

  /// 相位 = 已流动的秒数（不取模，由绘制器按各自周期换算角度）。
  final ValueListenable<double> phase;
  final Animation<double> fade;
  final ui.Image? image;

  /// 切歌淡入时垫在下面的上一张封面，按 [previousPhase] 冻结在换歌那一刻。
  final ui.Image? previous;
  final double previousPhase;
  final bool dark;

  LiquidArtworkPainter({
    required this.phase,
    required this.fade,
    required this.image,
    this.previous,
    this.previousPhase = 0,
    this.dark = true,
  }) : super(repaint: Listenable.merge([phase, fade]));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final previous = this.previous;
    if (previous != null) {
      _paintBackground(canvas, size, previous, previousPhase, 1);
    }
    final image = this.image;
    final alpha = fade.value.clamp(0.0, 1.0);
    if (image == null || alpha <= 0) return;
    _paintBackground(canvas, size, image, phase.value, alpha);
  }

  /// 合成并模糊一张背景，再按 [alpha] 铺到 [canvas]。
  void _paintBackground(
    Canvas canvas,
    Size size,
    ui.Image image,
    double elapsedSeconds,
    double alpha,
  ) {
    // 离屏画布覆盖屏幕的 1.3 倍（逻辑像素），内部按 1/downscale 缩小
    final bufW = size.width * 1.3;
    final bufH = size.height * 1.3;
    final w = math.max(1, (bufW / downscale).round());
    final h = math.max(1, (bufH / downscale).round());

    final recorder = ui.PictureRecorder();
    final offscreen = Canvas(recorder);
    // 先建带模糊的图层再缩放坐标：σ 以小像素计
    offscreen.saveLayer(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.clamp,
        ),
    );
    offscreen.scale(w / bufW, h / bufH);
    _compose(offscreen, bufW, bufH, image, elapsedSeconds);
    offscreen.restore();

    final picture = recorder.endRecording();
    final small = picture.toImageSync(w, h);
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..drawImageRect(
        small,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Rect.fromLTWH(-size.width * 0.15, -size.height * 0.15, bufW, bufH),
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Color.fromRGBO(0, 0, 0, alpha),
      )
      ..restore();
    small.dispose();
    picture.dispose();
  }

  /// 黑底 + 三份旋转封面 + 固定压暗层，坐标为 [w]×[h] 的逻辑像素。
  void _compose(
    Canvas canvas,
    double w,
    double h,
    ui.Image image,
    double elapsedSeconds,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = const Color(0xFF000000),
    );
    final side = math.max(w, h) * 1.3;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = ColorFilter.matrix(_saturationMatrix(saturation));
    final bounds = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    for (var i = 0; i < 3; i++) {
      final angle =
          (elapsedSeconds * 1000 / periodsMs[i]).remainder(1.0) * 2 * math.pi;
      canvas
        ..save()
        ..transform(_layerMatrix(i, angle, w, h, side, image).storage)
        ..drawImageRect(image, bounds, bounds, paint)
        ..restore();
    }
    // 压暗 + 轻微提亮（与原生端同序同值）
    canvas
      ..drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()..color = Color(dark ? 0x80000000 : 0x4D000000),
      )
      ..drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()..color = Color(dark ? 0x0DFFFFFF : 0x1AFFFFFF),
      );
  }

  /// 原生端 `Matrix`：缩放到 side×side → 绕其中心旋转 → 居中到画布，
  /// 第 2 份再平移 (-.95w, -.7h)，第 3 份平移 (-.5w, .7h) 后绕画布中心再转一次。
  Matrix4 _layerMatrix(
    int index,
    double angle,
    double w,
    double h,
    double side,
    ui.Image image,
  ) {
    Matrix4 about(double cx, double cy) =>
        Matrix4.translationValues(cx, cy, 0) *
        Matrix4.rotationZ(angle) *
        Matrix4.translationValues(-cx, -cy, 0);

    var m = Matrix4.diagonal3Values(side / image.width, side / image.height, 1);
    m = about(side / 2, side / 2) * m;
    m = Matrix4.translationValues((w - side) / 2, (h - side) / 2, 0) * m;
    if (index == 1) {
      m = Matrix4.translationValues(-0.95 * w, -0.7 * h, 0) * m;
    }
    if (index == 2) {
      m = Matrix4.translationValues(-0.5 * w, 0.7 * h, 0) * m;
      m = about(w / 2, h / 2) * m;
    }
    return m;
  }

  /// Android `ColorMatrix.setSaturation` 的 4x5 矩阵。
  static List<double> _saturationMatrix(double s) {
    final inv = 1 - s;
    final r = _luma[0] * inv, g = _luma[1] * inv, b = _luma[2] * inv;
    return [
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0,
      r, g, b + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  @override
  bool shouldRepaint(LiquidArtworkPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.previous != previous ||
      oldDelegate.previousPhase != previousPhase ||
      oldDelegate.dark != dark ||
      oldDelegate.phase != phase ||
      oldDelegate.fade != fade;
}
