import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/utils/formatters.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/artist.dart';
import '../../../../models/track.dart';
import '../../../../models/watch_feed.dart';
import '../../../../providers/library_provider.dart';
import '../../../../services/watchfeed/preview_player.dart';
import '../../../widgets/cover_image.dart';
import 'desktop_watch_feed_source.dart';

/// 左栏：feed 标题（上）→ 曲目块（中：大号歌名、艺人、专辑封面 + 进度）→ 艺人行与 #标签（下）。
class DesktopWatchFeedLeftColumn extends StatelessWidget {
  const DesktopWatchFeedLeftColumn({
    super.key,
    required this.title,
    required this.item,
    required this.size,
    required this.direction,
    required this.player,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenHashtag,
  });

  final String title;
  final WatchFeedItem item;
  final DesktopWatchFeedSize size;
  final int direction;
  final WatchFeedPreviewPlayer player;
  final ValueChanged<SpotifyTrack> onOpenAlbum;
  final ValueChanged<SpotifyArtist> onOpenArtist;
  final ValueChanged<WatchFeedHashtag> onOpenHashtag;

  @override
  Widget build(BuildContext context) {
    final track = item.playableTrack;
    final large = size == DesktopWatchFeedSize.large;
    final titleSize = switch (size) {
      DesktopWatchFeedSize.small => 20.0,
      DesktopWatchFeedSize.medium => 24.0,
      DesktopWatchFeedSize.large => 32.0,
    };
    final gap = size == DesktopWatchFeedSize.small ? 8.0 : 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: large ? 18 : 16,
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(start: large ? 64 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _DirectionalSwitcher(
                direction: direction,
                child: _Link(
                  key: ValueKey('title-${item.id}'),
                  onTap: track?.album == null
                      ? null
                      : () => onOpenAlbum(track!),
                  child: Text(
                    track?.name ?? item.entityRow?.title ?? '',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: titleSize,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              SizedBox(height: gap / 2),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _Artists(
                  key: ValueKey('artists-${item.id}'),
                  track: track,
                  fallback: item.entityRow?.subtitle ?? '',
                  onOpenArtist: onOpenArtist,
                ),
              ),
              _AlbumProgressRow(
                item: item,
                track: track,
                player: player,
                onOpenAlbum: onOpenAlbum,
              ),
            ],
          ),
        ),
        _CreatorSection(
          item: item,
          gap: gap,
          onOpenArtist: onOpenArtist,
          onOpenHashtag: onOpenHashtag,
        ),
      ],
    );
  }
}

/// 歌名切换动画：按翻页方向从下 / 上方 50% 处滑入并淡入，0.2s，延迟 0.1s。
class _DirectionalSwitcher extends StatelessWidget {
  const _DirectionalSwitcher({required this.direction, required this.child});

  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: const Interval(1 / 3, 1, curve: Curves.easeInOut),
      switchOutCurve: Curves.easeInOut,
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.bottomStart,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        final incoming = child.key == this.child.key;
        final from = Offset(0, 0.5 * direction * (incoming ? 1 : -1));
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: from, end: Offset.zero).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// 可点击的文字 / 图片：悬停显示手形光标并加下划线（文字）。
class _Link extends StatefulWidget {
  const _Link({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) return widget.child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: DefaultTextStyle.merge(
          style: TextStyle(
            decoration: _hover ? TextDecoration.underline : TextDecoration.none,
            decorationColor: Colors.white70,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _Artists extends StatelessWidget {
  const _Artists({
    super.key,
    required this.track,
    required this.fallback,
    required this.onOpenArtist,
  });

  final SpotifyTrack? track;
  final String fallback;
  final ValueChanged<SpotifyArtist> onOpenArtist;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Color(0xFFB3B3B3), fontSize: 15);
    final artists = track?.artists ?? const <SpotifyArtist>[];
    return Row(
      children: [
        if (track?.explicit ?? false)
          Container(
            margin: const EdgeInsetsDirectional.only(end: 4),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFB3B3B3),
              borderRadius: BorderRadius.circular(2),
            ),
            child: const Text(
              'E',
              style: TextStyle(
                color: Colors.black,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Flexible(
          child: artists.isEmpty
              ? Text(fallback, style: style, maxLines: 1)
              : Wrap(
                  children: [
                    for (var i = 0; i < artists.length; i++) ...[
                      _Link(
                        onTap: () => onOpenArtist(artists[i]),
                        child: Text(artists[i].name, style: style),
                      ),
                      if (i < artists.length - 1)
                        const Text(', ', style: style),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// 专辑封面（54×54，只在有 Canvas 时显示——没有时卡片本身就是封面）+ 4px 白色进度条；
/// 整行高 70、顶部留 16、最宽 318，间距 24。点封面进入专辑并定位到这首。
class _AlbumProgressRow extends StatelessWidget {
  const _AlbumProgressRow({
    required this.item,
    required this.track,
    required this.player,
    required this.onOpenAlbum,
  });

  final WatchFeedItem item;
  final SpotifyTrack? track;
  final WatchFeedPreviewPlayer player;
  final ValueChanged<SpotifyTrack> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final track = this.track;
    final cover = track?.coverUrl ?? '';
    final showCover =
        track != null &&
        item.visual.kind == WatchFeedVisualKind.canvas &&
        cover.isNotEmpty;
    final durationMs = context.select<WatchFeedPreviewPlayer, int>(
      (p) => p.duration.inMilliseconds,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 318),
      child: SizedBox(
        height: 70,
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(
            children: [
              if (showCover) ...[
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _Link(
                    key: ValueKey('cover-${item.id}'),
                    onTap: () => onOpenAlbum(track),
                    child: CoverImage(
                      url: cover,
                      size: 54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(width: 24),
              ],
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0x4DFFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: ValueListenableBuilder<Duration>(
                    valueListenable: player.position,
                    builder: (context, position, _) {
                      // 时长未知时官方按 30 秒算。
                      final total = durationMs > 0 ? durationMs : 30000;
                      final f = (position.inMilliseconds / total).clamp(
                        0.0,
                        1.0,
                      );
                      return FractionallySizedBox(
                        alignment: AlignmentDirectional.centerStart,
                        widthFactor: f,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 左栏底部：艺人行（32 头像、名字、• 月度听众、关注）+ 一行 #标签胶囊（超出一行的隐藏）。
class _CreatorSection extends StatelessWidget {
  const _CreatorSection({
    required this.item,
    required this.gap,
    required this.onOpenArtist,
    required this.onOpenHashtag,
  });

  final WatchFeedItem item;
  final double gap;
  final ValueChanged<SpotifyArtist> onOpenArtist;
  final ValueChanged<WatchFeedHashtag> onOpenHashtag;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final creator = item.creator;
    const subdued = TextStyle(color: Color(0xFFB3B3B3), fontSize: 13);
    final artist = creator == null
        ? null
        : SpotifyArtist(
            id: creator.artistId,
            name: creator.name,
            uri: creator.uri,
          );
    final following = context.select<LibraryProvider?, bool>(
      (l) => creator != null && (l?.isFollowing(creator.artistId) ?? false),
    );
    final listeners = creator?.monthlyListeners;
    final stat = listeners != null
        ? l10n.watchFeedMonthlyListeners(
            Formatters.formatCompactNumber(l10n, listeners),
          )
        : creator?.subtitle ?? '';
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 80),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (creator != null && artist != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Row(
                key: ValueKey('creator-${creator.uri}'),
                children: [
                  _Link(
                    onTap: () => onOpenArtist(artist),
                    child: CoverImage(
                      url: creator.imageUrl,
                      size: 32,
                      circular: true,
                      placeholderIcon: Icons.person_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: _Link(
                      onTap: () => onOpenArtist(artist),
                      child: Text(
                        creator.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subdued.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                  if (stat.isNotEmpty)
                    Flexible(
                      child: Text(
                        ' • $stat',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subdued,
                      ),
                    ),
                  if (context.read<LibraryProvider?>() != null) ...[
                    const SizedBox(width: 12),
                    OutlinedButton(
                      key: const Key('desktop-watch-feed-follow'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(
                            alpha: following ? 0.3 : 0.7,
                          ),
                        ),
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact,
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      onPressed: () => context
                          .read<LibraryProvider>()
                          .toggleFollowArtist(artist),
                      child: Text(
                        following ? l10n.artistFollowing : l10n.artistFollow,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (item.hashtags.isNotEmpty) ...[
            SizedBox(height: gap),
            // 只显示一行，放不下的隐藏（官方 height:32 + overflow:hidden）。
            SizedBox(
              height: 32,
              child: ClipRect(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in item.hashtags)
                      _HashtagChip(tag: tag, onTap: () => onOpenHashtag(tag)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// #标签胶囊（Encore Chip）：高 32、圆角 16、底色白 10%，悬停加亮。
class _HashtagChip extends StatefulWidget {
  const _HashtagChip({required this.tag, required this.onTap});

  final WatchFeedHashtag tag;
  final VoidCallback onTap;

  @override
  State<_HashtagChip> createState() => _HashtagChipState();
}

class _HashtagChipState extends State<_HashtagChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: ValueKey('desktop-watch-feed-hashtag-${widget.tag.id}'),
        onTap: widget.onTap,
        // 不能给 Container 设 alignment：那会让它撑满父级的最大宽度（每个胶囊占一整行）。
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Color(_hover ? 0x33FFFFFF : 0x1AFFFFFF),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              widget.tag.title,
              maxLines: 1,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
