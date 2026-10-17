import '../services/protocol/track_playback_exception.dart';
import 'track.dart';

/// 一次播放失败的记录，供 UI 提示（SnackBar / 播放器内提示条）。
///
/// [serial] 每次失败递增：即使同一首歌连续失败两次，UI 也能据此区分「新的一次」并重新提示。
class PlaybackError {
  final int serial;
  final SpotifyTrack track;
  final TrackPlaybackException exception;

  /// 播放器是否已自动跳到下一首（仅「不可播放」类错误会跳）。
  final bool skipped;

  /// 连续 [consecutiveFailures] 首无法播放、已按设置自动暂停（不再继续跳过）。
  final bool autoPaused;

  /// 截至本次，连续无法播放的曲目数（含本首）。
  final int consecutiveFailures;

  /// 播放器正在同一首上退避重放，还没放弃这首歌。
  ///
  /// 这类错误不代表「这次播放结束了」，只代表「这一下没加载上」：订阅 [playbackErrors]
  /// 的一方可以据此只提示一次（或干脆不提示），把连续几次网络抖动合成一条。
  final bool retryable;

  const PlaybackError({
    required this.serial,
    required this.track,
    required this.exception,
    required this.skipped,
    this.autoPaused = false,
    this.consecutiveFailures = 1,
    this.retryable = false,
  });

  TrackPlaybackFailure get kind => exception.kind;

  /// 可直接展示给用户的简体中文说明（不含曲名）。
  String get message => exception.message;

  /// 带曲名的完整提示，如「Blinding Lights：这首歌暂时无法播放…」。
  String get messageWithTrack =>
      track.name.isEmpty ? message : '${track.name}：$message';
}
