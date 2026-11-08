import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'audio_service_media_controls.dart';
import 'macos_media_controls.dart';
import 'windows_media_controls.dart';

/// 交给系统显示的曲目信息。
class MediaTrackInfo {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String artUrl;
  final Duration duration;

  const MediaTrackInfo({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.artUrl,
    required this.duration,
  });
}

/// 交给系统的播放状态。
class MediaPlaybackInfo {
  final bool playing;
  final bool buffering;
  final Duration position;
  final bool canNext;
  final bool canPrevious;

  const MediaPlaybackInfo({
    required this.playing,
    required this.buffering,
    required this.position,
    required this.canNext,
    required this.canPrevious,
  });
}

/// 系统发来的操作（媒体键、任务栏 / 锁屏媒体卡片、通知栏、耳机线控）。
sealed class MediaControlEvent {
  const MediaControlEvent();
}

enum MediaButton { play, pause, toggle, next, previous, stop }

class MediaButtonEvent extends MediaControlEvent {
  final MediaButton button;
  const MediaButtonEvent(this.button);
}

class MediaSeekEvent extends MediaControlEvent {
  final Duration position;
  const MediaSeekEvent(this.position);
}

/// 系统媒体控制：Windows 为 SMTC（任务栏 / 锁屏媒体卡片、键盘媒体键），
/// macOS 为 Now Playing + MPRemoteCommandCenter（Control Center / 触控栏 / 键盘媒体键），
/// Android / iOS 为 audio_service（通知栏、锁屏、蓝牙耳机按键）。
abstract class SystemMediaControls {
  Stream<MediaControlEvent> get events;

  /// 更新曲目；null 表示清除（没有当前曲目时系统不再显示媒体卡片）。
  Future<void> setTrack(MediaTrackInfo? track);

  Future<void> setPlayback(MediaPlaybackInfo info);

  /// 系统自己不推算进度的平台（Windows SMTC）需要定期更新时间线；会推算的平台忽略。
  bool get needsPeriodicTimeline;

  void dispose();

  /// 按当前平台创建；不支持的平台（Linux / Web）返回 null。
  static Future<SystemMediaControls?> create({
    ArtworkFileResolver? artworkFile,
  }) async {
    if (kIsWeb) return null;
    try {
      if (Platform.isWindows) return WindowsMediaControls();
      if (Platform.isMacOS) return MacOSMediaControls();
      if (Platform.isAndroid || Platform.isIOS) {
        return await AudioServiceMediaControls.init(artworkFile: artworkFile);
      }
    } catch (e) {
      debugPrint('系统媒体控制初始化失败：$e');
    }
    return null;
  }
}
