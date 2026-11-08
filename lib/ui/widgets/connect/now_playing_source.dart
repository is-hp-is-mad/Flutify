import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../models/track.dart';
import '../../../providers/connect_provider.dart';
import '../../../providers/playback_provider.dart';
import 'connect_actions.dart';

/// 「正在播放」的来源：遥控远程设备时（[ConnectActions.showRemote]）为远程，否则为本机。
///
/// 歌词、右栏「正在播放」、沉浸式歌词等按曲目展示的界面都从这里取曲目与播放状态，
/// 播放栏切到远程模式时它们随之切换。均在 build 中调用（内部用 `select` 订阅）。
class NowPlayingSource {
  NowPlayingSource._();

  static bool isRemote(BuildContext context) => ConnectActions.showRemote(context);

  /// 当前曲目；没有时为 null。
  static SpotifyTrack? track(BuildContext context) {
    if (isRemote(context)) return context.select<ConnectProvider, SpotifyTrack?>((c) => c.displayTrack);
    return context.select<PlaybackProvider, SpotifyTrack?>((p) => p.currentTrack);
  }

  /// 是否正在出声（驱动流动背景等）。
  static bool isPlaying(BuildContext context) {
    if (isRemote(context)) return context.select<ConnectProvider, bool>((c) => c.player.isAudible);
    return context.select<PlaybackProvider, bool>((p) => p.isPlaying);
  }

  /// 曲目行用：[trackId] 是否为当前曲目、是否正在出声。
  /// 只比较 ID 并返回布尔，其他曲目切换不会让这一行重建。
  static (bool current, bool playing) trackState(BuildContext context, String trackId) {
    if (isRemote(context)) {
      return context.select<ConnectProvider, (bool, bool)>((c) {
        final current = c.player.trackId == trackId;
        return (current, current && c.player.isAudible);
      });
    }
    return context.select<PlaybackProvider, (bool, bool)>((p) {
      final current = p.isCurrent(trackId);
      return (current, current && p.isPlaying);
    });
  }
}
