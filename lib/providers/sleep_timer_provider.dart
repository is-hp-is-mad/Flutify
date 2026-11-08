import 'dart:async';

import 'package:flutter/foundation.dart';

import 'playback_provider.dart';

/// 睡眠定时器的预设（与官方桌面端一致）。
enum SleepTimerPreset {
  minutes5(Duration(minutes: 5)),
  minutes10(Duration(minutes: 10)),
  minutes15(Duration(minutes: 15)),
  minutes30(Duration(minutes: 30)),
  minutes45(Duration(minutes: 45)),
  hour1(Duration(hours: 1)),
  endOfTrack(null);

  /// 定时时长；[endOfTrack] 为 null（本首播完即停）。
  final Duration? duration;

  const SleepTimerPreset(this.duration);
}

/// 睡眠定时器：到点暂停本机播放。不持久化，关掉 App 即取消。
///
/// - 按时长：到点调用 [PlaybackProvider.pause]；倒计时期间每秒通知一次，供播放栏指示器显示剩余时间；
/// - 本首结束时：交给 [PlaybackProvider.stopAfterCurrent]，播放器在曲目结束处停下，
///   这里监听它复位后把定时器标记为结束。
class SleepTimerProvider extends ChangeNotifier {
  final PlaybackProvider _playback;
  final DateTime Function() _now;

  SleepTimerPreset? _preset;
  DateTime? _deadline;
  Timer? _fire;
  Timer? _tick;

  SleepTimerProvider(this._playback, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    _playback.addListener(_onPlayback);
  }

  /// 当前预设；未开启时为 null。
  SleepTimerPreset? get preset => _preset;
  bool get active => _preset != null;

  /// 按时长定时的剩余时间；未开启或「本首结束时」为 null。
  Duration? get remaining {
    final deadline = _deadline;
    if (deadline == null) return null;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  void start(SleepTimerPreset preset) {
    _clear();
    _preset = preset;
    final duration = preset.duration;
    if (duration == null) {
      _playback.stopAfterCurrent = true;
    } else {
      _deadline = _now().add(duration);
      _fire = Timer(duration, _expire);
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    }
    notifyListeners();
  }

  void cancel() {
    if (!active) return;
    _clear();
    notifyListeners();
  }

  void _expire() {
    _clear();
    unawaited(_playback.pause());
    notifyListeners();
  }

  /// 「本首结束时」已生效（播放器复位了标志）或被别处关掉 → 定时器结束。
  void _onPlayback() {
    if (_preset == SleepTimerPreset.endOfTrack && !_playback.stopAfterCurrent) {
      _preset = null;
      notifyListeners();
    }
  }

  void _clear() {
    _fire?.cancel();
    _tick?.cancel();
    _fire = _tick = null;
    _deadline = null;
    if (_preset == SleepTimerPreset.endOfTrack) {
      _preset = null; // 先清空，避免下一行触发 _onPlayback 再通知一次
      _playback.stopAfterCurrent = false;
    }
    _preset = null;
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlayback);
    _fire?.cancel();
    _tick?.cancel();
    super.dispose();
  }
}
