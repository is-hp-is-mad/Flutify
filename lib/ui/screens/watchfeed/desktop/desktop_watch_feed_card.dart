import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/utils/artwork_palette.dart';
import '../../../../models/watch_feed.dart';
import '../../../../services/watchfeed/preview_player.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/looping_video.dart';

/// 对话框底：当前曲目封面的深色（0.5s 过渡），叠一层从右侧中心透明、35% 处变为页面底色的径向渐变；
/// 1px 描边、圆角 8。
///
/// 颜色优先用服务端给的封面深色，没有时从封面取色。无论哪种来源，组件结构都保持不变——
/// 结构一变，里面的轮播会被整个重建并回到初始页（曾导致翻几首后跳回第一首、封面对不上）。
class DesktopWatchFeedDialogBackground extends StatefulWidget {
  const DesktopWatchFeedDialogBackground({
    super.key,
    required this.item,
    required this.width,
    required this.height,
    required this.child,
  });

  final WatchFeedItem? item;
  final double width;
  final double height;
  final Widget child;

  @override
  State<DesktopWatchFeedDialogBackground> createState() =>
      _DesktopWatchFeedDialogBackgroundState();
}

class _DesktopWatchFeedDialogBackgroundState
    extends State<DesktopWatchFeedDialogBackground> {
  static const Color _base = Color(0xFF121212);
  static const Color _fallback = Color(0xFF7F7F7F);

  Color _color = _base;

  /// 正在取色的封面；过期结果丢弃。
  String? _resolving;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant DesktopWatchFeedDialogBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.id != widget.item?.id) _resolve();
  }

  void _resolve() {
    final item = widget.item;
    if (item == null) {
      _resolving = null;
      _color = _base;
      return;
    }
    final server = item.backgroundColor;
    if (server != null) {
      _resolving = null;
      _color = Color(server);
      return;
    }
    final url = item.visual.imageUrl;
    final cached = ArtworkPalette.cached(url);
    if (cached != null) {
      _resolving = null;
      _color = cached;
      return;
    }
    _resolving = url;
    ArtworkPalette.resolve(url).then((color) {
      if (!mounted || _resolving != url) return;
      setState(() => _color = color ?? _fallback);
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    final h = widget.height;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: _color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1F1F1F)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.centerRight,
              // CSS 圆的半径是到最远角的距离；Flutter 的 radius 以短边为单位。
              radius: math.sqrt(w * w + h * h / 4) / math.min(w, h),
              colors: const [Color(0x00121212), _base],
              stops: const [0, 0.35],
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 一张 9:16 卡片。
/// - 有 Canvas：首帧图垫底，当前卡片播放静音循环视频；
/// - 无 Canvas：只有正方形封面居中（不画 9:16 底色块，滑动时封面周围不会出现灰色方块），
///   当前卡片封面缩到 0.85，背后跳动均衡器竖条。
/// 当前卡片外加 0.5s 淡入的投影；点非当前卡片跳到它。
class DesktopWatchFeedCard extends StatelessWidget {
  const DesktopWatchFeedCard({
    super.key,
    required this.item,
    required this.active,
    required this.onTap,
  });

  final WatchFeedItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final playing = context.select<WatchFeedPreviewPlayer, bool>(
      (p) => p.isPlaying || p.isLoading,
    );
    final canvas = item.visual.kind == WatchFeedVisualKind.canvas;
    final dark = Color(item.backgroundColor ?? 0xFF535353);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = MediaQuery.sizeOf(context);
        final blur = math.min(60.0, math.min(size.width, size.height) * 0.03);
        return GestureDetector(
          onTap: active ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, active && canvas ? 0.5 : 0),
                  offset: const Offset(0, 4),
                  blurRadius: blur,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: canvas
                  ? ColoredBox(
                      color: dark,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CoverImage(url: item.visual.imageUrl),
                          if (active)
                            LoopingVideo(
                              videoUrl: item.visual.videoUrl,
                              posterUrl: item.visual.imageUrl,
                              playing: playing,
                            ),
                        ],
                      ),
                    )
                  : _CoverCard(
                      item: item,
                      active: active,
                      playing: playing,
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _CoverCard extends StatelessWidget {
  const _CoverCard({
    required this.item,
    required this.active,
    required this.playing,
    required this.width,
    required this.height,
  });

  final WatchFeedItem item;
  final bool active;
  final bool playing;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (active)
          Center(
            child: _EqualizerBars(
              width: width,
              height: height,
              playing: playing,
            ),
          ),
        Center(
          child: AnimatedScale(
            scale: active ? 0.85 : 1,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            child: SizedBox.square(
              dimension: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: active
                      ? const [
                          BoxShadow(
                            color: Color(0x80000000),
                            offset: Offset(0, 4),
                            blurRadius: 30,
                          ),
                        ]
                      : null,
                ),
                child: CoverImage(
                  url: item.visual.imageUrl,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 无 Canvas 卡片背后的均衡器：左 4 根 + 中间留白（被封面挡住）+ 右 4 根，白色 30%，
/// 每根 0.85s 循环上下伸缩、相位错开；激活 200ms 后出现，两端渐隐。
class _EqualizerBars extends StatefulWidget {
  const _EqualizerBars({
    required this.width,
    required this.height,
    required this.playing,
  });

  final double width;
  final double height;
  final bool playing;

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );
  bool _visible = false;
  Timer? _delay;

  /// 各根的峰值缩放（官方关键帧在 0.8 ~ 1.4 之间）。
  static const _peaks = [1.2, 0.8, 1.4, 1.0, 1.0, 1.4, 0.8, 1.2];

  @override
  void initState() {
    super.initState();
    _delay = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _EqualizerBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.playing && !MediaQuery.disableAnimationsOf(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final barW = math.min(widget.width * 0.017, 8.0);
    final barH = widget.height * 0.05;
    final spacer = widget.width * 0.7 - math.min(widget.width * 0.02, 8.0);
    Widget bar(int i) => AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final phase = (_controller.value + i * 0.17) % 1.0;
        final wave = 0.5 - 0.5 * math.cos(phase * 2 * math.pi);
        final scale = 0.6 + (_peaks[i] - 0.6) * wave;
        return Transform.scale(
          scaleY: scale,
          child: Container(
            width: barW,
            height: barH,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: const Color(0x4DFFFFFF),
              borderRadius: BorderRadius.circular(barW),
            ),
          ),
        );
      },
    );
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: OverflowBox(
        maxWidth: widget.width * 1.2,
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            colors: [
              Color(0x00FFFFFF),
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x00FFFFFF),
            ],
            stops: [0, 0.15, 0.85, 1],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 4; i++) bar(i),
              SizedBox(width: spacer),
              for (var i = 4; i < 8; i++) bar(i),
            ],
          ),
        ),
      ),
    );
  }
}
