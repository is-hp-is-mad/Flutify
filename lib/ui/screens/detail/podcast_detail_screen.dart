import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playback_context.dart';
import '../../../models/podcast.dart';
import '../../../models/track.dart';
import '../../../providers/playback_provider.dart';
import '../../../services/spotify_api_service.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/hover_builder.dart';
import 'widgets/collection_hero.dart';
import 'widgets/collection_widgets.dart';

/// 播客节目详情页：封面 + 出版方 + 简介 + 最新单集列表。
///
/// 数据来自 open.spotify.com 节目页（[SpotifyApiService.getPodcastShow]），无需登录即可加载；
/// 单集点击即播放（协议链路，见 TrackAudioLoader 的单集分支）。
class PodcastDetailScreen extends StatefulWidget {
  /// 节目 id（`spotify:show:xxx` 中的 xxx）。
  final String showId;

  /// 卡片带来的节目标题 / 封面（加载完成前先展示）。
  final String initialTitle;
  final String initialCover;

  const PodcastDetailScreen({
    super.key,
    required this.showId,
    this.initialTitle = '',
    this.initialCover = '',
  });

  @override
  State<PodcastDetailScreen> createState() => _PodcastDetailScreenState();
}

class _PodcastDetailScreenState extends State<PodcastDetailScreen> {
  PodcastShow? _show;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _error = null);
    try {
      final show = await context.read<SpotifyApiService>().getPodcastShow(
        widget.showId,
      );
      if (mounted) setState(() => _show = show);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final show = _show;
    final title = show?.name ?? widget.initialTitle;
    final cover = show?.coverUrl ?? widget.initialCover;
    final episodes = show?.episodes ?? const <PodcastEpisode>[];
    final tracks = [for (final e in episodes) e.toTrack()];
    final playbackContext = PlaybackContext.collection(
      title,
      uri: show?.uri ?? 'spotify:show:${widget.showId}',
    );

    return Scaffold(
      body: CollectionTintScope(
        imageUrl: cover,
        fallback: const Color(0xFF3A3A48),
        child: CustomScrollView(
          slivers: [
            CollectionHero(
              typeLabel: l10n.typePodcast,
              title: title,
              imageUrl: cover,
              meta: _PodcastMeta(show: show),
              collapsedAction: ContextPlayButton(
                tracks: tracks,
                playbackContext: playbackContext,
                size: 44,
                elevated: false,
              ),
            ),
            SliverToBoxAdapter(
              child: CollectionHeroFade(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: CollectionActionRow(
                    tracks: tracks,
                    playbackContext: playbackContext,
                    leading: const [],
                  ),
                ),
              ),
            ),
            if (show == null && _error == null)
              const CollectionPlaceholder(loading: true)
            else if (_error != null)
              CollectionErrorPlaceholder(signedOut: false, onRetry: _fetch)
            else if (episodes.isEmpty)
              CollectionPlaceholder(
                message: l10n.podcastEmpty,
                icon: Icons.podcasts_rounded,
              )
            else
              SliverList.builder(
                itemCount: episodes.length,
                itemBuilder: (context, index) => _EpisodeTile(
                  episode: episodes[index],
                  queue: tracks,
                  playbackContext: playbackContext,
                ),
              ),
            const ContentBottomSpacer(),
          ],
        ),
      ),
    );
  }
}

/// 头部元信息：出版方 · 集数 + 简介（一行）。
class _PodcastMeta extends StatelessWidget {
  final PodcastShow? show;

  const _PodcastMeta({required this.show});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final show = this.show;
    if (show == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (show.description.isNotEmpty) ...[
          Text(
            show.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: context.tokens.accent,
              child: Icon(
                Icons.podcasts_rounded,
                color: context.tokens.onAccent,
                size: 14,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                show.publisher,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (show.episodes.isNotEmpty)
              Flexible(
                child: Text(
                  ' · ${l10n.podcastEpisodeCount(show.episodes.length)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 单集行：封面（叠播放态）+ 标题 + 简介 + 「日期 · 时长 · 播放进度」。
class _EpisodeTile extends StatelessWidget {
  final PodcastEpisode episode;
  final List<SpotifyTrack> queue;
  final PlaybackContext playbackContext;

  const _EpisodeTile({
    required this.episode,
    required this.queue,
    required this.playbackContext,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    // 当前播放态（按 uri 匹配，单集与曲目不会撞 id）
    final (isCurrent, isPlaying) = context
        .select<PlaybackProvider, (bool, bool)>(
          (p) => (
            p.currentTrack?.uri == episode.uri,
            p.currentTrack?.uri == episode.uri && p.isPlaying,
          ),
        );

    // 元信息行：日期 · 时长（· 播至 mm:ss / 已播完）
    final parts = <String>[
      if (episode.releaseDate.isNotEmpty)
        Formatters.formatReleaseDate(
          l10n,
          episode.releaseDate.split('T').first,
        ),
      if (episode.durationMs > 0)
        Formatters.formatDurationMs(episode.durationMs),
      if (episode.played)
        l10n.podcastPlayed
      else if (episode.resumeMs > 0)
        l10n.podcastResumeFrom(Formatters.formatDurationMs(episode.resumeMs)),
    ];

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: () => _play(context),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: context.motion(const Duration(milliseconds: 150)),
          color: hovered
              ? colorScheme.surfaceContainerHighest.withAlpha(120)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(episode: episode, playing: isPlaying, hovered: hovered),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      episode.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isCurrent ? context.tokens.accent : null,
                      ),
                    ),
                    if (episode.description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        episode.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          episode.played
                              ? Icons.check_circle_rounded
                              : Icons.play_circle_outline_rounded,
                          size: 16,
                          color: episode.played
                              ? context.tokens.accent
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            parts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // 续播进度条
                    if (!episode.played &&
                        episode.resumeMs > 0 &&
                        episode.durationMs > 0) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: (episode.resumeMs / episode.durationMs).clamp(
                            0.0,
                            1.0,
                          ),
                          minHeight: 3,
                          backgroundColor: colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation(
                            context.tokens.accent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _play(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    if (playback.currentTrack?.uri == episode.uri) {
      playback.togglePlayPause();
    } else {
      playback.playTrack(
        episode.toTrack(),
        contextQueue: queue,
        context: playbackContext,
      );
    }
  }
}

/// 单集封面：悬停 / 播放中时叠加播放图标。
class _Cover extends StatelessWidget {
  final PodcastEpisode episode;
  final bool playing;
  final bool hovered;

  const _Cover({
    required this.episode,
    required this.playing,
    required this.hovered,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (episode.coverUrl.isNotEmpty)
              // 播客封面常是 3000px 级原图，56px 的小图按显示尺寸解码，避免每张占几十 MB
              Image.network(
                episode.coverUrl,
                fit: BoxFit.cover,
                cacheWidth:
                    (56 * MediaQuery.devicePixelRatioOf(context) * 1.5 / 64)
                        .ceil() *
                    64,
              )
            else
              ColoredBox(
                color: colorScheme.surfaceContainerHigh,
                child: Icon(
                  Icons.podcasts_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            if (hovered || playing)
              ColoredBox(
                color: Colors.black.withAlpha(90),
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
