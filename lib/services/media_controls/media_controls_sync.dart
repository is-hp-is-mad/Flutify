import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/track.dart';
import '../../providers/playback_provider.dart';
import '../widget/widget_bridge.dart';
import 'system_media_controls.dart';

/// 媒体卡片的替代来源（例如在其他设备上播放时的 Connect 远程设备，见 [ConnectMediaSource]）。
///
/// [active] 为 true 时系统媒体卡片显示它的曲目 / 播放状态 / 进度，系统按键也交给 [handle]；
/// 否则照常显示并控制本机。
abstract interface class MediaSourceOverride {
  /// [active]、[track]、[playbackInfo] 可能变化时通知。
  Listenable get changes;

  /// 播放进度（拖动、周期同步用）。
  ValueListenable<Duration> get position;

  bool get active;

  /// 当前曲目；不是曲目（播客单集等）时为 null，卡片清空。
  MediaTrackInfo? get track;

  MediaPlaybackInfo get playbackInfo;

  /// 处理系统按键；返回 true 表示已处理，本机不再响应。
  bool handle(MediaControlEvent event);
}

/// 把播放状态同步给系统媒体控制，并把系统按键转给 [PlaybackProvider]（或接管中的 [override]）。
///
/// 规则：
/// - 曲目、播放 / 暂停、缓冲、能否切歌只在变化时下发（PlaybackProvider 的通知很频繁，这里做差异比较）；
/// - 进度：拖动（与按时间推算的位置相差超过 2 秒）时立即下发；系统不会自行推算进度的平台（Windows）
///   播放中每 [timelineInterval] 再下发一次；
/// - 系统的「播放 / 暂停」按当前状态决定是否切换，避免重复按键把状态切反；
/// - 本机与 [override] 之间切换时视为换曲，重新下发曲目与状态。
class MediaControlsSync {
  final PlaybackProvider playback;
  final SystemMediaControls controls;
  final WidgetBridge? widget;

  static const Duration timelineInterval = Duration(seconds: 5);

  /// 桌面小组件「待播清单」最多显示几首。
  static const int widgetQueueLength = 6;

  MediaSourceOverride? _override;
  StreamSubscription<MediaControlEvent>? _events;
  // 曲目键带来源前缀：本机与远程恰好是同一首时也会重新下发
  String? _trackKey;
  MediaTrackInfo? _lastTrack;
  MediaPlaybackInfo? _lastPlayback;
  DateTime _lastPlaybackAt = DateTime.now();
  // 小组件待播清单的差异键（来源名 + 曲目 id）
  String? _widgetQueueKey;

  MediaControlsSync(this.playback, this.controls, {this.widget}) {
    widget?.onPlayQueueItem = _playQueueItem;
    playback.addListener(_sync);
    playback.positionNotifier.addListener(_onPosition);
    _events = controls.events.listen(_onEvent);
    _sync();
    // 上次会话在 PlaybackProvider 构造时已同步还原；此时仍无曲目说明没有会话，
    // 清掉小组件里上一个进程留下的旧曲目
    if (_trackKey == null) unawaited(widget?.clear());
  }

  /// 接上 / 换掉替代来源（App 启动时由 main.dart 接上 Connect）。
  set override(MediaSourceOverride? value) {
    _override?.changes.removeListener(_sync);
    _override?.position.removeListener(_onPosition);
    _override = value;
    value?.changes.addListener(_sync);
    value?.position.addListener(_onPosition);
    _sync();
  }

  bool get _remote => _override?.active ?? false;

  void _sync() {
    final remote = _remote;
    final track = remote ? _override!.track : _localTrack();
    final key = track == null
        ? null
        : '${remote ? 'remote' : 'local'}:${track.id}';
    if (key != _trackKey || !_sameTrack(track, _lastTrack)) {
      _trackKey = key;
      _lastTrack = track;
      unawaited(controls.setTrack(track));
      unawaited(_pushWidgetTrack(track));
      _lastPlayback = null;
    }
    if (track == null) return;
    _pushWidgetQueue();
    final next = _playbackInfo();
    final last = _lastPlayback;
    if (last == null ||
        last.playing != next.playing ||
        last.buffering != next.buffering ||
        last.canNext != next.canNext ||
        last.canPrevious != next.canPrevious) {
      _push(next);
    }
  }

  void _onPosition() {
    final last = _lastPlayback;
    if (last == null || _trackKey == null) return;
    final now = DateTime.now();
    final elapsed = now.difference(_lastPlaybackAt);
    final expected = last.playing && !last.buffering
        ? last.position + elapsed
        : last.position;
    final position = _remote ? _override!.position.value : playback.position;
    final jumped = (position - expected).abs() > const Duration(seconds: 2);
    final periodic =
        controls.needsPeriodicTimeline &&
        last.playing &&
        elapsed >= timelineInterval;
    if (jumped || periodic) _push(_playbackInfo());
  }

  void _push(MediaPlaybackInfo info) {
    _lastPlayback = info;
    _lastPlaybackAt = DateTime.now();
    unawaited(controls.setPlayback(info));
    final track = _lastTrack;
    if (track != null && track.id.isNotEmpty) {
      unawaited(widget?.update(track, info));
    }
  }

  // 曲目变化时同步桌面小组件；无曲目时清空
  Future<void> _pushWidgetTrack(MediaTrackInfo? track) {
    final bridge = widget;
    if (bridge == null) return Future.value();
    if (track == null || track.id.isEmpty) {
      _widgetQueueKey = null;
      return bridge.clear();
    }
    return bridge.update(track, _playbackInfo());
  }

  // 待播清单只在内容变化时下发；远程播放（Connect）时本机队列不相关，清单为空
  void _pushWidgetQueue() {
    final bridge = widget;
    if (bridge == null) return;
    final remote = _remote;
    final contextName = remote ? '' : playback.playbackContext.name;
    final next = remote
        ? const <MediaTrackInfo>[]
        : [
            for (final t in playback.upcomingTracks(widgetQueueLength))
              trackInfo(t),
          ];
    final key = [contextName, for (final t in next) t.id].join('\u0000');
    if (key == _widgetQueueKey) return;
    _widgetQueueKey = key;
    unawaited(bridge.updateQueue(contextName, next));
  }

  Future<bool> _playQueueItem(int index, String trackId) {
    if (_remote) return Future.value(false);
    return playback.playUpcoming(index, trackId);
  }

  MediaTrackInfo? _localTrack() {
    final track = playback.currentTrack;
    return track == null ? null : trackInfo(track, duration: playback.duration);
  }

  static bool _sameTrack(MediaTrackInfo? a, MediaTrackInfo? b) =>
      identical(a, b) ||
      (a != null &&
          b != null &&
          a.id == b.id &&
          a.title == b.title &&
          a.artist == b.artist &&
          a.album == b.album &&
          a.artUrl == b.artUrl &&
          a.duration == b.duration);

  MediaPlaybackInfo _playbackInfo() {
    if (_remote) return _override!.playbackInfo;
    final hasError = playback.playbackError != null;
    return MediaPlaybackInfo(
      playing: !hasError && playback.isPlaybackActive,
      buffering:
          playback.isBuffering ||
          (playback.isPlaybackActive && !playback.isPlaying) ||
          hasError,
      position: playback.position,
      canNext: playback.canSkipNext,
      // 有上一首时直接切歌；没有上一首时回到本曲开头。
      canPrevious: true,
    );
  }

  /// 曲目 → 系统媒体卡片信息（本机与远程共用）。
  static MediaTrackInfo trackInfo(SpotifyTrack track, {Duration? duration}) =>
      MediaTrackInfo(
        id: track.id,
        title: track.name,
        artist: track.artistNames,
        album: track.album?.name ?? '',
        artUrl: track.coverUrl,
        duration: duration ?? Duration(milliseconds: track.durationMs),
      );

  void _onEvent(MediaControlEvent event) {
    if (_override?.handle(event) ?? false) return;
    switch (event) {
      case MediaButtonEvent(button: MediaButton.play):
        if (!playback.isPlaybackActive) unawaited(playback.togglePlayPause());
      case MediaButtonEvent(button: MediaButton.pause || MediaButton.stop):
        unawaited(playback.pause());
      case MediaButtonEvent(button: MediaButton.toggle):
        unawaited(playback.togglePlayPause());
      case MediaButtonEvent(button: MediaButton.next):
        unawaited(playback.nextTrack());
      case MediaButtonEvent(button: MediaButton.previous):
        unawaited(playback.previousTrack());
      case MediaSeekEvent(:final position):
        unawaited(playback.seekTo(position));
    }
  }

  void dispose() {
    if (widget?.onPlayQueueItem == _playQueueItem) {
      widget?.onPlayQueueItem = null;
    }
    _override?.changes.removeListener(_sync);
    _override?.position.removeListener(_onPosition);
    playback.removeListener(_sync);
    playback.positionNotifier.removeListener(_onPosition);
    _events?.cancel();
    controls.dispose();
  }
}
