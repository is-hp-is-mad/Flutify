import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/formatters.dart';
import '../../../providers/connect_provider.dart';
import 'connect_actions.dart';

/// 远程播放进度：服务端只在状态变化时推送，进度按「快照进度 + 服务端时间差」每 500ms 推算一次。
class RemoteProgressBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, int positionMs, int durationMs) builder;

  const RemoteProgressBuilder({super.key, required this.builder});

  @override
  State<RemoteProgressBuilder> createState() => _RemoteProgressBuilderState();
}

class _RemoteProgressBuilderState extends State<RemoteProgressBuilder> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connect = context.watch<ConnectProvider>();
    final player = connect.player;
    return widget.builder(context, player.positionAt(connect.serverNowMs), player.durationMs);
  }
}

/// 远程进度条：时间 + 可拖动滑块；松手后向远程设备发送 seek。
class RemoteScrubber extends StatefulWidget {
  /// 紧凑模式（桌面播放栏）：细轨道、小圆点。
  final bool compact;
  final double? compactProgress;

  /// 颜色（歌词玻璃控制台用白色）；为 null 时跟随主题。
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? labelColor;

  const RemoteScrubber({super.key, this.compact = true, this.compactProgress, this.activeColor, this.inactiveColor, this.labelColor});

  @override
  State<RemoteScrubber> createState() => _RemoteScrubberState();
}

class _RemoteScrubberState extends State<RemoteScrubber> {
  /// 拖动中的位置（毫秒）；为 null 时跟随推算进度。
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final compactness = widget.compactProgress ?? (widget.compact ? 1.0 : 0.0);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: widget.labelColor ?? colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return RemoteProgressBuilder(
      builder: (context, positionMs, durationMs) {
        final max = durationMs > 0 ? durationMs.toDouble() : 1.0;
        final value = (_dragMs ?? positionMs.toDouble()).clamp(0.0, max);
        return Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(Formatters.formatDurationMs(value.round()), textAlign: TextAlign.right, style: labelStyle),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: lerpDouble(4, 3, compactness),
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: lerpDouble(7, 5, compactness)!),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: lerpDouble(16, 10, compactness)!),
                  activeTrackColor: widget.activeColor,
                  thumbColor: widget.activeColor,
                  inactiveTrackColor: widget.inactiveColor,
                ),
                child: Slider(
                  value: value,
                  max: max,
                  onChanged: durationMs > 0 ? (v) => setState(() => _dragMs = v) : null,
                  onChangeEnd: (v) {
                    setState(() => _dragMs = null);
                    final connect = context.read<ConnectProvider>();
                    ConnectActions.run(context, () => connect.seekTo(v.round()));
                  },
                ),
              ),
            ),
            SizedBox(width: 40, child: Text(Formatters.formatDurationMs(durationMs), style: labelStyle)),
          ],
        );
      },
    );
  }
}
