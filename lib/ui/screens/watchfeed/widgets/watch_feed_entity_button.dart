import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/watch_feed.dart';
import '../../../../providers/spotify_provider.dart';
import '../../../navigation/app_routes.dart';
import '../../../shell/shell_breakpoints.dart';
import '../../../widgets/cover_image.dart';

/// 艺人 / 专辑 / 歌单页操作行里的发现流入口（对齐官方桌面网页版 desktop-watch-feed-entity-button）。
///
/// 只在桌面布局显示，且该实体确实有视频流时才出现（首次构建时预取第一页，打开时直接复用）。
/// 38×48 透明按钮：30×40 的竖版缩略图（第一条的 Canvas 首帧或封面，圆角 4），
/// 出现时描一圈一次性的边框动画；悬停时盖一层深色并显示播放图标。
class WatchFeedEntityButton extends StatefulWidget {
  const WatchFeedEntityButton({
    super.key,
    required this.feedUri,
    required this.name,
  });

  /// `spotify:watch-feed:{artist|album|playlist}:<id>`
  final String feedUri;

  /// 实体名称（提示文字与 feed 标题）。
  final String name;

  /// 实体 uri（`spotify:artist:xxx` 等）→ 对应的 feed uri；不支持的类型返回 null。
  static String? feedUriFor(String entityUri) {
    final parts = entityUri.split(':');
    if (parts.length != 3 || parts.first != 'spotify') return null;
    const kinds = {'artist', 'album', 'playlist'};
    if (!kinds.contains(parts[1]) || parts[2].isEmpty) return null;
    return 'spotify:watch-feed:${parts[1]}:${parts[2]}';
  }

  @override
  State<WatchFeedEntityButton> createState() => _WatchFeedEntityButtonState();
}

class _WatchFeedEntityButtonState extends State<WatchFeedEntityButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _border;
  bool _hover = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _border = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void dispose() {
    _border.dispose();
    super.dispose();
  }

  void _request() {
    if (_requested) return;
    _requested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<SpotifyProvider?>()?.loadEntityFeed(widget.feedUri);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      return const SizedBox.shrink();
    }
    _request();
    final page = context.select<SpotifyProvider?, WatchFeedEntityPage?>(
      (p) => p?.entityFeedFor(widget.feedUri),
    );
    if (page == null || page.items.isEmpty) return const SizedBox.shrink();
    if (!_border.isAnimating && _border.value == 0) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _border.value = 1;
      } else {
        _border.forward();
      }
    }
    final thumbnail = page.items.first.visual.imageUrl;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: context.l10n.watchFeedEntityTooltip(widget.name),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            key: const Key('watch-feed-entity-button'),
            onTap: () => AppRoutes.openWatchFeed(
              context,
              widget.feedUri,
              title: widget.name,
              initialPage: page,
            ),
            child: SizedBox(
              width: 38,
              height: 48,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _BorderSweepPainter(_border)),
                  ),
                  Positioned(
                    left: 4,
                    top: 4,
                    width: 30,
                    height: 40,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          thumbnail.isEmpty
                              ? const ColoredBox(
                                  color: Color(0xFF2A2A2A),
                                  child: Icon(
                                    Icons.video_library_outlined,
                                    size: 16,
                                    color: Colors.white70,
                                  ),
                                )
                              : CoverImage(url: thumbnail),
                          AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                            child: const ColoredBox(
                              color: Color(0xCC121212),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一次性的边框描绘：白色描边沿圆角矩形走一圈，走完后淡成浅灰常驻
/// （官方用 watch-feed-entry-point-border Lottie，播一次不循环）。
class _BorderSweepPainter extends CustomPainter {
  _BorderSweepPainter(this.progress) : super(repaint: progress);

  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0) return;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(1),
      const Radius.circular(6),
    );
    final path = Path()..addRRect(rrect);
    final draw = (t / 0.8).clamp(0.0, 1.0);
    final settle = ((t - 0.8) / 0.2).clamp(0.0, 1.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Color.lerp(Colors.white, const Color(0x4DFFFFFF), settle)!;
    for (final PathMetric metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * draw), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BorderSweepPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
