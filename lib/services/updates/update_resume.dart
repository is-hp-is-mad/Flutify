import 'dart:io';

import '../../core/constants/app_info.dart';
import '../storage/update_state_store.dart';

/// 更新后自动续播：点「安装更新」时正在播放就记一个标记，更新后的新版本启动时消费它。
///
/// - Windows：更新脚本 / 安装器装完会立刻重新启动 Flutify，时限放宽到 10 分钟（UAC 确认、安装器耗时）；
/// - Android：系统安装器装完不会自动打开，用户在 5 分钟内重新打开即续播；
/// - macOS / Linux：没有应用内安装，点更新只是打开发布页，下载、替换、重开都由用户手动完成，时限 30 分钟；
/// - 只有版本确实变了才续播：系统安装器里点了取消、过一会儿又打开旧版本，不应莫名开始放歌；
/// - 标记只用一次：无论是否续播，启动时都会清除。
class UpdateResume {
  UpdateResume(
    this._store, {
    String? currentVersion,
    DateTime Function()? now,
    Duration? window,
  }) : _currentVersion = currentVersion ?? AppInfo.releaseTag,
       _now = now ?? DateTime.now,
       window = window ?? defaultWindow;

  final UpdateStateStore _store;
  final String _currentVersion;
  final DateTime Function() _now;

  /// 从点更新到新版本启动的最长间隔。
  final Duration window;

  static Duration get defaultWindow {
    if (Platform.isAndroid) return const Duration(minutes: 5);
    if (Platform.isWindows) return const Duration(minutes: 10);
    return const Duration(minutes: 30);
  }

  /// 点安装（或打开发布页手动更新）前调用（调用方先确认正在播放、并已保存播放会话）。
  Future<void> mark() => _store.setResumeAfterUpdate(
    _now().millisecondsSinceEpoch,
    _currentVersion,
  );

  /// 启动时调用一次：有标记就清除；版本已变且在时限内返回 true。
  Future<bool> consume() async {
    final at = _store.resumeAfterUpdateAt;
    if (at == null) return false;
    final from = _store.resumeAfterUpdateFrom;
    await _store.clearResumeAfterUpdate();
    if (from == _currentVersion) return false;
    final elapsed = _now().difference(DateTime.fromMillisecondsSinceEpoch(at));
    return !elapsed.isNegative && elapsed <= window;
  }
}
