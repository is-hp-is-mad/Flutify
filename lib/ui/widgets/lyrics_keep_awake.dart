import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/preferences_provider.dart';
import '../../services/screen_awake/screen_awake.dart';

/// 歌词界面显示期间保持屏幕常亮（设置页「自定义功能」开启时）。
///
/// 包在歌词视图外面：歌词视图卸载、或像 Android 播放页那样收起后常驻在 Offstage 里
/// （外面的 TickerMode 关掉），以及关闭开关时，都恢复自动熄屏。
class LyricsKeepAwake extends StatefulWidget {
  final Widget child;

  const LyricsKeepAwake({super.key, required this.child});

  @override
  State<LyricsKeepAwake> createState() => _LyricsKeepAwakeState();
}

class _LyricsKeepAwakeState extends State<LyricsKeepAwake> {
  @override
  Widget build(BuildContext context) {
    final enabled = context.select<PreferencesProvider?, bool>(
      (p) => p?.prefs.lyricsKeepScreenOn ?? false,
    );
    if (enabled && TickerMode.valuesOf(context).enabled) {
      ScreenAwake.acquire(this);
    } else {
      ScreenAwake.release(this);
    }
    return widget.child;
  }

  @override
  void dispose() {
    ScreenAwake.release(this);
    super.dispose();
  }
}
