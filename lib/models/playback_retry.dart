/// One visible retry, first while waiting and then while opening the source.
class PlaybackRetry {
  /// 一次加载尝试里最多退避重试几次。
  ///
  /// 退避是第 attempt 次等 [delay] 秒，线性增长：3 次就是 1+2+3 = 6 秒。
  /// 网络类失败还会整首歌重放一次（见 PlaybackProvider._retryTrack），
  /// 所以最坏情况下用户要等 12 秒才看到错误提示。
  /// 再长用户就只能看着「正在重试」而不能听歌了——等待期间的提示条虽然带
  /// 「取消」，但默认路径不该逼人去点它。
  static const int limit = 3;
  final int attempt;
  final Duration delay;
  final bool waiting;

  const PlaybackRetry(this.attempt, this.delay, {this.waiting = true});
}
