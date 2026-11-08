import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/playback_provider.dart';

/// App 切到后台 / 即将被系统回收时保存播放会话（手机上划掉 App 时进程会被直接杀掉）。
/// 桌面端关窗由 `DesktopWindow.addBeforeCloseHook` 负责。
class PlaybackSessionKeeper extends StatefulWidget {
  final Widget child;

  const PlaybackSessionKeeper({super.key, required this.child});

  @override
  State<PlaybackSessionKeeper> createState() => _PlaybackSessionKeeperState();
}

class _PlaybackSessionKeeperState extends State<PlaybackSessionKeeper> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onHide: _flush, onPause: _flush, onDetach: _flush);
  }

  void _flush() {
    if (!mounted) return;
    context.read<PlaybackProvider>().flushSession();
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
