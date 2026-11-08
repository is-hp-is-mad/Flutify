import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../../models/app_preferences.dart';
import '../../../services/storage_service.dart';
import 'window_bounds_memory.dart';

/// 桌面窗口外观：隐藏系统标题栏，由顶栏自绘（拖动区 + 最小化 / 最大化 / 关闭）。
/// macOS 保留原生交通灯按钮浮在窗口左上角（见 init 中 windowButtonVisibility 分支），
/// 不渲染 Windows 风格的自绘窗口按钮。
///
/// 只在 Windows / macOS / Linux 的真实运行中启用；Widget 测试和移动端
/// [enabled] 为 false，顶栏不渲染窗口按钮、不调用任何原生通道。
class DesktopWindow {
  DesktopWindow._();

  static bool _enabled = false;

  /// 自绘标题栏是否生效。
  static bool get enabled => debugEnabledOverride ?? _enabled;

  /// 测试用：启用真实的窗口手势，并由测试接管 window_manager 原生通道。
  @visibleForTesting
  static bool? debugEnabledOverride;

  /// 是否运行在「macOS 原生窗口按钮」模式：原生交通灯浮在左上角，红色关闭按钮只隐藏
  /// 窗口（音乐继续播放），真正退出走 Cmd+Q。窗口 chrome / 快捷键 / 原生菜单统一按它分支；
  /// 依赖 [enabled]，Widget 测试（init 未跑）恒为 false。
  static bool get macNativeWindow =>
      debugMacNativeWindowOverride ?? (_enabled && !kIsWeb && Platform.isMacOS);

  /// 测试用：在任意平台模拟 / 关闭「macOS 原生窗口按钮」模式（⌘ 快捷键、原生菜单栏等分支）。
  @visibleForTesting
  static bool? debugMacNativeWindowOverride;

  /// macOS 原生交通灯在左上角占用的宽度；顶栏 / 窄窗口标题条的左侧内容需为它留白。
  /// 为原生交通灯的约 20pt 左边距、三个按钮及其间距留白（见 TrafficLightAligner）。
  static const double macTrafficLightsInset = 96;

  /// 窗口最小尺寸：可缩到手机宽度，窄于 `ShellBreakpoints.desktop` 时切换为移动端布局，
  /// 便于在桌面上直接调试手机界面。
  static const Size minimumSize = Size(360, 600);

  /// 当前是否处于系统全屏（沉浸式歌词）；全屏时 `WindowFrame` 隐藏窗口按钮与标题条。
  static final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  /// 系统全屏切换进行中（含退出后的尺寸刷新）。
  ///
  /// 在此期间渲染 BackdropFilter 会让引擎合成器在窗口尺寸重排时访问冲突
  /// （flutter_windows.dll 0xc0000005，WER dump 确认栈全在引擎内），
  /// `LiquidGlass` 监听它，在切换窗口期暂时退化为无模糊的玻璃。
  static final ValueNotifier<bool> fullscreenTransition = ValueNotifier(false);

  /// 沉浸式歌词正以「仅铺满窗口」方式显示：`WindowFrame` 不加窄窗口标题条，
  /// 窗口按钮以深色样式浮在右上角（沉浸式背景始终是深色）。
  static final ValueNotifier<bool> immersiveWindow = ValueNotifier(false);

  /// 在 runApp 之前调用。开启「记住窗口大小和位置」时，在窗口显示前就放到上次的位置（不闪一下再跳）。
  static Future<void> init(StorageService storage) async {
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    await windowManager.ensureInitialized();
    bool remember() =>
        AppPreferences.decode(storage.preferencesJson).rememberWindow;
    final saved = remember()
        ? await WindowBoundsMemory.restorable(storage, minimumSize: minimumSize)
        : null;
    final options = WindowOptions(
      size: saved?.rect.size ?? const Size(1360, 860),
      minimumSize: minimumSize,
      center: saved == null,
      title: 'Flutify',
      titleBarStyle: TitleBarStyle.hidden,
      // macOS 隐藏标题栏时保留原生交通灯（红黄绿）浮在左上角；Windows / Linux 完全自绘窗口按钮
      windowButtonVisibility: Platform.isMacOS,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (saved != null) await windowManager.setPosition(saved.rect.topLeft);
      await windowManager.show();
      await windowManager.focus();
      // 最大化必须在窗口显示之后调用：显示前最大化会被 WindowOptions 的尺寸覆盖，
      // 结果以「最大化前的普通窗口尺寸」启动（表现为记住位置失效）。
      // 刚 show 完窗口尚未就绪，立即 maximize 可能被丢弃：稍等片刻并重试一次
      if (saved?.maximized ?? false) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await windowManager.maximize();
        if (!await windowManager.isMaximized()) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await windowManager.maximize();
        }
      }
    });
    // 监听器由 windowManager 持有，随进程存活
    final memory = WindowBoundsMemory(
      storage,
      minimumSize: minimumSize,
      enabled: remember,
      fullScreen: () => fullScreen.value,
    )..attach();
    _boundsMemory = memory;
    // 移动 / 缩放后 500ms 内直接关窗会丢掉最后一次位置，关窗前补存一次
    addBeforeCloseHook(memory.saveNow);
    // 拦截关闭（窗口按钮 / Alt+F4 / 任务栏），先跑完收尾钩子再销毁窗口；
    // macOS 红色关闭按钮只隐藏窗口（见 _CloseGuard），真正退出由菜单 / Cmd+Q 触发
    await windowManager.setPreventClose(true);
    windowManager.addListener(_CloseGuard());
    if (Platform.isMacOS) windowManager.addListener(_FullScreenSync());
    // macOS：Cmd+Q / 菜单退出前跑同一套收尾钩子（红色按钮隐藏窗口时不跑——应用还在运行）。
    // 监听器注册为 WidgetsBindingObserver，由 binding 持有，随进程存活
    if (Platform.isMacOS) {
      AppLifecycleListener(onExitRequested: _onExitRequested);
    }
    _enabled = true;
  }

  /// 窗口位置记忆；macOS 隐藏窗口前也要保存一次。
  static WindowBoundsMemory? _boundsMemory;

  /// 隐藏窗口（macOS 红色关闭按钮）前的收尾：只保存窗口位置，
  /// 不跑 [addBeforeCloseHook] 的重钩子（注销 Connect、保存播放会话等留给真正退出）。
  static Future<void> _runBeforeHide() =>
      _boundsMemory?.saveNow() ?? Future.value();

  /// Windows：关闭按钮只隐藏窗口到托盘（托盘图标在时才为 true，见 `DesktopTray`）。
  static bool closeToTray = false;

  static bool _quitting = false;

  /// 真正退出（托盘菜单）：跑完收尾再销毁窗口，不再隐藏到托盘。
  static Future<void> quit() {
    _quitting = true;
    return windowManager.close();
  }

  /// 从托盘恢复窗口。
  static Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  static bool _exitRequested = false;

  /// macOS 退出请求（Cmd+Q / 程序坞右键退出 / 菜单「退出 Flutify」）：
  /// 先并行跑完 [addBeforeCloseHook] 注册的收尾（保存播放会话、注销 Connect 播放端、
  /// 令牌落盘、保存窗口位置……），再放行系统退出。
  static Future<AppExitResponse> _onExitRequested() async {
    // 重入（连按 Cmd+Q）直接放行本次，收尾只跑一次
    if (_exitRequested) return AppExitResponse.exit;
    _exitRequested = true;
    await _runBeforeClose();
    return AppExitResponse.exit;
  }

  static final List<(Future<void> Function(), Duration)> _beforeClose = [];

  /// 关窗前要完成的收尾（如保存播放进度）。每个钩子最多等 [timeout]，超时也照常关闭；
  /// 所有钩子并行执行。
  static void addBeforeCloseHook(
    Future<void> Function() hook, {
    Duration timeout = _closeTimeout,
  }) => _beforeClose.add((hook, timeout));

  static const Duration _closeTimeout = Duration(milliseconds: 800);

  static Future<void> _runBeforeClose() async {
    await Future.wait([
      for (final (hook, timeout) in _beforeClose)
        Future.sync(hook).timeout(timeout).catchError((Object _) {}),
    ]);
  }

  /// Update confirmation uses the same session-saving hooks as normal exit.
  static Future<void> closeForUpdate() async {
    if (!_enabled || !Platform.isWindows) return;
    await windowManager.close();
  }

  /// 把窗口带到前台（最小化时先还原）。任务栏歌词「打开 Flutify」使用。
  static Future<void> bringToFront() async {
    if (!_enabled) return;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// 进入 / 退出系统全屏（沉浸式歌词使用）。未启用自绘标题栏（测试、移动端）时不做任何事。
  static Future<void> setFullScreen(bool value) async {
    if (!_enabled) return;
    fullScreen.value = value;
    if (await windowManager.isFullScreen() == value) return;
    // 切换期间（含退出后的两次 setSize 刷新）暂停所有背景模糊，避开引擎合成器崩溃
    _holdGlass();
    try {
      // 必须等 Flutter 真正画出「无 BackdropFilter」的帧之后再让原生改窗口：
      // 之前同一个微任务里先置标志、立刻调原生，窗口尺寸变化时上一帧的
      // BackdropFilter 还在图层树里，正是崩溃（0xc0000005）的窗口期。
      await _afterGlassDropped();
      await windowManager.setFullScreen(value);
      if (!value) await _refreshFrame();
    } finally {
      // 等原生尺寸与最后一帧落定再恢复模糊
      Future<void>.delayed(const Duration(milliseconds: 300), _releaseGlass);
    }
  }

  /// 玻璃模糊暂停的持有计数：多处（路由退出、全屏切换）可同时持有，全部释放后才恢复。
  static int _glassHolds = 0;

  static void _holdGlass() {
    _glassHolds++;
    fullscreenTransition.value = true;
  }

  static void _releaseGlass() {
    if (_glassHolds > 0) _glassHolds--;
    if (_glassHolds == 0) fullscreenTransition.value = false;
  }

  /// 等两帧：第一帧重建 LiquidGlass 去掉 BackdropFilter，第二帧确保已经提交到合成器。
  static Future<void> _afterGlassDropped() async {
    final binding = WidgetsBinding.instance;
    // 窗口最小化 / 被遮挡时可能不出帧：最多等 300ms，不让切换卡死
    await (() async {
      await binding.endOfFrame;
      await binding.endOfFrame;
    })().timeout(const Duration(milliseconds: 300), onTimeout: () {});
  }

  /// 关闭沉浸式歌词前调用：先让玻璃退化为无模糊并等其落地，再返回，
  /// 这样路由淡出动画（Opacity 图层里套 BackdropFilter）与随后的退出全屏都不会撞上它。
  /// [hold] 之后自动恢复，期间若发生全屏切换，会等它也结束才恢复。
  static Future<void> dropGlassForExit({
    Duration hold = const Duration(milliseconds: 900),
  }) async {
    if (!_enabled) return;
    _holdGlass();
    Future<void>.delayed(hold, _releaseGlass);
    await _afterGlassDropped();
  }

  /// 退出全屏后强制原生窗口重算边框、重排 Flutter 视图。
  ///
  /// window_manager 在 Windows 上只有收到 SIZE_MAXIMIZED 才记为「已进入全屏」；
  /// 从普通窗口进入全屏时收到的是 SIZE_RESTORED，状态没记上，退出时就跳过了
  /// 子视图刷新，客户区残留全屏时的尺寸，露出大片黑边。
  /// 宽度临时 +1 再改回，触发两次 WM_SIZE，让子视图贴合新的客户区。
  static Future<void> _refreshFrame() async {
    if (!Platform.isWindows) return;
    // 等原生还原落定：进入全屏前若是最大化，插件会异步再发一次 SC_MAXIMIZE
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (await windowManager.isFullScreen() ||
        await windowManager.isMaximized()) {
      return;
    }
    final size = await windowManager.getSize();
    await windowManager.setSize(Size(size.width + 1, size.height));
    await windowManager.setSize(size);
  }
}

/// 收到关闭请求时先执行 [DesktopWindow.addBeforeCloseHook] 注册的收尾，再真正销毁窗口。
/// macOS 例外：红色关闭按钮只隐藏窗口（macOS 音乐应用惯例，音乐继续播放），
/// 窗口位置照常保存；重新打开由 Dock 重开（applicationShouldHandleReopen）原生侧处理，
/// 真正退出见 [DesktopWindow._exitRequested] 的 AppLifecycleListener。
class _CloseGuard with WindowListener {
  bool _closing = false;

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    if (Platform.isMacOS) {
      await DesktopWindow._runBeforeHide();
      await _leaveFullScreen();
      await windowManager.hide();
      // 窗口只是藏起来，应用还活着：解除闭锁，下次关窗（或再次隐藏）仍能触发
      _closing = false;
      return;
    }
    if (DesktopWindow.closeToTray && !DesktopWindow._quitting) {
      await DesktopWindow._runBeforeHide();
      await _leaveFullScreen();
      await windowManager.hide();
      _closing = false;
      return;
    }
    await DesktopWindow._runBeforeClose();
    await windowManager.destroy();
  }

  /// 原生全屏时直接隐藏会留下一个黑色的全屏桌面空间，[DesktopWindow.fullScreen] 也停在 true：
  /// 先退出全屏，等退出动画结束（轮询，最多 2s）再隐藏。
  static Future<void> _leaveFullScreen() async {
    if (!await windowManager.isFullScreen()) {
      DesktopWindow.fullScreen.value = false;
      return;
    }
    await DesktopWindow.setFullScreen(false);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (await windowManager.isFullScreen() &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // isFullScreen 翻转时退出动画还在收尾，紧接着 orderOut 偶发留下空白空间
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

/// macOS：绿色按钮、「窗口 → 进入全屏」、⌃⌘F 由系统直接切换全屏，不经过 [DesktopWindow.setFullScreen]。
/// 把原生全屏状态同步回 [DesktopWindow.fullScreen]（窗口位置记忆、窄窗口标题条、沉浸式歌词都看它）。
class _FullScreenSync with WindowListener {
  @override
  void onWindowEnterFullScreen() => DesktopWindow.fullScreen.value = true;

  @override
  void onWindowLeaveFullScreen() => DesktopWindow.fullScreen.value = false;
}

/// 窗口拖动区：按住拖动移动窗口，双击最大化 / 还原（Windows 标题栏行为）。
/// 未启用自绘标题栏时原样返回子组件。
class WindowDragArea extends StatelessWidget {
  final Widget child;

  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindow.enabled) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: DesktopWindow.toggleMaximize,
      child: child,
    );
  }
}
