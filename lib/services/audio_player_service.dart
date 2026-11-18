import 'dart:async';
import 'package:just_audio/just_audio.dart';

import 'audio/audio_engine.dart';
import 'downloading_audio_source.dart';
import 'protocol/progressive_download.dart';
import '../models/track_playback_exception.dart';

/// just_audio 的薄封装。上层只依赖这里暴露的流与方法，
/// 便于在测试中用 Fake 实现替换（不直接暴露 AudioPlayer 实例）。
class AudioPlayerService implements AudioEngine {
  final AudioPlayer _player;

  AudioPlayerService([AudioPlayer? player]) : _player = player ?? AudioPlayer();

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  /// just_audio 链路没有 EME 运行期错误。
  @override
  Stream<EmePlaybackException> get emeErrors => const Stream.empty();

  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get isPlaying => _player.playing;

  /// 是否已加载过音源。
  bool get hasSource => _player.audioSource != null;

  /// 播放本地音频文件（协议链路下载、解密后的完整曲目）。
  ///
  /// [initialPosition] 用于恢复上次播放进度。[autoplay] 为 false 时只加载、不开始播放。
  /// 连续切歌时 just_audio 会以「加载被中断」结束上一次调用，属预期行为，静默返回；
  /// 其余加载失败（文件损坏 / 解码器不支持）抛 [TrackPlaybackException]（unavailable），
  /// 由 PlaybackProvider 提示并跳到下一首。
  Future<void> playFile(String path, {Duration? initialPosition, bool autoplay = true}) async {
    if (path.isEmpty) return;
    await _setSource(AudioSource.file(path), initialPosition, autoplay);
  }

  /// 边下边播：播放仍在下载中的曲目（规则同 [playFile]）。
  Future<void> playStream(ProgressiveAudio audio, {Duration? initialPosition, bool autoplay = true}) {
    return _setSource(DownloadingAudioSource(audio), initialPosition, autoplay);
  }

  Future<void> _setSource(AudioSource source, Duration? initialPosition, bool autoplay) async {
    try {
      await _player.setAudioSource(source, initialPosition: initialPosition);
    } on PlayerInterruptedException {
      return;
    } catch (e) {
      throw TrackPlaybackException(TrackPlaybackFailure.unavailable, '音频文件无法解码，已跳过', e);
    }
    // just_audio 的 play() 要到播放结束 / 暂停才完成，不能 await，否则会阻塞后续切歌逻辑
    if (autoplay) unawaited(_player.play().catchError((Object _) {}));
  }

  /// EME（DRM 曲目）在 just_audio 引擎上不可用；由路由引擎转发到 EME 引擎。
  @override
  Future<void> playEme(EmeTrackContent content, {Duration? initialPosition, bool autoplay = true}) {
    throw UnimplementedError('just_audio 引擎不支持 EME 播放');
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0.0, 1.0));
  Future<void> stop() => _player.stop();

  void dispose() {
    _player.dispose();
  }
}
