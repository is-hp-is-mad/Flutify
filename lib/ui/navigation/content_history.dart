import 'package:flutter/material.dart';

/// 内容区的「后退 / 前进」历史（桌面顶栏的 ‹ › 按钮）。
///
/// Navigator 本身只有后退栈；这里作为 [NavigatorObserver] 记录被「后退」弹出的页面，
/// 前进时用原来的 builder 重新压栈。规则与浏览器一致：
/// - 后退：弹出当前页，并把它放入前进栈；
/// - 前进：从前进栈取出页面重新打开；
/// - 用户打开任何新页面：清空前进栈。
class ContentHistory extends NavigatorObserver with ChangeNotifier {
  final List<WidgetBuilder> _forward = [];
  bool _replaying = false;
  bool _goingBack = false;

  bool get canGoBack => navigator?.canPop() ?? false;
  bool get canGoForward => _forward.isNotEmpty;

  void back() {
    final nav = navigator;
    if (nav == null || !nav.canPop()) return;
    _goingBack = true;
    nav.pop();
    _goingBack = false;
  }

  void forward() {
    final nav = navigator;
    if (nav == null || _forward.isEmpty) return;
    final builder = _forward.removeLast();
    _replaying = true;
    nav.push(MaterialPageRoute<void>(builder: builder));
    _replaying = false;
  }

  /// 回到根页面（点击「主页」或再次点击当前导航项），前进栈一并清空。
  void popToRoot() {
    navigator?.popUntil((route) => route.isFirst);
    _forward.clear();
    notifyListeners();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_replaying && route is PageRoute) _forward.clear();
    _notifyLater();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_goingBack && route is MaterialPageRoute) _forward.add(route.builder);
    _notifyLater();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _notifyLater();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _notifyLater();

  /// 观察回调发生在 Navigator 构建 / 布局期间，推迟到帧末再通知监听者重建。
  void _notifyLater() => WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
}
