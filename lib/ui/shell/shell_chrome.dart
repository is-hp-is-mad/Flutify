import 'dart:async';

import 'package:flutter/widgets.dart';

/// 移动端外壳「边框」（底部导航 + 迷你播放栏）的显示开关与配色来源。
///
/// 全屏沉浸页（发现流）成为所在 Tab 的当前页时请求隐藏，离开当前页（上面又压了专辑页等）或销毁时撤回。
/// 自带底色的页面（艺人页、专辑页）成为当前页时通过 [ShellBackdrop] 上报底色，边框跟着换深浅与底色。
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

  /// 请求者 → 它所在的 Navigator 与页面底色；后上报的排在后面。
  final Map<Object, (NavigatorState, Color)> _backdrops = {};

  /// [owner] 上报（[color] 非空）或撤回页面底色。
  void setBackdrop(Object owner, NavigatorState? navigator, Color? color) {
    final next = navigator != null && color != null ? (navigator, color) : null;
    if (_backdrops[owner] == next) return;
    _backdrops.remove(owner);
    if (next != null) _backdrops[owner] = next;
    notifyListeners();
  }

  /// [navigator]（当前显示的 Tab）当前页的底色；没有页面上报时为 null，边框用应用主题。
  Color? backdropFor(NavigatorState? navigator) {
    Color? color;
    for (final (owner, value) in _backdrops.values) {
      if (owner == navigator) color = value;
    }
    return color;
  }

  /// [navigator]（当前显示的 Tab）上是否有页面要求隐藏边框。
  bool hiddenFor(NavigatorState? navigator) =>
      navigator != null && _hideRequests.containsValue(navigator);
}

/// 把所在页面的底色上报给外壳：本页是所在 Tab 的当前页时生效，被别的页面盖住或销毁时撤回。
class ShellBackdrop extends StatefulWidget {
  /// 页面底色；为 null 表示本页用应用主题，不上报。
  final Color? color;
  final Widget child;

  const ShellBackdrop({super.key, required this.color, required this.child});

  @override
  State<ShellBackdrop> createState() => _ShellBackdropState();
}

class _ShellBackdropState extends State<ShellBackdrop> {
  @override
  void dispose() {
    // 放到微任务里，避免在卸载树的过程中通知外壳重建。
    final chrome = ShellChrome.instance;
    final owner = this;
    scheduleMicrotask(() => chrome.setBackdrop(owner, null, null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ModalRoute.isCurrentOf 会在路由栈变化时触发重建。
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final navigator = Navigator.maybeOf(context);
    final color = isCurrent ? widget.color : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ShellChrome.instance.setBackdrop(this, navigator, color);
    });
    return widget.child;
  }
}
