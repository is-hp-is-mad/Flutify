import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/utils/artwork_palette.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/artist.dart';
import '../../../../models/share_target.dart';
import '../../../../models/track.dart';
import '../../../../models/watch_feed.dart';
import '../../../../providers/library_provider.dart';
import '../../../../services/watchfeed/preview_player.dart';
import '../../../navigation/app_routes.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/looping_video.dart';
import '../../../widgets/share/share_button.dart';
import '../../../widgets/track_menu.dart';
import 'feed_animations.dart';

/// 深色画面上图标与文字的统一投影。
const List<Shadow> _kShadows = [
  Shadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 1)),
];

/// 发现流的一张卡片（对齐官方 WatchFeedTwoColumnsLayout）。
///
/// 由后往前：画面层（Canvas 视频 / 专辑封面卡 + 取色底 + 波形）→ 手势层（轻点暂停、双击保存、
/// 长按隐藏界面）→ 暂停图标 / 保存彩纸 → 底部主列（艺人行、#标签行、曲目行）+ 右侧操作列
/// （分享、更多、保存）→ 进度条。叠加组件在卡片成为当前页时按 200ms 间隔依次上浮淡入。
class WatchFeedItemCard extends StatefulWidget {
  const WatchFeedItemCard({
    super.key,
    required this.item,
    required this.active,
    this.foreground = true,
    required this.player,
    required this.onTogglePlay,
    required this.onPlayFull,
    required this.onOpenHashtag,
  });

  final WatchFeedItem item;

  /// 是否为当前可见、正在试听的卡片。
  final bool active;

  /// App 是否在前台（后台时不保留视频）。
  final bool foreground;

  final WatchFeedPreviewPlayer player;

  /// 轻点画面：暂停 / 继续试听。
  final VoidCallback onTogglePlay;

  /// 点曲目行：进入所在专辑并定位到这首歌（拿不到专辑时播放完整歌曲）。
  final ValueChanged<SpotifyTrack> onPlayFull;

  /// 点 #标签：进入该标签的 feed。
  final ValueChanged<WatchFeedHashtag> onOpenHashtag;

  @override
  State<WatchFeedItemCard> createState() => _WatchFeedItemCardState();
}

class _WatchFeedItemCardState extends State<WatchFeedItemCard> {
  /// 长按期间隐藏界面、放大封面（官方 ui_hide）。
  bool _uiHidden = false;

  /// 正在播放的保存彩纸。
  final List<Key> _bursts = [];
  int _burstSeed = 0;

  /// 双击：未保存则保存（已保存不取消），并在中心播放彩纸。
  void _onDoubleTap() {
    final track = widget.item.playableTrack;
    final library = context.read<LibraryProvider?>();
    if (track != null && library != null && !library.isLiked(track.id)) {
      library.toggleLike(track);
    }
    setState(() => _bursts.add(ValueKey(_burstSeed++)));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final active = widget.active;
    // 暂停态：本卡片是当前页、片段已加载且未在播放。
    final paused =
        active &&
        context.select<WatchFeedPreviewPlayer, bool>(
          (p) => p.currentUrl != null && !p.isLoading && !p.isPlaying,
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _FeedVisualLayer(
            visual: item.visual,
            // 只有当前卡片创建视频：相邻（露出的下一张）只画首帧，同屏最多一个 WebView。
            videoActive: active && widget.foreground,
            playing: active && !paused,
            enlarged: _uiHidden,
          ),
          Positioned.fill(
            child: GestureDetector(
              key: const Key('watch-feed-gesture-layer'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTogglePlay,
              onDoubleTap: _onDoubleTap,
              onLongPressStart: (_) => setState(() => _uiHidden = true),
              onLongPressEnd: (_) => setState(() => _uiHidden = false),
              onLongPressCancel: () => setState(() => _uiHidden = false),
            ),
          ),
          if (paused)
            IgnorePointer(
              child: Center(
                child: Semantics(
                  label: context.l10n.watchFeedPaused,
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 84,
                    color: Colors.white.withValues(alpha: 0.85),
                    shadows: _kShadows,
                  ),
                ),
              ),
            ),
          for (final key in _bursts)
            Center(
              child: FeedSaveBurst(
                key: key,
                onDone: () {
                  if (mounted) setState(() => _bursts.remove(key));
                },
              ),
            ),
          // 界面层：长按时 300ms 淡出（官方 ui_hide）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: _uiHidden,
              child: AnimatedOpacity(
                opacity: _uiHidden ? 0 : 1,
                duration: const Duration(milliseconds: 300),
                child: _buildOverlays(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverlays(BuildContext context) {
    final item = widget.item;
    final track = item.playableTrack;
    final main = <Widget>[
      if (item.creator != null) _CreatorRow(creator: item.creator!),
      for (final text in item.texts)
        Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.white,
            shadows: _kShadows,
          ),
        ),
      if (item.hashtags.isNotEmpty)
        _HashtagRow(hashtags: item.hashtags, onOpen: widget.onOpenHashtag),
      if (item.entityRow != null && track != null)
        _EntityRow(
          row: item.entityRow!,
          track: track,
          showSave: item.canSave,
          onPlay: () => widget.onPlayFull(track),
        ),
    ];
    final actions = <Widget>[
      if (item.canShare && track != null) _ShareAction(track: track),
      if (item.hasMenu && track != null) _MenuAction(track: track),
      if (item.canSave && track != null) _SaveButton(track: track, size: 30),
    ];
    var index = 0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < main.length; i++) ...[
                          if (i > 0) const SizedBox(height: 12),
                          _Entrance(
                            index: index++,
                            active: widget.active,
                            child: main[i],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final action in actions)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _Entrance(
                              index: index++,
                              active: widget.active,
                              child: action,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (item.hasProgressBar)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _PreviewProgressBar(
                  player: widget.player,
                  active: widget.active,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 画面层
// -----------------------------------------------------------------------------

/// 官方 Canvas 叠加渐变：顶部微暗、中段透明、底部加深（承托文字）。
const LinearGradient _kVideoScrim = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Color(0x36000000),
    Color(0x00000000),
    Color(0x00000000),
    Color(0x29000000),
    Color(0x99000000),
  ],
  stops: [0, 0.2, 0.56, 0.75, 1],
);

class _FeedVisualLayer extends StatelessWidget {
  const _FeedVisualLayer({
    required this.visual,
    required this.videoActive,
    required this.playing,
    required this.enlarged,
  });

  final WatchFeedVisual visual;
  final bool videoActive;
  final bool playing;

  /// 长按隐藏界面时封面卡放大（边距 70 → 12）。
  final bool enlarged;

  @override
  Widget build(BuildContext context) {
    switch (visual.kind) {
      case WatchFeedVisualKind.canvas:
      case WatchFeedVisualKind.image:
        return Stack(
          fit: StackFit.expand,
          children: [
            if (visual.kind == WatchFeedVisualKind.canvas)
              LoopingVideo(
                videoUrl: visual.videoUrl,
                posterUrl: visual.imageUrl,
                active: videoActive,
                playing: playing,
              )
            else
              CoverImage(url: visual.imageUrl),
            const DecoratedBox(
              decoration: BoxDecoration(gradient: _kVideoScrim),
            ),
          ],
        );
      case WatchFeedVisualKind.gradient:
        final colors = [for (final c in visual.colors) ?_parseColor(c)];
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: colors.length >= 2
                  ? colors
                  : const [Color(0xFF3A3A3A), Color(0xFF121212)],
            ),
          ),
        );
      case WatchFeedVisualKind.trackPreview:
        return _TrackPreviewVisual(
          visual: visual,
          playing: playing,
          enlarged: enlarged,
        );
    }
  }

  static Color? _parseColor(String value) {
    var hex = value.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    final parsed = int.tryParse(hex, radix: 16);
    return hex.length == 8 && parsed != null ? Color(parsed) : null;
  }
}

/// 无视频条目：整卡填封面取色 → 20% 黑色压暗 → 全宽波形（仅播放时动）→ 正方形封面卡
/// （圆角 8、阴影 16，左右边距 70，长按时以弹簧动画放大到 12）。
class _TrackPreviewVisual extends StatelessWidget {
  const _TrackPreviewVisual({
    required this.visual,
    required this.playing,
    required this.enlarged,
  });

  final WatchFeedVisual visual;
  final bool playing;
  final bool enlarged;

  @override
  Widget build(BuildContext context) {
    return ArtworkColorBuilder(
      imageUrl: visual.imageUrl,
      fallback: const Color(0xFF2A2A2A),
      builder: (context, color) => AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        color: color,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0x33000000)),
            Align(
              alignment: const Alignment(0, -0.25),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (visual.animationUrl.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: FeedWaveform(playing: playing),
                    ),
                  AnimatedPadding(
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOutBack,
                    padding: EdgeInsets.symmetric(
                      horizontal: enlarged ? 12 : 70,
                    ),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 16,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: CoverImage(
                          url: visual.imageUrl,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 叠加组件
// -----------------------------------------------------------------------------

/// 官方入场：卡片成为当前页时，第 [index] 个组件延迟 200ms × index，400ms 内
/// 从下方 8dp 上浮并淡入（Cubic(0.3, 0, 0.4, 1)）；离开当前页时复位。
class _Entrance extends StatefulWidget {
  const _Entrance({
    required this.index,
    required this.active,
    required this.child,
  });

  final int index;
  final bool active;
  final Widget child;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: kFeedEase,
  );
  int _run = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(covariant _Entrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _start();
    if (!widget.active && oldWidget.active) {
      _run++;
      _controller.value = 0;
    }
  }

  Future<void> _start() async {
    final run = ++_run;
    _controller.value = 0;
    // 系统减弱动效：直接显示。
    if (WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations) {
      _controller.value = 1;
      return;
    }
    await Future<void>.delayed(Duration(milliseconds: 200 * widget.index));
    if (!mounted || run != _run) return;
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 8dp 上浮：以子组件高度为单位换算不出固定 8dp，这里用 Transform 的像素偏移，
  /// 但通过 FadeTransition + AnimatedBuilder 只重绘、不重建子树。
  @override
  Widget build(BuildContext context) {
    final child = RepaintBoundary(child: widget.child);
    return FadeTransition(
      opacity: _curve,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 8 * (1 - _curve.value)),
          child: child,
        ),
        child: child,
      ),
    );
  }
}

/// 艺人行：头像 + 名字 / 粉丝数 + 关注按钮；点头像或名字进入艺人页。
class _CreatorRow extends StatelessWidget {
  const _CreatorRow({required this.creator});

  final WatchFeedCreator creator;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final artist = SpotifyArtist(
      id: creator.artistId,
      name: creator.name,
      uri: creator.uri,
    );
    final following = context.select<LibraryProvider?, bool>(
      (l) => l?.isFollowing(creator.artistId) ?? false,
    );
    return Row(
      children: [
        Flexible(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: creator.uri.startsWith('spotify:artist:')
                ? () => AppRoutes.openArtist(context, artist)
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CoverImage(url: creator.imageUrl, size: 32, circular: true),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        creator.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          shadows: _kShadows,
                        ),
                      ),
                      if (creator.subtitle.isNotEmpty)
                        Text(
                          creator.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                            shadows: _kShadows,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (creator.followUri.isNotEmpty &&
            creator.followText.isNotEmpty &&
            context.read<LibraryProvider?>() != null) ...[
          const SizedBox(width: 12),
          OutlinedButton(
            key: const Key('watch-feed-follow'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(
                color: Colors.white.withValues(alpha: following ? 0.4 : 0.9),
              ),
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              visualDensity: VisualDensity.compact,
              textStyle: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: () =>
                context.read<LibraryProvider>().toggleFollowArtist(artist),
            child: Text(
              following && creator.followingText.isNotEmpty
                  ? creator.followingText
                  : creator.followText,
            ),
          ),
        ],
      ],
    );
  }
}

/// #标签行：横滑、无底色、加粗白字，间距 16（官方 HashtagRow）。
class _HashtagRow extends StatelessWidget {
  const _HashtagRow({required this.hashtags, required this.onOpen});

  final List<WatchFeedHashtag> hashtags;
  final ValueChanged<WatchFeedHashtag> onOpen;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w700,
      shadows: _kShadows,
    );
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: hashtags.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (context, i) {
          final tag = hashtags[i];
          return InkWell(
            key: ValueKey('watch-feed-hashtag-${tag.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => onOpen(tag),
            child: Center(child: Text(tag.title, style: style)),
          );
        },
      ),
    );
  }
}

/// 曲目行：半透明圆角盒（16）里放 56dp 封面 + 歌名 / 艺人 + 保存；点整行进入所在专辑并定位到这首。
class _EntityRow extends StatelessWidget {
  const _EntityRow({
    required this.row,
    required this.track,
    required this.showSave,
    required this.onPlay,
  });

  final WatchFeedEntityRow row;
  final SpotifyTrack track;
  final bool showSave;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      // 服务端无障碍文案是「Play song: …」，与现在的行为（打开专辑）不符，改读歌名与艺人。
      label: [row.title, row.subtitle].where((t) => t.isNotEmpty).join(', '),
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('watch-feed-entity-row'),
          onTap: onPlay,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                CoverImage(
                  url: row.imageUrl.isNotEmpty ? row.imageUrl : track.coverUrl,
                  size: 56,
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (row.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          row.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (showSave) _SaveButton(track: track, size: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 保存按钮：未保存为「+」圈、已保存为绿色「✓」圈，切换时缩放弹出（官方 save_now 动画）。
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.track, required this.size});

  final SpotifyTrack track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final saved = context.select<LibraryProvider?, bool>(
      (l) => l?.isLiked(track.id) ?? false,
    );
    final library = context.read<LibraryProvider?>();
    return IconButton(
      key: const Key('watch-feed-save'),
      tooltip: saved ? l10n.likeRemove : l10n.likeAdd,
      onPressed: library == null ? null : () => library.toggleLike(track),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, animation) => ScaleTransition(
          scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
          child: child,
        ),
        child: Icon(
          saved ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
          key: ValueKey(saved),
          size: size,
          color: saved ? const Color(0xFF1ED760) : Colors.white,
          shadows: _kShadows,
        ),
      ),
    );
  }
}

class _ShareAction extends StatelessWidget {
  const _ShareAction({required this.track});

  final SpotifyTrack track;

  @override
  Widget build(BuildContext context) => IconTheme(
    data: const IconThemeData(
      color: Colors.white,
      size: 26,
      shadows: _kShadows,
    ),
    child: ShareButton(target: ShareTarget.track(track)),
  );
}

class _MenuAction extends StatelessWidget {
  const _MenuAction({required this.track});

  final SpotifyTrack track;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('watch-feed-more'),
    tooltip: context.l10n.commonMoreOptions,
    icon: const Icon(
      Icons.more_horiz_rounded,
      size: 28,
      color: Colors.white,
      shadows: _kShadows,
    ),
    onPressed: () => TrackMenu.show(context, track),
  );
}

/// 试听进度条：32dp 触控区里一条 2dp 细线；横向拖动时加粗并在松手时 seek。
class _PreviewProgressBar extends StatefulWidget {
  const _PreviewProgressBar({required this.player, required this.active});

  final WatchFeedPreviewPlayer player;
  final bool active;

  @override
  State<_PreviewProgressBar> createState() => _PreviewProgressBarState();
}

class _PreviewProgressBarState extends State<_PreviewProgressBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.active
        ? context.select<WatchFeedPreviewPlayer, int>(
            (p) => p.duration.inMilliseconds,
          )
        : 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double fractionAt(double dx) =>
            width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);
        return GestureDetector(
          key: const Key('watch-feed-progress'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: durationMs <= 0
              ? null
              : (d) => setState(() => _drag = fractionAt(d.localPosition.dx)),
          onHorizontalDragUpdate: durationMs <= 0
              ? null
              : (d) => setState(() => _drag = fractionAt(d.localPosition.dx)),
          onHorizontalDragEnd: durationMs <= 0
              ? null
              : (_) {
                  final f = _drag;
                  setState(() => _drag = null);
                  if (f != null) {
                    widget.player.seek(
                      Duration(milliseconds: (durationMs * f).round()),
                    );
                  }
                },
          onHorizontalDragCancel: () => setState(() => _drag = null),
          child: SizedBox(
            height: 32,
            child: RepaintBoundary(
              child: ValueListenableBuilder<Duration>(
                valueListenable: widget.player.position,
                builder: (context, position, _) {
                  final dragging = _drag != null;
                  final fraction = durationMs <= 0
                      ? 0.0
                      : _drag ??
                            (position.inMilliseconds / durationMs).clamp(
                              0.0,
                              1.0,
                            );
                  return Align(
                    alignment: Alignment.center,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      height: dragging ? 4 : 2,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: fraction,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
