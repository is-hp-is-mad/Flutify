import 'package:flutter/material.dart';

import '../../../../models/watch_feed.dart';
import '../../../navigation/app_routes.dart';
import '../../../widgets/looping_video.dart';

/// 发现流入口卡片行（对齐官方 watchfeedentrypointvideo_card_layout）：标题 + 横滑竖版视频卡。
///
/// 卡片圆角 8，画面静音循环播放 Canvas（被其他页面压住时暂停），底部 40% 起渐暗，
/// 左下角依次为 overline / 加粗标题（通常就是「#标签」）/ subtitle。点击进入对应 feed。
class WatchFeedShelfRow extends StatefulWidget {
  const WatchFeedShelfRow({
    super.key,
    required this.shelf,
    required this.fallbackTitle,
    this.aspectRatio = 2 / 3,
    this.cardWidth = 140,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final WatchFeedShelf shelf;

  /// 服务端没给标题时显示。
  final String fallbackTitle;

  /// 卡片宽高比：搜索页 / 首页为 2:3，其余入口为 9:16（官方 c8l1）。
  final double aspectRatio;
  final double cardWidth;
  final EdgeInsets padding;

  @override
  State<WatchFeedShelfRow> createState() => _WatchFeedShelfRowState();
}

/// 卡片间距。
const double _kGap = 12;

class _WatchFeedShelfRowState extends State<WatchFeedShelfRow> {
  final ScrollController _scroll = ScrollController();

  /// 只有最靠左、完整可见的那张卡片播放视频，其余显示首帧：同一行最多一个 WebView，
  /// 横滑与整页滚动都不会被多路视频拖慢。
  int _lead = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateLead);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _updateLead() {
    final lead = (_scroll.offset / (widget.cardWidth + _kGap)).round().clamp(
      0,
      widget.shelf.entries.length - 1,
    );
    if (lead != _lead) setState(() => _lead = lead);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardHeight = widget.cardWidth / widget.aspectRatio;
    // 页面被压住（TickerMode 关闭）时不播放。
    final visible = TickerMode.valuesOf(context).enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: widget.padding.copyWith(top: 8, bottom: 8),
          child: Text(
            widget.shelf.title.isNotEmpty
                ? widget.shelf.title
                : widget.fallbackTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        SizedBox(
          height: cardHeight,
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: widget.shelf.entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: _kGap),
            itemBuilder: (context, i) => WatchFeedEntryCard(
              entry: widget.shelf.entries[i],
              width: widget.cardWidth,
              height: cardHeight,
              playing: visible && i == _lead,
            ),
          ),
        ),
      ],
    );
  }
}

/// 一张入口卡片。
class WatchFeedEntryCard extends StatelessWidget {
  const WatchFeedEntryCard({
    super.key,
    required this.entry,
    required this.width,
    required this.height,
    this.playing = false,
  });

  final WatchFeedEntry entry;
  final double width;
  final double height;

  /// 是否播放视频（否则只显示首帧）。
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    const subdued = TextStyle(color: Colors.white70);
    return Semantics(
      button: true,
      label: entry.accessibilityText.isNotEmpty
          ? entry.accessibilityText
          : entry.title,
      excludeSemantics: true,
      child: Material(
        color: const Color(0xFF282828),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('watch-feed-entry-${entry.feedUri}'),
          onTap: () => AppRoutes.openWatchFeed(
            context,
            entry.feedUri,
            title: entry.title,
          ),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LoopingVideo(
                  videoUrl: entry.videoUrl,
                  posterUrl: entry.imageUrl,
                  active: playing,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0x66000000),
                      ],
                      stops: [0, 0.4, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.overline.isNotEmpty)
                        Text(
                          entry.overline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.merge(subdued),
                        ),
                      Text(
                        entry.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          shadows: const [
                            Shadow(color: Colors.black45, blurRadius: 6),
                          ],
                        ),
                      ),
                      if (entry.subtitle.isNotEmpty)
                        Text(
                          entry.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.merge(subdued),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
