import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 「已复制」就地反馈：复制后按钮短暂变为对勾 + 「已复制」，再自动恢复。
///
/// 分享面板内的复制都用它代替 SnackBar——反馈出现在用户刚点的位置，
/// 不会被弹窗遮住，也不会和底部播放栏争位置。
mixin CopiedFlash<T extends StatefulWidget> on State<T> {
  /// 反馈持续时间。
  static const Duration hold = Duration(milliseconds: 1800);

  bool _copied = false;
  Timer? _timer;

  bool get copied => _copied;

  /// 写入剪贴板并进入「已复制」状态；连续点击会重新计时。
  Future<void> copyAndFlash(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HapticFeedback.selectionClick();
    _timer?.cancel();
    setState(() => _copied = true);
    _timer = Timer(hold, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
