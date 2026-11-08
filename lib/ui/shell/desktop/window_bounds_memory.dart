import 'dart:async';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../../../services/storage_service.dart';
import 'saved_window_bounds.dart';

/// 桌面窗口位置 / 大小记忆（设置页「启动」分组的「记住窗口大小和位置」）。
///
/// - 启动时 [restorable] 读出上次的位置，并校验当前显示器仍能看到窗口；
/// - 运行中监听移动 / 缩放 / 最大化，停止变化 500ms 后写盘（拖动过程中不反复写）；
/// - 系统全屏（沉浸式歌词）与最小化时不记录，避免把全屏尺寸当成窗口尺寸。
class WindowBoundsMemory with WindowListener {
  final StorageService _storage;
  final Size _minimumSize;

  /// 当前是否开启记忆（每次写盘前读取，设置页关掉后立即停止记录）。
  final bool Function() _enabled;

  /// 是否处于沉浸式系统全屏。
  final bool Function() _fullScreen;

  Timer? _debounce;

  WindowBoundsMemory(
    this._storage, {
    required this._minimumSize,
    required this._enabled,
    required this._fullScreen,
  });

  /// 读取可恢复的位置；没有记录、数据损坏或窗口会落在所有显示器之外时返回 null。
  static Future<SavedWindowBounds?> restorable(
    StorageService storage, {
    required Size minimumSize,
  }) async {
    final saved = SavedWindowBounds.decode(
      storage.windowBoundsJson,
      minimumSize: minimumSize,
    );
    if (saved == null) return null;
    try {
      final displays = await screenRetriever.getAllDisplays();
      final areas = [
        for (final d in displays)
          (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size),
      ];
      return saved.isReachableOn(areas) ? saved : null;
    } catch (_) {
      return null;
    }
  }

  void attach() => windowManager.addListener(this);

  void detach() {
    _debounce?.cancel();
    windowManager.removeListener(this);
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  /// 立即保存（关窗前调用，不等防抖）。
  Future<void> saveNow() {
    _debounce?.cancel();
    return _save();
  }

  Future<void> _save() async {
    if (!_enabled() || _fullScreen()) return;
    try {
      if (await windowManager.isFullScreen() || await windowManager.isMinimized()) {
        return;
      }
      final maximized = await windowManager.isMaximized();
      // 最大化时保留之前的普通窗口位置，只更新最大化标记
      final previous = SavedWindowBounds.decode(
        _storage.windowBoundsJson,
        minimumSize: _minimumSize,
      );
      final rect = maximized ? previous?.rect : await windowManager.getBounds();
      if (rect == null) return;
      await _storage.setWindowBoundsJson(
        SavedWindowBounds(rect, maximized: maximized).encode(),
      );
    } catch (_) {
      // 原生通道不可用（测试 / 关闭中）时忽略
    }
  }

  @override
  void onWindowMoved() => _schedule();

  @override
  void onWindowResized() => _schedule();

  @override
  void onWindowMaximize() => _schedule();

  @override
  void onWindowUnmaximize() => _schedule();
}
