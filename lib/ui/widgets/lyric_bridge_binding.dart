import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_preferences.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/spotify_provider.dart';
import '../../services/lyric_bridge/lyric_metadata_controls.dart';

/// 把蓝牙（车机）歌词 / Flyme 状态栏歌词接到界面状态上：
/// - 歌词来源 = SpotifyProvider（与 App 内歌词、任务栏歌词共享缓存与补全）；
/// - 设置变化时同步开关、译文、手动加入的设备。
/// 没有注入 [LyricMetadataControls]（非 Android、测试）时原样返回 [child]。
class LyricBridgeBinding extends StatefulWidget {
  final Widget child;

  const LyricBridgeBinding({super.key, required this.child});

  @override
  State<LyricBridgeBinding> createState() => _LyricBridgeBindingState();
}

class _LyricBridgeBindingState extends State<LyricBridgeBinding> {
  LyricMetadataControls? _controls;
  StreamSubscription<String>? _lyricsCached;

  @override
  void initState() {
    super.initState();
    final controls = context.read<LyricMetadataControls?>();
    _controls = controls;
    if (controls == null) return;
    final spotify = context.read<SpotifyProvider>();
    controls
      ..lyricsLoader = spotify.fetchLyrics
      ..lyricsSourceReady();
    _lyricsCached = spotify.lyricsCached.listen(controls.lyricsCached);
  }

  @override
  void dispose() {
    unawaited(_lyricsCached?.cancel());
    _controls?.lyricsLoader = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controls = _controls;
    if (controls == null) return widget.child;
    final prefs = context.select<PreferencesProvider, AppPreferences>(
      (p) => p.prefs,
    );
    controls.configure(
      mode: prefs.bluetoothLyrics,
      withTranslation: prefs.bluetoothLyricsTranslation,
      extraDevices: prefs.bluetoothLyricsDevices,
      flymeStatusBar: prefs.flymeStatusBarLyrics,
    );
    return widget.child;
  }
}
