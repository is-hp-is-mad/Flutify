import 'package:flutter/widgets.dart';

/// 文本尺寸实测：给固定高度的容器（卡架、网格行）算高度用。
///
/// 按当前字号缩放（MediaQuery.textScaler）实测单行高度；样本含中文，
/// 中文回退字体的行高通常大于拉丁字体，按它算才不会在中文标题下溢出。
class TextMetrics {
  TextMetrics._();

  static const String _sample = 'Ag汉字';

  static double lineHeight(BuildContext context, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: _sample, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }
}
