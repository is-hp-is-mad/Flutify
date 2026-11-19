import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/playback_retry.dart';
import '../network/network_failure.dart';

/// 播放网络重试预算与退避状态机（从 `PlaybackProvider` 拆出，保持高内聚）。
///
/// 规则：
/// - 一次手动播放尝试或一次自动跳过给 [PlaybackRetry.limit] 次重试；
/// - 网络类失败允许将预算还回去重放一次（[canReplayOnce] / [runReplay]），重放再失败则不再循环。
class PlaybackRetryController {
  bool _retryingTrack = false;
  int _retriesUsed = 0;
  bool _transientRetried = false;
  Completer<void>? _retryWait;

  final ValueNotifier<PlaybackRetry?> notifier = ValueNotifier(null);

  bool get _budgetExhausted => _retriesUsed >= PlaybackRetry.limit;

  /// 是否允许把预算还回去同曲重放一次。
  bool get canReplayOnce => !_transientRetried && !_retryingTrack;

  /// 新的手动播放尝试或成功开播后：完全重置重试状态。
  void resetAll() {
    _retryingTrack = false;
    _retriesUsed = 0;
    _transientRetried = false;
  }

  /// 自动跳过到下一首或重放彻底放弃后：重置计数与重放标记。
  void resetBudget() {
    _retriesUsed = 0;
    _transientRetried = false;
  }

  /// 开始一首歌时更新预算（[isRetry] 为 true 且不在同曲重放中时，说明是自动跳过到下一首）。
  void onStartTrack({required bool isRetry}) {
    if (!isRetry) {
      resetAll();
    } else if (!_retryingTrack) {
      resetBudget();
    }
  }

  /// 取消当前正在等待的退避。
  void cancel() {
    final wait = _retryWait;
    _retryWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
    notifier.value = null;
  }

  /// 执行一次同曲重放（重置预算并立起 `_retryingTrack` 闸门，防止重放失败时再次循环）。
  Future<void> runReplay(Future<void> Function() action) async {
    _retriesUsed = 0;
    _transientRetried = true;
    _retryingTrack = true;
    try {
      await action();
    } finally {
      _retryingTrack = false;
    }
  }

  /// 若 [error] 是可重试的网络故障且尚有预算，则按递增秒数退避等待；返回 true 表示应继续重试。
  Future<bool> waitForRetry(
    Object error, {
    required bool Function() isCurrentGeneration,
  }) async {
    if (!isConnectionFailure(error) || _budgetExhausted) {
      return false;
    }
    final attempt = ++_retriesUsed;
    final delay = Duration(seconds: attempt);
    final wait = Completer<void>();
    _retryWait = wait;
    notifier.value = PlaybackRetry(attempt, delay);
    final timer = Timer(delay, () {
      if (!wait.isCompleted) wait.complete();
    });
    await wait.future;
    timer.cancel();
    if (!identical(_retryWait, wait)) return false;
    _retryWait = null;
    if (!isCurrentGeneration()) return false;
    notifier.value = PlaybackRetry(attempt, delay, waiting: false);
    return true;
  }

  void dispose() {
    cancel();
    notifier.dispose();
  }
}
