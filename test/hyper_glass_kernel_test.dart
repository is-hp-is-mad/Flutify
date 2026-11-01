import 'package:flutter_test/flutter_test.dart';
import 'package:hyper_glass/hyper_glass.dart';

void main() {
  test('默认柔光玻璃参数走 4 次采样的融合路径', () {
    // glass shader 只保留了半径 1 的融合采样；默认参数若变宽会悄悄退回非融合的多 pass 路径
    final kernel = fusedRefractKernel(const GlassFilter());
    expect(kernel, isNotNull);
    expect(kernel!.radius, 1);
  });
}
