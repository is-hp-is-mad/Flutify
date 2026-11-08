import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../providers/connect_provider.dart';
import '../../screens/player/device_picker_sheet.dart';
import '../../screens/player/full_player_sheet.dart';
import '../../shell/shell_layout_controller.dart';
import '../desktop_player_bar.dart';
import '../playback_status_button.dart';
import '../player_bar_cover.dart';
import '../marquee_text.dart';
import 'connect_device_icon.dart';
import 'remote_progress.dart';
import 'remote_transport_controls.dart';

/// 桌面端播放栏的远程模式：内容与按钮作用于正在使用的远程设备。
///
/// 与本机播放栏相同的悬浮液态玻璃胶囊（左曲目 / 中控制 + 进度 / 右设备与音量），
/// 胶囊底部合并一条强调色细条「正在 {设备} 上播放」（通宽、圆角随胶囊）；
/// 点细条或设备键打开设备面板，点封面打开全屏播放器（远程模式同样可打开）。
class RemotePlayerBar extends StatelessWidget {
  const RemotePlayerBar({super.key});

  /// 细条露出高度（含在胶囊内）；总占位另计（见 [reservedHeight]）。
  static const double stripHeight = 21;
  static const double reservedHeight =
      DesktopPlayerBar.reservedHeight + stripHeight;

  @override
  Widget build(BuildContext context) {
    return PlayerBarGlassCapsule(
      attachment: const RemotePlayingStrip(height: stripHeight),
      attachmentVisibleHeight: stripHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sideWidth = (constraints.maxWidth * 0.28).clamp(160.0, 300.0);
          return Row(
            children: [
              SizedBox(width: sideWidth, child: const _RemoteTrackInfo()),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [RemoteTransportControls(), RemoteScrubber()],
                    ),
                  ),
                ),
              ),
              SizedBox(width: sideWidth, child: const _RemoteRightControls()),
            ],
          );
        },
      ),
    );
  }
}

/// 远程曲目：封面 + 标题 + 艺人（补全前回退为专辑名）。
class _RemoteTrackInfo extends StatelessWidget {
  const _RemoteTrackInfo();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connect = context.watch<ConnectProvider>();
    final player = connect.player;
    final track = connect.remoteTrack;
    final title = track?.name ?? player.title;
    final subtitle = track?.artistNames ?? player.albumTitle;
    final layout = context.watch<ShellLayoutController?>();
    return Row(
      children: [
        // 点封面：右栏关着时打开「正在播放」；没有三栏框架时打开全屏播放器（与本机播放栏一致）
        PlayerBarCover(
          url: track?.coverUrl ?? player.imageUrl,
          layout: layout,
          onOpenFallback: layout == null ? () => FullPlayerSheet.show(context) : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(
                text: title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 右侧：正在播放 / 歌词（右栏标签，远程曲目同样可看）+ 设备键（强调色，表示正在遥控）+ 远程音量。
class _RemoteRightControls extends StatelessWidget {
  const _RemoteRightControls();

  static const double _sliderWidth = 92;
  static const double _buttonSize = 36;
  static final ButtonStyle _style = IconButton.styleFrom(
    fixedSize: const Size.square(_buttonSize),
    minimumSize: const Size.square(_buttonSize),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final connect = context.watch<ConnectProvider>();
    final device = connect.activeDevice;
    // 「播放状态」键：三栏框架下开关右栏；没有框架（单独使用播放栏）时回退为底部歌词面板
    final layout = context.watch<ShellLayoutController?>();

    return LayoutBuilder(
      builder: (context, constraints) {
        final showPanels = constraints.maxWidth >= 2 * _buttonSize;
        final used = (showPanels ? 2 : 1) * _buttonSize;
        final showSlider =
            device != null &&
            device.supportsVolume &&
            constraints.maxWidth >= used + _sliderWidth + 8;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (showPanels) PlaybackStatusButton(layout: layout, style: _style),
            IconButton(
              icon: Icon(
                device == null
                    ? Icons.devices_rounded
                    : connectDeviceIcon(device.type),
                size: 20,
              ),
              color: tokens.accent,
              tooltip: context.l10n.deviceConnectTitle,
              style: _style,
              onPressed: () => DevicePickerSheet.show(context),
            ),
            if (showSlider)
              SizedBox(
                width: _sliderWidth,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.0,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 4,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 8,
                    ),
                  ),
                  child: Slider(
                    value: connect.volume,
                    onChanged: connect.setVolume,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 「正在 {设备} 上播放」强调色小条，包裹播放栏胶囊底部：
/// 与胶囊同宽，顶部两角沿胶囊底角圆弧上卷（[AttachedStripShape]）；点按打开设备面板。
class RemotePlayingStrip extends StatelessWidget {
  final double height;

  const RemotePlayingStrip({super.key, this.height = 26});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final device = context.select<ConnectProvider, (String, IconData)?>((c) {
      final d = c.activeDevice;
      return d == null ? null : (d.name, connectDeviceIcon(d.type));
    });
    if (device == null) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: tokens.onAccent,
      fontWeight: FontWeight.w600,
    );
    // 包裹胶囊底部：总高 = 露出高度 + 胶囊圆角（上卷部分叠在胶囊底角上），
    // 文字放在底部露出区域内；通宽，圆角随胶囊（含设置页的圆角风格）
    final corner = tokens.corner(28);
    final shape = AttachedStripShape(cornerRadius: corner);
    return Material(
      color: tokens.accent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        mouseCursor: SystemMouseCursors.click,
        onTap: () => DevicePickerSheet.show(context),
        child: SizedBox(
          height: height + corner,
          child: Padding(
            padding: EdgeInsets.only(top: corner),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(device.$2, size: 12, color: tokens.onAccent),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        context.l10n.connectPlayingOn(device.$1),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
