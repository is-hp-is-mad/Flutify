/// 完整曲目加载失败的原因分类，供播放器决定「提示并跳过」还是「提示重试」。
enum TrackPlaybackFailure {
  /// 未登录或会话失效：需要重新登录，跳过也无意义。
  notSignedIn,

  /// 缺少 Web 登录态（sp_dc）：DRM 全曲播放的 Widevine 真密钥依赖 Web token，
  /// 需要用户完成一次 Web 登录；跳过无意义。
  webSignInRequired,

  /// 曲目在当前地区 / 账号下不可播放（无音频文件、版权限制、仅 Premium 音质等）：提示并跳过。
  unavailable,

  /// 网络或服务端临时错误：提示，可重试。
  network,

  /// 当前网络出口在中国大陆：Spotify 在这里不可用，提示用户换节点（见 PlaybackRegionGate）。
  /// 和 [unavailable] 分开：这不是这首歌的问题，跳到下一首也没用。
  regionBlocked,
}

/// 完整曲目加载失败。[message] 为可直接展示给用户的简体中文说明。
class TrackPlaybackException implements Exception {
  final TrackPlaybackFailure kind;
  final String message;

  /// 原始错误，仅用于日志排查。
  final Object? cause;

  const TrackPlaybackException(this.kind, this.message, [this.cause]);

  /// 「不可播放」类错误：播放器应自动跳到下一首。
  bool get shouldSkip => kind == TrackPlaybackFailure.unavailable;

  @override
  String toString() => cause == null ? message : '$message（$cause）';
}
