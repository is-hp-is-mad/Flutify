import 'package:flutter/widgets.dart';

import 'perf_flags.dart';

/// 设置页「动画调试」里可以临时关闭的动画 / 特效。
///
/// 只用于定位掉帧：逐项关闭后观察是否变流畅，就能知道是哪一类开销造成的。
enum DebugToggle {
  /// 所有过渡动画（等同系统「移除动画」，并入全局 disableAnimations）。
  allMotion,

  /// 歌词行的对焦渐变（缩放 / 模糊 / 透明度补间）。
  lyricsLineMotion,

  /// 切行时的滚动与整列位移动画。
  lyricsScroll,

  /// 歌词区上下边缘渐隐用的整块离屏遮罩。
  lyricsMask,

  /// 所有 LiquidGlass 的 BackdropFilter（每帧复制并模糊下方画面）。
  glassBackdrop,

  /// 流动背景（Android 原生纹理 / 其他平台的 Flutter 背景）。
  flowingBackground;

  /// 构建时已用 `--dart-define` 关闭（见 [PerfFlags]），运行时无法再打开。
  bool get compileTimeOff => switch (this) {
    DebugToggle.lyricsMask => PerfFlags.noLyricsMask,
    DebugToggle.glassBackdrop => PerfFlags.noBackdrop,
    DebugToggle.flowingBackground => PerfFlags.staticBackground,
    _ => false,
  };
}

/// 运行时的临时关闭状态。只存在内存里：重启应用后全部恢复，不会忘记关着。
class DebugToggles extends ChangeNotifier {
  DebugToggles._();

  static final DebugToggles instance = DebugToggles._();

  final Set<DebugToggle> _off = <DebugToggle>{};

  /// [toggle] 当前是否处于「已关闭」（运行时关闭，或构建时已关闭）。
  bool isOff(DebugToggle toggle) =>
      toggle.compileTimeOff || _off.contains(toggle);

  /// 是否有运行时关闭的项（不含构建时关闭的）。
  bool get anyOff => _off.isNotEmpty;

  void setOff(DebugToggle toggle, bool off) {
    final changed = off ? _off.add(toggle) : _off.remove(toggle);
    if (changed) notifyListeners();
  }

  void reset() {
    if (_off.isEmpty) return;
    _off.clear();
    notifyListeners();
  }

  /// 在 build 里读取：登记依赖，开关变化时自动重建。
  /// 没有 [DebugTogglesScope]（例如单元测试）时退回全局实例。
  static DebugToggles of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DebugTogglesScope>()
          ?.notifier ??
      instance;
}

class DebugTogglesScope extends InheritedNotifier<DebugToggles> {
  const DebugTogglesScope({
    super.key,
    required DebugToggles toggles,
    required super.child,
  }) : super(notifier: toggles);
}

/// 挂在 MaterialApp.builder 里：提供 [DebugToggles]，并把「关闭所有过渡动画」
/// 通过 [builder] 的 `motionOff` 并入全局 MediaQuery.disableAnimations。
class DebugTogglesBinding extends StatelessWidget {
  const DebugTogglesBinding({super.key, required this.builder});

  final Widget Function(BuildContext context, bool motionOff) builder;

  @override
  Widget build(BuildContext context) => DebugTogglesScope(
    toggles: DebugToggles.instance,
    child: ListenableBuilder(
      listenable: DebugToggles.instance,
      builder: (context, _) => builder(
        context,
        DebugToggles.instance.isOff(DebugToggle.allMotion),
      ),
    ),
  );
}
