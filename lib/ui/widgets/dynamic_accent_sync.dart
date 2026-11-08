import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../core/utils/artwork_palette.dart';
import '../../providers/appearance_provider.dart';
import 'connect/now_playing_source.dart';

/// 动态取色：当前曲目换封面时取主色，交给 [AppearanceProvider]（仅在开启「跟随封面取色」时取色）。
///
/// 放在 MaterialApp 之外，只订阅封面 URL 与开关两个字段，播放进度变化不会触发它。
class DynamicAccentSync extends StatefulWidget {
  final Widget child;

  const DynamicAccentSync({super.key, required this.child});

  @override
  State<DynamicAccentSync> createState() => _DynamicAccentSyncState();
}

class _DynamicAccentSyncState extends State<DynamicAccentSync> {
  String? _resolvedUrl;

  void _sync(String url, bool enabled) {
    if (!enabled || url == _resolvedUrl) return;
    _resolvedUrl = url;
    final appearance = context.read<AppearanceProvider>();
    if (url.isEmpty) {
      appearance.setArtworkColor(null);
      return;
    }
    final cached = ArtworkPalette.cached(url);
    if (cached != null) {
      appearance.setArtworkColor(cached);
      return;
    }
    ArtworkPalette.resolve(url).then((color) {
      // 取色期间又切了歌：丢弃过期结果
      if (mounted && _resolvedUrl == url) appearance.setArtworkColor(color);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 遥控远程设备时跟随远程曲目的封面
    final url = NowPlayingSource.track(context)?.coverUrl ?? '';
    final enabled = context.select<AppearanceProvider, bool>((a) => a.settings.dynamicAccent);
    if (!enabled) _resolvedUrl = null;
    // 构建期间不能通知其他监听者，放到帧末
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(url, enabled);
    });
    return widget.child;
  }
}
