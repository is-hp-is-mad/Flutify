import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 柔光玻璃的图标：把 HyperOS 图标字形打补丁进 Material 图标字体，以 `MaterialIcons` 字族名注册。
///
/// 运行时注册的字体优先于打包的字体，所以所有 `Icons.x` 不用改调用点就换了字形；没有替换的图标保持
/// Material 字形。字体由 tool/brand/gen_hyper_icons.py 生成。
/// 引擎不能注销字体：从柔光玻璃切回 MD3E 后，图标要到下次启动才恢复。
abstract final class HyperIcons {
  static const String _asset = 'assets/fonts/HyperMaterialIcons.otf';

  static Future<void>? _loading;

  /// 可重复调用。载入失败时什么都不变，继续用 Material 图标。
  static Future<void> ensure() => _loading ??= () async {
    try {
      final loader = FontLoader('MaterialIcons')..addFont(rootBundle.load(_asset));
      await loader.load();
    } catch (e) {
      debugPrint('[hyper_glass] 图标字体载入失败：$e');
    }
  }();
}
