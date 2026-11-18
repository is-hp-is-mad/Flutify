import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/md3e_theme.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/artist.dart';
import '../../../../models/track.dart';
import '../../../../models/watch_feed.dart';
import '../../../../providers/appearance_provider.dart';
import '../../../../providers/library_provider.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../services/media_controls/media_controls_sync.dart';
import '../../../../services/media_controls/system_media_controls.dart';
import '../../../../services/spotify_api_service.dart';
import '../../../../services/taskbar_lyrics/taskbar_lyrics_controls.dart';
import '../../../../services/watchfeed/preview_player.dart';
import '../../../navigation/app_routes.dart';
import '../../../widgets/skeleton.dart';
import '../../../widgets/toast/app_toast.dart';
import '../watch_feed_shortcuts.dart';
import 'desktop_watch_feed_card.dart';
import 'desktop_watch_feed_left_column.dart';
import 'desktop_watch_feed_right_column.dart';
import 'desktop_watch_feed_source.dart';

/// 桌面版发现流（对齐 Spotify 桌面网页版 dwp-watch-feed-view-container，抓包见
/// docs/DISCOVERY_FEED_ANALYSIS.md「桌面版」一节）。
///
/// 与手机版完全不同：盖住整个窗口的模态层（90% 黑底），中间 16:10 的对话框分三栏——
/// 左栏是 feed 标题 / 大号歌名 / 艺人 / 专辑与进度 / 艺人行与 #标签；中栏是 9:16 卡片竖向轮播
/// （上下各露出一点邻居）；右栏是静音、关闭、更多 / 复制链接 / 加队列 / 保存，以及上一首 / 下一首。
/// 打开时暂停主播放，关闭时恢复（原本在播的话）；离开本层去专辑 / 艺人页会先关闭本层。
class DesktopWatchFeed extends StatefulWidget {
  const DesktopWatchFeed({
    super.key,
    required this.feedUri,
    required this.title,
    required this.opener,
    this.initialPage,
    this.player,
  });

  /// `spotify:watch-feed:{artist|album|playlist}:<id>`（实体，Pathfinder）或
  /// `spotify:watch-feed:discovery-feed:<id>`（#标签，spclient）。
  final String feedUri;
  final String title;

  /// 打开本层的页面 context：关闭本层后从它导航到专辑 / 艺人页。
  final BuildContext opener;

  /// 入口按钮已预取的第一页（实体 feed），避免重复请求。
  final WatchFeedEntityPage? initialPage;

  /// 测试注入；为 null 时自建并负责释放。
  final WatchFeedPreviewPlayer? player;

  /// 以模态层打开（根 Navigator、非不透明路由，背后整窗压暗）。
  static Future<void> open(
    BuildContext context, {
    required String feedUri,
    required String title,
    WatchFeedEntityPage? initialPage,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 180),
        reverseTransitionDuration: const Duration(milliseconds: 140),
        pageBuilder: (_, _, _) => DesktopWatchFeed(
          feedUri: feedUri,
          title: title,
          opener: context,
          initialPage: initialPage,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  State<DesktopWatchFeed> createState() => _DesktopWatchFeedState();
}

class _DesktopWatchFeedState extends State<DesktopWatchFeed> {
  late final WatchFeedPreviewPlayer _player =
      widget.player ?? WatchFeedPreviewPlayer();
  late final AppLifecycleListener _lifecycle;
  final FocusNode _focus = FocusNode(debugLabel: 'desktop-watch-feed');

  late String _title = widget.title;
  late DesktopWatchFeedSource _source;
  final List<WatchFeedItem> _items = [];
  int _index = 0;
  bool _loading = false;
  bool _failed = false;

  /// 竖向轮播：viewportFraction 取决于卡片与对话框高度之比，尺寸变化时重建。
  PageController? _pager;
  double _fraction = 0;

  /// 上一次滑动方向（标题切换动画用）：1 往下、-1 往上。
  int _direction = 1;

  /// 用户是否已经翻过页：之前显示会跳动的白色「下一首」胶囊，之后换成小箭头。
  bool _interacted = false;

  /// 打开时主播放器在播：关闭时恢复。
  bool _resumeOnClose = false;
  bool _wasPlayingBeforeHide = false;

  Duration? _lastWheel;
  PlaybackProvider? _playback;
  TaskbarLyricsControls? _taskbarLyrics;

  @override
  void initState() {
    super.initState();
    _source = _sourceFor(widget.feedUri, widget.initialPage);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _taskbarLyrics = context.read<TaskbarLyricsControls?>();
    _player.addListener(_syncTaskbarLyrics);
    MediaControlsSync.setWatchFeedHandler(this, _onMediaControlEvent);
    final playback = context.read<PlaybackProvider?>();
    _playback = playback;
    if (playback != null) {
      _resumeOnClose = playback.isPlaying;
      if (playback.isPlaying) playback.pause();
      _player.setBaseVolume(playback.volume);
      playback.addListener(_syncVolume);
    }
    _loadMore();
  }

  @override
  void dispose() {
    MediaControlsSync.setWatchFeedHandler(this, null);
    _player.removeListener(_syncTaskbarLyrics);
    _taskbarLyrics?.clearWatchFeedOverride();
    _playback?.removeListener(_syncVolume);
    _lifecycle.dispose();
    _focus.dispose();
    _pager?.dispose();
    if (widget.player == null) {
      _player.dispose();
    } else {
      _player.stop();
    }
    // 关闭（含去专辑 / 艺人页）后恢复打开前的主播放。
    final playback = _playback;
    if (_resumeOnClose && playback != null && !playback.isPlaying) {
      playback.togglePlayPause();
    }
    super.dispose();
  }

  DesktopWatchFeedSource _sourceFor(String uri, WatchFeedEntityPage? first) {
    final api = context.read<SpotifyApiService>();
    return uri.startsWith('spotify:watch-feed:discovery-feed')
        ? DiscoveryWatchFeedSource(api, uri)
        : EntityWatchFeedSource(api, uri, first);
  }

  void _syncVolume() {
    final playback = _playback;
    if (playback != null) _player.setBaseVolume(playback.volume);
  }

  void _onLifecycle(AppLifecycleState state) {
    final foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (!foreground) {
      _wasPlayingBeforeHide =
          _wasPlayingBeforeHide || _player.isPlaying || _player.isLoading;
      _player.pause();
    } else if (_wasPlayingBeforeHide) {
      _wasPlayingBeforeHide = false;
      _player.resume();
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_source.hasMore) return;
    final source = _source;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final items = await source.next();
      if (!mounted || !identical(source, _source)) return;
      final first = _items.isEmpty;
      setState(() {
        _items.addAll(items);
        _loading = false;
      });
      if (first) _playCurrent();
    } catch (e) {
      debugPrint('[watch-feed] 桌面版加载失败：$e');
      if (!mounted || !identical(source, _source)) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _playCurrent() {
    if (_items.isEmpty) return;
    final audio = _items[_index].audio;
    if (audio == null) {
      _player.stop();
    } else {
      _player.play(audio);
    }
    _syncTaskbarLyrics();
  }

  void _syncTaskbarLyrics() {
    final taskbar = _taskbarLyrics;
    if (taskbar == null || !mounted || _items.isEmpty) return;
    taskbar.setWatchFeedItem(
      _items[_index],
      badge: context.l10n.watchFeedBadge,
      muted: _player.muted,
      fallbackTitle: widget.title,
      onPrevious: _index > 0 ? () => _move(-1) : null,
      onToggleMute: () => _player.setMuted(!_player.muted),
      onNext: _index + 1 < _items.length ? () => _move(1) : null,
    );
  }

  void _onPageChanged(int index) {
    if (index == _index) return;
    setState(() {
      _direction = index > _index ? 1 : -1;
      _index = index;
      _interacted = true;
    });
    _playCurrent();
    // 官方：剩余不足 5 条时预加载下一页。
    if (index >= _items.length - 5) _loadMore();
  }

  void _move(int delta) {
    final target = _index + delta;
    final pager = _pager;
    if (target < 0 || target >= _items.length || pager == null) return;
    if (!pager.hasClients) return;
    final instant = MediaQuery.disableAnimationsOf(context);
    if (instant) {
      pager.jumpToPage(target);
    } else {
      pager.animateToPage(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _close() => Navigator.of(context).maybePop();

  /// 关闭本层再导航（官方：路径变化即关闭弹层）。
  void _navigate(void Function(BuildContext opener) go) {
    final opener = widget.opener;
    Navigator.of(context).pop();
    if (opener.mounted) go(opener);
  }

  /// 点 #标签：在本层里换成该标签的 feed。
  void _openHashtag(WatchFeedHashtag tag) {
    _player.stop();
    setState(() {
      _title = tag.title;
      _source = _sourceFor(tag.navigationUri, null);
      _items.clear();
      _index = 0;
      _direction = 1;
      _failed = false;
      _loading = false;
      _interacted = false;
      final old = _pager;
      _pager = null;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    });
    _loadMore();
  }

  bool _onMediaControlEvent(MediaControlEvent event) =>
      handleWatchFeedMediaButton(
        event,
        onPrevious: () => _move(-1),
        onNext: () => _move(1),
        isMuted: () => _player.muted,
        setMuted: _player.setMuted,
      );

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final mediaResult = handleWatchFeedMediaKey(
      context,
      event,
      onPrevious: () => _move(-1),
      onNext: () => _move(1),
      onToggleMute: () => _player.setMuted(!_player.muted),
    );
    if (mediaResult == KeyEventResult.handled) return mediaResult;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final item = _items.isEmpty ? null : _items[_index];
    if (key == LogicalKeyboardKey.escape) {
      _close();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (key == LogicalKeyboardKey.arrowLeft && item != null) {
      _toggleSave(item);
    } else if (key == LogicalKeyboardKey.arrowRight && item != null) {
      _addToQueue(item);
    } else if (key == LogicalKeyboardKey.keyM && event is KeyDownEvent) {
      _player.setMuted(!_player.muted);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// 鼠标滚轮：一次手势只翻一页（触控板的平移手势由 PageView 自己吸附）。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final scroll = resolved as PointerScrollEvent;
      final dy = scroll.scrollDelta.dy;
      if (dy == 0) return;
      final last = _lastWheel;
      if (last != null &&
          (scroll.timeStamp - last).abs() < const Duration(milliseconds: 450)) {
        return;
      }
      _lastWheel = scroll.timeStamp;
      _move(dy > 0 ? 1 : -1);
    });
  }

  void _toggleSave(WatchFeedItem item) {
    final track = item.playableTrack;
    final library = context.read<LibraryProvider?>();
    if (track == null || library == null) return;
    final wasSaved = library.isLiked(track.id);
    library.toggleLike(track);
    final l10n = context.l10n;
    AppToast.show(
      context,
      wasSaved ? l10n.toastLikeRemoved : l10n.toastLikeAdded,
      icon: wasSaved ? Icons.heart_broken_rounded : Icons.favorite_rounded,
      tone: ToastTone.success,
    );
  }

  void _addToQueue(WatchFeedItem item) {
    final track = item.playableTrack;
    if (track == null) return;
    context.read<PlaybackProvider?>()?.addToQueue(track);
    AppToast.show(
      context,
      context.l10n.toastAddedToQueue,
      icon: Icons.queue_music_rounded,
      tone: ToastTone.success,
    );
  }

  void _copyLink(WatchFeedItem item) {
    final track = item.playableTrack;
    if (track == null) return;
    Clipboard.setData(
      ClipboardData(text: 'https://open.spotify.com/track/${track.id}'),
    );
    AppToast.show(
      context,
      context.l10n.shareCopied,
      icon: Icons.link_rounded,
      tone: ToastTone.success,
    );
  }

  void _openAlbum(SpotifyTrack track) {
    final album = track.album;
    if (album == null || album.id.isEmpty) return;
    _navigate(
      (opener) => AppRoutes.openAlbum(opener, album, focusTrack: track),
    );
  }

  void _openArtist(SpotifyArtist artist) {
    if (artist.id.isEmpty) return;
    _navigate((opener) => AppRoutes.openArtist(opener, artist));
  }

  @override
  Widget build(BuildContext context) {
    final theme =
        context.watch<AppearanceProvider?>()?.theme(Brightness.dark) ??
        MD3ETheme.dark;
    return Theme(
      data: theme,
      child: ChangeNotifierProvider<WatchFeedPreviewPlayer>.value(
        value: _player,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Material(
            type: MaterialType.transparency,
            child: GestureDetector(
              // 点对话框外的暗区关闭。
              key: const Key('desktop-watch-feed-backdrop'),
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: ColoredBox(
                color: const Color(0x7A000000),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // width = min(85%, 1680, 85vh × 16/10)，比例 16:10。
                    final w = math.min(
                      constraints.maxWidth * 0.85,
                      math.min(1680.0, constraints.maxHeight * 0.85 * 1.6),
                    );
                    final h = w / 1.6;
                    return Center(
                      child: GestureDetector(
                        // 吞掉对话框内的点击，不让它冒到暗区关闭。
                        onTap: () {},
                        child: SizedBox(
                          width: w,
                          height: h,
                          child: _buildDialog(context, w, h),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDialog(BuildContext context, double w, double h) {
    final size = w < 778
        ? DesktopWatchFeedSize.small
        : w < 1102
        ? DesktopWatchFeedSize.medium
        : DesktopWatchFeedSize.large;
    final item = _items.isEmpty ? null : _items[_index];
    return DesktopWatchFeedDialogBackground(
      item: item,
      width: w,
      height: h,
      child: _items.isEmpty
          ? _buildPlaceholder(context, size, w, h)
          : _buildRow(context, size, w, h, item!),
    );
  }

  /// 三栏排布（按官方 CSS 计算）：右栏 86/128/160 宽，左栏与中栏各占剩余一半（间距 16），
  /// 轮播宽 41%、左右各留 5%，卡片 9:16。
  Widget _buildRow(
    BuildContext context,
    DesktopWatchFeedSize size,
    double w,
    double h,
    WatchFeedItem item,
  ) {
    final rightW = switch (size) {
      DesktopWatchFeedSize.small => 86.0,
      DesktopWatchFeedSize.medium => 128.0,
      DesktopWatchFeedSize.large => 160.0,
    };
    final pad = switch (size) {
      DesktopWatchFeedSize.small => 16.0,
      DesktopWatchFeedSize.medium => 24.0,
      DesktopWatchFeedSize.large => 32.0,
    };
    final leftW = (w - rightW - 32) / 2;
    final carouselLeft = leftW + 16 + 32;
    final carouselW = w * 0.41;
    final cardW = w * 0.31;
    final cardH = cardW * 16 / 9;
    final fraction = ((cardH + 15) / h).clamp(0.1, 1.0);
    if (_pager == null || (fraction - _fraction).abs() > 0.004) {
      final old = _pager;
      _fraction = fraction;
      _pager = PageController(viewportFraction: fraction, initialPage: _index);
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    }
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: leftW,
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: DesktopWatchFeedLeftColumn(
              title: _title,
              item: item,
              size: size,
              direction: _direction,
              player: _player,
              onOpenAlbum: _openAlbum,
              onOpenArtist: _openArtist,
              onOpenHashtag: _openHashtag,
            ),
          ),
        ),
        Positioned(
          left: carouselLeft,
          top: 0,
          bottom: 0,
          width: carouselW,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                key: ValueKey(_source),
                controller: _pager,
                scrollDirection: Axis.vertical,
                itemCount: _items.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, i) => Center(
                  child: SizedBox(
                    width: cardW,
                    height: cardH,
                    child: DesktopWatchFeedCard(
                      key: ValueKey(_items[i].id),
                      item: _items[i],
                      active: i == _index,
                      onTap: () => _move(i - _index),
                    ),
                  ),
                ),
              ),
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: _onPointerSignal,
              ),
            ],
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: rightW,
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: DesktopWatchFeedRightColumn(
              item: item,
              size: size,
              canPrevious: _index > 0,
              canNext: _index < _items.length - 1,
              interacted: _interacted,
              onClose: _close,
              onPrevious: () => _move(-1),
              onNext: () => _move(1),
              onToggleSave: () => _toggleSave(item),
              onAddToQueue: () => _addToQueue(item),
              onCopyLink: () => _copyLink(item),
            ),
          ),
        ),
        // 官方：首次翻页前的「下一首」是贴在对话框右下角的白色胶囊，宽度按文字自适应，
        // 不受右栏宽度限制（右栏最窄只有 54，放进去会把文字挤掉）。
        if (!_interacted && _index < _items.length - 1)
          Positioned(
            right: pad,
            bottom: pad,
            child: DesktopWatchFeedNextPill(
              label: context.l10n.playerNext,
              large: size != DesktopWatchFeedSize.small,
              onPressed: () => _move(1),
            ),
          ),
      ],
    );
  }

  /// 加载骨架 / 错误态：左栏几条闪烁文字块，中间三张 #333 卡片；右上角仍可关闭。
  Widget _buildPlaceholder(
    BuildContext context,
    DesktopWatchFeedSize size,
    double w,
    double h,
  ) {
    final l10n = context.l10n;
    final cardW = w * 0.31;
    final cardH = cardW * 16 / 9;
    final leftW = (w - 160 - 32) / 2;
    return Stack(
      children: [
        Positioned(
          right: 8,
          top: 8,
          child: IconButton(
            key: const Key('desktop-watch-feed-close'),
            tooltip: l10n.commonClose,
            icon: const Icon(Icons.close_rounded, color: Colors.white70),
            onPressed: _close,
          ),
        ),
        if (_failed || (!_loading && !_source.hasMore))
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.video_library_outlined,
                  size: 48,
                  color: Colors.white54,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.detailLoadFailed,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                if (_failed)
                  TextButton(
                    onPressed: _loadMore,
                    child: Text(l10n.commonRetry),
                  ),
              ],
            ),
          )
        else
          SkeletonPulse(
            child: Stack(
              children: [
                Positioned(
                  left: 32,
                  top: 32,
                  bottom: 32,
                  width: leftW - 64,
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      SkeletonBox(width: 140, height: 18),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBox(width: 220, height: 30),
                          SizedBox(height: 12),
                          SkeletonBox(width: 160, height: 16),
                        ],
                      ),
                      SkeletonBox(width: 200, height: 32),
                    ],
                  ),
                ),
                Positioned(
                  left: leftW + 48 + w * 0.05,
                  top: (h - cardH) / 2 - 15 - cardH,
                  child: Column(
                    children: [
                      for (var i = 0; i < 3; i++) ...[
                        if (i > 0) const SizedBox(height: 15),
                        SkeletonBox(
                          width: cardW,
                          height: cardH,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(12),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
