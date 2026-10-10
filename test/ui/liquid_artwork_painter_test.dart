import 'dart:ui' as ui;

import 'package:flutify_app/ui/widgets/liquid_artwork_painter.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ui.Image image;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 128, 128),
      ui.Paint()..color = const ui.Color(0xFFE0457B),
    );
    image = await recorder.endRecording().toImage(128, 128);
  });

  /// 用绘制器画到一张图上，返回不透明像素数。
  Future<int> paintedPixels(Size size, {double fade = 1, ui.Image? art}) async {
    final painter = LiquidArtworkPainter(
      phase: ValueNotifier(0.25),
      fade: AlwaysStoppedAnimation(fade),
      image: art,
    );
    final recorder = ui.PictureRecorder();
    painter.paint(ui.Canvas(recorder), size);
    final result = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
    final bytes = (await result.toByteData())!;
    var opaque = 0;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      if (bytes.getUint8(i) > 0) opaque++;
    }
    return opaque;
  }

  test('paints blurred artwork across wide and tall layouts', () async {
    for (final size in const [Size(1600, 900), Size(390, 844)]) {
      expect(await paintedPixels(size, art: image), greaterThan(0), reason: '$size');
    }
  });

  test('paints nothing before the artwork loads or while fully faded out', () async {
    const size = Size(400, 300);
    expect(await paintedPixels(size), 0);
    expect(await paintedPixels(size, art: image, fade: 0), 0);
  });

  /// 渲染并取中心像素 (r, g, b, a)。
  Future<List<int>> centerPixel(
    Size size, {
    ui.Image? art,
    ui.Image? previous,
    double fade = 1,
    bool dark = true,
    double phase = 0,
  }) async {
    final painter = LiquidArtworkPainter(
      phase: ValueNotifier(phase),
      fade: AlwaysStoppedAnimation(fade),
      image: art,
      previous: previous,
      dark: dark,
    );
    final recorder = ui.PictureRecorder();
    painter.paint(ui.Canvas(recorder), size);
    final result = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
    final bytes = (await result.toByteData())!;
    final i = ((size.height ~/ 2) * size.width.toInt() + size.width ~/ 2) * 4;
    return [for (var k = 0; k < 4; k++) bytes.getUint8(i + k)];
  }

  void expectNear(List<int> actual, List<double> expected, {double tolerance = 4}) {
    for (var k = 0; k < 3; k++) {
      expect(actual[k].toDouble(), closeTo(expected[k], tolerance), reason: 'channel $k of $actual');
    }
  }

  // 纯色封面 (224, 69, 123) 经 Android 原生同一流水线手算：
  // 饱和度 2.5（亮度 0.213/0.715/0.072）→ (255, 13.6, 148.7)，
  // 深色：50% 黑 + 5% 白 → x * 0.5 * 0.95 + 12.75；浅色：30% 黑 + 10% 白 → x * 0.7 * 0.9 + 25.5。
  test('matches the native recipe numerically for dark and light themes', () async {
    const size = Size(390, 844);
    expectNear(await centerPixel(size, art: image), [133.9, 19.2, 83.4]);
    expectNear(await centerPixel(size, art: image, dark: false), [186.2, 34.1, 119.2]);
  });

  test('keeps the previous artwork underneath while the new one has not faded in', () async {
    const size = Size(390, 844);
    final onlyPrevious = await centerPixel(size, art: image, previous: image, fade: 0);
    expectNear(onlyPrevious, [133.9, 19.2, 83.4]);
    expect(onlyPrevious[3], 255);
  });

  test('is a uniform blur: rotation phase does not change a solid cover', () async {
    const size = Size(390, 844);
    final a = await centerPixel(size, art: image, phase: 0);
    final b = await centerPixel(size, art: image, phase: 37.5);
    expectNear(b, [a[0].toDouble(), a[1].toDouble(), a[2].toDouble()], tolerance: 2);
  });
}
