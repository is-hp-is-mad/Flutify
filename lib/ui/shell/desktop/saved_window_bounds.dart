import 'dart:convert';
import 'dart:ui';

/// 记住的窗口位置 / 大小（逻辑像素）与最大化状态。
///
/// 最大化时 [rect] 保存的是最大化之前的普通窗口位置，还原时先放到这里再最大化，
/// 这样取消最大化也能回到原来的位置。
class SavedWindowBounds {
  final Rect rect;
  final bool maximized;

  const SavedWindowBounds(this.rect, {this.maximized = false});

  /// 解析持久化字符串；空串、损坏或尺寸不合理时返回 null（使用默认居中）。
  static SavedWindowBounds? decode(String raw, {required Size minimumSize}) {
    if (raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final values = [json['x'], json['y'], json['w'], json['h']];
      if (values.any((v) => v is! num || !v.isFinite)) return null;
      final [x, y, w, h] = values.cast<num>().map((v) => v.toDouble()).toList();
      if (w < minimumSize.width || h < minimumSize.height) return null;
      return SavedWindowBounds(Rect.fromLTWH(x, y, w, h), maximized: json['maximized'] == true);
    } catch (_) {
      return null;
    }
  }

  String encode() =>
      jsonEncode({'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height, 'maximized': maximized});

  /// 窗口顶部标题栏中段落在某块显示器的可见区域内，才认为能找回窗口（可拖动）。
  /// 显示器拔掉 / 分辨率变化后窗口可能落在屏幕外，此时应回到默认居中。
  bool isReachableOn(List<Rect> displays) {
    final grip = Offset(rect.center.dx, rect.top + 20);
    return displays.any((d) => d.contains(grip));
  }
}
