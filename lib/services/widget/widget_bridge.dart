import 'dart:async';

import 'package:flutter/services.dart';

import '../../models/app_preferences.dart';
import '../media_controls/system_media_controls.dart';

/// 桌面小组件的款式；[id] 与原生 WidgetBridgePlugin.requestPin 约定一致。
enum HomeWidgetStyle {
  nowPlaying('nowPlaying'),
  albumCard('albumCard'),
  cover('cover'),
  upNext('upNext');

  const HomeWidgetStyle(this.id);
  final String id;
}

/// Android 桌面小组件桥：把播放态经 MethodChannel 推给原生 Glance widget。
///
/// 原生侧把状态写入后刷新 widget；非 Android 或原生未注册插件时 invokeMethod 抛
/// [PlatformException] / [MissingPluginException]，静默降级——小组件是展示增强，不影响播放主流程。
///
/// 换曲时封面要先下载落盘：[coverWait] 内拿到就和文字一起下发；拿不到先下发文字
/// （小组件立刻换歌名，封面位显示占位），封面就绪后再补发一次。同一封面地址只解析一次，
/// 期间新的 [update]（播放 / 暂停等）复用同一次解析；被更新的推送取代的旧推送不再下发，避免乱序覆盖。
class WidgetBridge {
  static const MethodChannel _ch = MethodChannel('flutify/widget_bridge');

  static const Duration coverWait = Duration(milliseconds: 600);
  static const Duration coverTimeout = Duration(seconds: 5);

  /// 远程封面 URL → 本地文件路径；与注入 SystemMediaControls 的是同一份 resolver。
  final Future<String?> Function(String url) artworkFile;

  /// 小组件「待播清单」点了第 index 项（曲目 id 用于校验队列没变）；返回是否已开始播放。
  Future<bool> Function(int index, String trackId)? onPlayQueueItem;

  int _generation = 0;
  String? _localeTag;
  String? _coverUrl;
  Future<String?>? _cover;

  WidgetBridge({required this.artworkFile}) {
    _ch.setMethodCallHandler(_handleCall);
  }

  Future<void> update(MediaTrackInfo track, MediaPlaybackInfo playback) async {
    final generation = ++_generation;
    final cover = _resolveCover(track.artUrl);
    String? coverPath;
    var pending = false;
    if (cover != null) {
      try {
        coverPath = await cover.timeout(coverWait);
      } on TimeoutException {
        pending = true;
      } catch (_) {}
    }
    if (generation != _generation) return;
    await _send(track, playback, coverPath);
    if (!pending) return;
    try {
      coverPath = await cover!.timeout(coverTimeout - coverWait);
    } catch (_) {
      return;
    }
    if (generation != _generation || coverPath == null) return;
    await _send(track, playback, coverPath);
  }

  /// 「来自 xx」与接下来的几首；内容没变时调用方不必重复推送。
  Future<void> updateQueue(String contextName, List<MediaTrackInfo> next) =>
      _invoke('queue', {
        'context': contextName,
        'items': [
          for (final t in next)
            {'id': t.id, 'title': t.title, 'artist': t.artist},
        ],
      });

  Future<void> clear() {
    ++_generation;
    return _invoke('clear');
  }

  /// 把 App 内语言同步成 Android 的单应用语言（13+），小组件里的文字随之切换；同值不重复下发。
  ///
  /// 桌面小组件列表里的名称 / 描述由桌面按系统语言读取，不受这里影响。
  Future<void> syncLanguage(AppLanguage language) {
    final tag = switch (language) {
      AppLanguage.system => '',
      AppLanguage.zh => 'zh-CN',
      AppLanguage.zhHant => 'zh-TW',
      AppLanguage.en => 'en',
      AppLanguage.ja => 'ja',
    };
    if (tag == _localeTag) return Future.value();
    _localeTag = tag;
    return _invoke('setLocale', tag);
  }

  /// 请求桌面添加 [style] 款小组件（随后由系统弹窗确认）；桌面不支持或失败时返回 false。
  ///
  /// 澎湃 OS 里经典小组件藏在小组件列表底部的「安卓小部件」分区，这是更直接的添加方式。
  Future<bool> requestPin(HomeWidgetStyle style) async {
    try {
      return await _ch.invokeMethod<bool>('requestPin', style.id) ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  Future<String?>? _resolveCover(String url) {
    if (url.isEmpty) return null;
    if (url == _coverUrl && _cover != null) return _cover;
    _coverUrl = url;
    final future = artworkFile(url).then<String?>(
      (path) => path == null || path.isEmpty ? null : path,
      onError: (Object _) {
        // 失败不缓存：下次推送（例如播放 / 暂停）再试
        if (_coverUrl == url) _cover = null;
        return null;
      },
    );
    return _cover = future;
  }

  Future<void> _send(
    MediaTrackInfo track,
    MediaPlaybackInfo playback,
    String? coverPath,
  ) => _invoke('update', {
    'id': track.id,
    'title': track.title,
    'artist': track.artist,
    'album': track.album,
    'durationMs': track.duration.inMilliseconds,
    'isPlaying': playback.playing,
    'isBuffering': playback.buffering,
    'coverPath': coverPath,
  });

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _ch.invokeMethod(method, arguments);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'playQueueItem') return null;
    final args = call.arguments;
    if (args is! Map) return false;
    final index = args['index'];
    final id = args['id'];
    final handler = onPlayQueueItem;
    if (handler == null || index is! int || id is! String) return false;
    return handler(index, id);
  }
}
