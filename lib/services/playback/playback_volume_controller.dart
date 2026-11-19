import 'dart:math';

import '../audio/audio_engine.dart';
import '../protocol/audio_normalization.dart';
import '../storage/playback_prefs_store.dart';

/// 播放器音量、静音记忆、响度均衡（ReplayGain）与平方曲线淡入淡出控制器。
class PlaybackVolumeController {
  static const int maxFadeSeconds = 12;

  final AudioEngine _audio;
  final PlaybackPrefsStore _storage;

  double _volume;
  double _volumeBeforeMute;
  bool _normalize;
  int _fadeSeconds;
  AudioNormalization? _normalization;
  double _fadeFactor = 1.0;
  double _appliedVolume = -1.0;

  PlaybackVolumeController(this._audio, this._storage)
    : _volume = _storage.volume,
      _volumeBeforeMute = _storage.volume > 0 ? _storage.volume : 0.8,
      _normalize = _storage.normalizeVolume,
      _fadeSeconds = _storage.fadeSeconds.clamp(0, maxFadeSeconds);

  double get volume => _volume;
  bool get normalizeVolume => _normalize;
  int get fadeSeconds => _fadeSeconds;

  void setNormalization(AudioNormalization? normalization) {
    _normalization = normalization;
  }

  void resetTrackGain() {
    _normalization = null;
    _fadeFactor = 1.0;
    apply();
  }

  void setVolume(double value, {bool persist = false}) {
    _volume = value.clamp(0.0, 1.0);
    if (_volume > 0) _volumeBeforeMute = _volume;
    apply();
    if (persist) _storage.setVolume(_volume);
  }

  bool setNormalizeVolume(bool value) {
    if (value == _normalize) return false;
    _normalize = value;
    _storage.setNormalizeVolume(value);
    apply();
    return true;
  }

  bool setFadeSeconds(int value, {required Duration position, required Duration duration}) {
    final next = value.clamp(0, maxFadeSeconds);
    if (next == _fadeSeconds) return false;
    _fadeSeconds = next;
    _storage.setFadeSeconds(next);
    updateFade(position, duration);
    return true;
  }

  double mutedOrRestoredVolume() => _volume > 0 ? 0.0 : _volumeBeforeMute;

  void apply() {
    final gain = _normalize ? (_normalization?.volumeFactor ?? 1.0) : 1.0;
    final effective = (_volume * gain * _fadeFactor).clamp(0.0, 1.0);
    if ((effective - _appliedVolume).abs() < 0.002) return;
    _appliedVolume = effective;
    _audio.setVolume(effective);
  }

  void updateFade(Duration position, Duration duration) {
    var factor = 1.0;
    if (_fadeSeconds > 0) {
      final fadeMs = _fadeSeconds * 1000;
      final posMs = position.inMilliseconds;
      final durMs = duration.inMilliseconds;
      final fadeInMs = (fadeMs / 2).clamp(500.0, 3000.0);
      if (posMs < fadeInMs) factor = posMs / fadeInMs;
      if (durMs > fadeMs * 2) factor = min(factor, (durMs - posMs) / fadeMs);
      factor = factor.clamp(0.0, 1.0);
      factor *= factor;
    }
    if (factor == _fadeFactor) return;
    _fadeFactor = factor;
    apply();
  }
}
