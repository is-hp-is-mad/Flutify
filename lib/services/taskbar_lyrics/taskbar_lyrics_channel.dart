import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/app_preferences.dart';
import '../../models/lyrics.dart';

/// 任务栏歌词的外观：颜色模式、各模式下的颜色、整体不透明度，以及右键菜单文案。
@immutable
class TaskbarLyricsStyle {
  final TaskbarLyricsColor mode;
  final int customColor;

  /// 跟随强调色时：深色任务栏上用的亮色调、浅色任务栏上用的暗色调（ARGB）。
  final int accentOnDark;
  final int accentOnLight;
  final int opacity;

  /// 字号百分比（100 = 默认）。
  final int fontScale;
  final String openLabel;
  final String refetchLabel;
  final String disableLabel;

  const TaskbarLyricsStyle({
    this.mode = TaskbarLyricsColor.auto,
    this.customColor = AppPreferences.defaultTaskbarLyricsCustomColor,
    this.accentOnDark = 0xFF1ED760,
    this.accentOnLight = 0xFF1DB954,
    this.opacity = 100,
    this.fontScale = 100,
    this.openLabel = '',
    this.refetchLabel = '',
    this.disableLabel = '',
  });

  Map<String, Object> toMap() => {
    'mode': mode.name,
    'custom': customColor,
    'accentOnDark': accentOnDark,
    'accentOnLight': accentOnLight,
    'opacity': opacity,
    'fontScale': fontScale,
    'labels': {
      'open': openLabel,
      'refetch': refetchLabel,
      'disable': disableLabel,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is TaskbarLyricsStyle &&
      other.mode == mode &&
      other.customColor == customColor &&
      other.accentOnDark == accentOnDark &&
      other.accentOnLight == accentOnLight &&
      other.opacity == opacity &&
      other.fontScale == fontScale &&
      other.openLabel == openLabel &&
      other.refetchLabel == refetchLabel &&
      other.disableLabel == disableLabel;

  @override
  int get hashCode => Object.hash(
    mode,
    customColor,
    accentOnDark,
    accentOnLight,
    opacity,
    fontScale,
    openLabel,
    refetchLabel,
    disableLabel,
  );
}

/// 任务栏上的用户操作。
enum TaskbarLyricsEvent { previous, toggle, next, open, refetch, disable }

/// 与原生任务栏歌词窗口通信的接口（测试注入内存实现）。
abstract interface class TaskbarLyricsPlatform {
  Stream<TaskbarLyricsEvent> get events;

  Future<void> setEnabled(bool enabled);
  Future<void> setStyle(TaskbarLyricsStyle style);

  /// null 清除曲目（窗口隐藏）。
  Future<void> setTrack(({String title, String artist})? track);

  /// 封面原始字节（JPEG / PNG）；null 显示占位。
  Future<void> setArt(Uint8List? bytes);

  /// 逐行同步歌词；null / 空表示没有，窗口显示控制条。
  Future<void> setLyrics(List<LyricLine>? lines);

  Future<void> setPlayback({
    required bool playing,
    required Duration position,
    bool muteButton = false,
    bool muted = false,
  });
}

/// Windows 原生实现：`windows/runner/taskbar_lyrics.cpp`，MethodChannel `flutify/taskbar_lyrics`。
///
/// 原生端不可用（测试、旧版 runner）时静默忽略：任务栏歌词只是锦上添花，不能影响 App。
class MethodChannelTaskbarLyrics implements TaskbarLyricsPlatform {
  static const MethodChannel _channel = MethodChannel('flutify/taskbar_lyrics');

  final StreamController<TaskbarLyricsEvent> _events =
      StreamController.broadcast();

  MethodChannelTaskbarLyrics() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'event') return;
      final event = TaskbarLyricsEvent.values
          .where((e) => e.name == call.arguments)
          .firstOrNull;
      if (event != null) _events.add(event);
    });
  }

  @override
  Stream<TaskbarLyricsEvent> get events => _events.stream;

  @override
  Future<void> setEnabled(bool enabled) => _invoke('setEnabled', enabled);

  @override
  Future<void> setStyle(TaskbarLyricsStyle style) =>
      _invoke('setStyle', style.toMap());

  @override
  Future<void> setTrack(({String title, String artist})? track) => _invoke(
    'setTrack',
    track == null ? null : {'title': track.title, 'artist': track.artist},
  );

  @override
  Future<void> setArt(Uint8List? bytes) => _invoke('setArt', bytes);

  @override
  Future<void> setLyrics(List<LyricLine>? lines) => _invoke(
    'setLyrics',
    lines == null || lines.isEmpty
        ? null
        : {
            'times': Int32List.fromList([for (final l in lines) l.startTimeMs]),
            'texts': [for (final l in lines) l.words],
            // 译文（双语歌词），原生端在当前句下方画一行小字；恒为与 texts 等长的数组（可全为空串）
            'texts2': [for (final l in lines) l.translation],
          },
  );

  @override
  Future<void> setPlayback({
    required bool playing,
    required Duration position,
    bool muteButton = false,
    bool muted = false,
  }) => _invoke('setPlayback', {
    'playing': playing,
    'positionMs': position.inMilliseconds,
    'muteButton': muteButton,
    'muted': muted,
  });

  Future<void> _invoke(String method, Object? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // 忽略
    } on PlatformException {
      // 忽略
    }
  }
}
