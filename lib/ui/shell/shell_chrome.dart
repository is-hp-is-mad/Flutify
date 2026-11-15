import 'package:flutter/widgets.dart';

/// 移动端外壳「边框」（底部导航 + 迷你播放栏）的显示开关。
///
/// 全屏沉浸页（发现流）成为所在 Tab 的当前页时请求隐藏，离开当前页（上面又压了专辑页等）或销毁时撤回。
/// 请求按 Tab 的 Navigator 记录：外壳只看当前显示的 Tab，切到别的 Tab 时边框照常显示。
class ShellChrome extends ChangeNotifier {
  ShellChrome._();

  static final ShellChrome instance = ShellChrome._();

  /// 请求者 → 它所在的 Navigator。
  final Map<Object, NavigatorState> _hideRequests = {};

  /// [owner] 请求（[hide] 为 true）或撤回隐藏；[navigator] 为 owner 所在的 Tab Navigator。
  void request(Object owner, NavigatorState? navigator, {required bool hide}) {
    final changed = hide && navigator != null
        ? _hideRequests[owner] != navigator
        : _hideRequests.containsKey(owner);
    if (!changed) return;
    if (hide && navigator != null) {
      _hideRequests[owner] = navigator;
    } else {
      _hideRequests.remove(owner);
    }
    notifyListeners();
  }

  /// [navigator]（当前显示的 Tab）上是否有页面要求隐藏边框。
  bool hiddenFor(NavigatorState? navigator) =>
      navigator != null && _hideRequests.containsValue(navigator);
}
