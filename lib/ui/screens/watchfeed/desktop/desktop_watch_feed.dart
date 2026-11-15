import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/md3e_theme.dart';
import '../../../../core/utils/artwork_palette.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/artist.dart';
import '../../../../models/track.dart';
import '../../../../models/watch_feed.dart';
import '../../../../providers/appearance_provider.dart';
import '../../../../providers/library_provider.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../services/spotify_api_service.dart';
import '../../../../services/watchfeed/preview_player.dart';
import '../../../navigation/app_routes.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/looping_video.dart';
import '../../../widgets/skeleton.dart';
import '../../../widgets/toast/app_toast.dart';
import '../../../widgets/track_menu.dart';

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

/// 官方宽度分档（按对话框宽度）：<778 小，<1102 中，其余大。
enum _Size { small, medium, large }

/// 数据来源：实体 feed 按 offset 分页，#标签 feed 按令牌分页。
abstract class _FeedSource {
  bool get hasMore;
  Future<List<WatchFeedItem>> next();
}

class _EntitySource implements _FeedSource {
  _EntitySource(this.api, this.uri, WatchFeedEntityPage? first) {
    if (first != null) _pending = first;
  }

  final SpotifyApiService api;
  final String uri;
  WatchFeedEntityPage? _pending;
  int? _nextOffset = 0;
  int _loaded = 0;

  /// 官方：已加载不超过 50 条且服务端还有下一页时才继续加载。
  @override
  bool get hasMore => _nextOffset != null && _loaded <= 50;

  @override
  Future<List<WatchFeedItem>> next() async {
    final page =
        _pending ??
        await api.watchFeed.fetchEntityFeed(uri, offset: _nextOffset ?? 0);
    _pending = null;
    _nextOffset = page.nextOffset;
    _loaded += page.items.length;
    return page.items;
  }
}

class _DiscoverySource implements _FeedSource {
  _DiscoverySource(this.api, this.uri);

  final SpotifyApiService api;
  final String uri;
  bool _started = false;
  dynamic _token;

  @override
  bool get hasMore => !_started || _token != null;

  @override
  Future<List<WatchFeedItem>> next() async {
    final page = await api.watchFeed.fetchFeed(uri, pageToken: _token);
    _started = true;
    _token = page.nextPageToken;
    return page.items;
  }
}

class _DesktopWatchFeedState extends State<DesktopWatchFeed> {
  late final WatchFeedPreviewPlayer _player =
      widget.player ?? WatchFeedPreviewPlayer();
  late final AppLifecycleListener _lifecycle;
  final FocusNode _focus = FocusNode(debugLabel: 'desktop-watch-feed');

  late String _title = widget.title;
  late _FeedSource _source;
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

  @override
  void initState() {
    super.initState();
    _source = _sourceFor(widget.feedUri, widget.initialPage);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
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

  _FeedSource _sourceFor(String uri, WatchFeedEntityPage? first) {
    final api = context.read<SpotifyApiService>();
    return uri.startsWith('spotify:watch-feed:discovery-feed')
        ? _DiscoverySource(api, uri)
        : _EntitySource(api, uri, first);
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

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
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
    } else if (key == LogicalKeyboardKey.keyM) {
      _player.setMuted(!_player.muted);
    } else if (key == LogicalKeyboardKey.space && event is KeyDownEvent) {
      _player.toggle();
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
                color: const Color(0xE6000000),
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
        ? _Size.small
        : w < 1102
        ? _Size.medium
        : _Size.large;
    final item = _items.isEmpty ? null : _items[_index];
    return _DialogBackground(
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
    _Size size,
    double w,
    double h,
    WatchFeedItem item,
  ) {
    final rightW = switch (size) {
      _Size.small => 86.0,
      _Size.medium => 128.0,
      _Size.large => 160.0,
    };
    final pad = switch (size) {
      _Size.small => 16.0,
      _Size.medium => 24.0,
      _Size.large => 32.0,
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
            child: _LeftColumn(
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
                    child: _FeedCard(
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
            child: _RightColumn(
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
            child: _NextPill(
              label: context.l10n.playerNext,
              large: size != _Size.small,
              onPressed: () => _move(1),
            ),
          ),
      ],
    );
  }

  /// 加载骨架 / 错误态：左栏几条闪烁文字块，中间三张 #333 卡片；右上角仍可关闭。
  Widget _buildPlaceholder(
    BuildContext context,
    _Size size,
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

/// 对话框底：当前曲目封面的深色（0.5s 过渡），叠一层从右侧中心透明、35% 处变为页面底色的径向渐变；
/// 1px 描边、圆角 8。
///
/// 颜色优先用服务端给的封面深色，没有时从封面取色。无论哪种来源，组件结构都保持不变——
/// 结构一变，里面的轮播会被整个重建并回到初始页（曾导致翻几首后跳回第一首、封面对不上）。
class _DialogBackground extends StatefulWidget {
  const _DialogBackground({
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
  State<_DialogBackground> createState() => _DialogBackgroundState();
}

class _DialogBackgroundState extends State<_DialogBackground> {
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
  void didUpdateWidget(covariant _DialogBackground oldWidget) {
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
class _FeedCard extends StatelessWidget {
  const _FeedCard({
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

/// 左栏：feed 标题（上）→ 曲目块（中：大号歌名、艺人、专辑封面 + 进度）→ 艺人行与 #标签（下）。
class _LeftColumn extends StatelessWidget {
  const _LeftColumn({
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
  final _Size size;
  final int direction;
  final WatchFeedPreviewPlayer player;
  final ValueChanged<SpotifyTrack> onOpenAlbum;
  final ValueChanged<SpotifyArtist> onOpenArtist;
  final ValueChanged<WatchFeedHashtag> onOpenHashtag;

  @override
  Widget build(BuildContext context) {
    final track = item.playableTrack;
    final large = size == _Size.large;
    final titleSize = switch (size) {
      _Size.small => 20.0,
      _Size.medium => 24.0,
      _Size.large => 32.0,
    };
    final gap = size == _Size.small ? 8.0 : 16.0;
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

/// 右栏：顶部静音 + 关闭；中间更多 / 复制链接 / 加入队列 / 保存；底部上一首 / 下一首。
class _RightColumn extends StatelessWidget {
  const _RightColumn({
    required this.item,
    required this.size,
    required this.canPrevious,
    required this.canNext,
    required this.interacted,
    required this.onClose,
    required this.onPrevious,
    required this.onNext,
    required this.onToggleSave,
    required this.onAddToQueue,
    required this.onCopyLink,
  });

  final WatchFeedItem item;
  final _Size size;
  final bool canPrevious;
  final bool canNext;
  final bool interacted;
  final VoidCallback onClose;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToggleSave;
  final VoidCallback onAddToQueue;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final track = item.playableTrack;
    final muted = context.select<WatchFeedPreviewPlayer, bool>((p) => p.muted);
    final playing = context.select<WatchFeedPreviewPlayer, bool>(
      (p) => p.isPlaying,
    );
    final saved = context.select<LibraryProvider?, bool>(
      (l) => track != null && (l?.isLiked(track.id) ?? false),
    );
    final stackGap = size == _Size.small ? 32.0 : 48.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // 窄档（右栏内宽只有 54）放不下两个按钮时折成两行。
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            _TertiaryButton(
              key: const Key('desktop-watch-feed-mute'),
              tooltip: muted ? l10n.watchFeedUnmute : l10n.watchFeedMute,
              onPressed: () =>
                  context.read<WatchFeedPreviewPlayer>().setMuted(!muted),
              child: muted
                  ? const Icon(Icons.volume_off_rounded, size: 20)
                  : _MiniEqualizer(playing: playing),
            ),
            _TertiaryButton(
              key: const Key('desktop-watch-feed-close'),
              tooltip: l10n.commonClose,
              onPressed: onClose,
              child: const Icon(Icons.close_rounded, size: 22),
            ),
          ],
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (track != null)
              Builder(
                builder: (buttonContext) => _TertiaryButton(
                  key: const Key('desktop-watch-feed-more'),
                  tooltip: l10n.commonMoreOptions,
                  onPressed: () => TrackMenu.show(buttonContext, track),
                  child: const Icon(Icons.more_horiz_rounded, size: 24),
                ),
              ),
            SizedBox(height: stackGap / 3),
            _TertiaryButton(
              tooltip: l10n.shareCopyLink,
              onPressed: onCopyLink,
              child: const Icon(Icons.link_rounded, size: 22),
            ),
            SizedBox(height: stackGap / 3),
            _TertiaryButton(
              tooltip: l10n.trackAddToQueue,
              onPressed: onAddToQueue,
              child: const Icon(Icons.queue_music_rounded, size: 22),
            ),
            SizedBox(height: stackGap / 3),
            _TertiaryButton(
              key: const Key('desktop-watch-feed-save'),
              tooltip: saved ? l10n.likeRemove : l10n.likeAdd,
              onPressed: onToggleSave,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: Icon(
                  saved
                      ? Icons.check_circle_rounded
                      : Icons.add_circle_outline_rounded,
                  key: ValueKey(saved),
                  size: 26,
                  color: saved ? const Color(0xFF1ED760) : Colors.white,
                ),
              ),
            ),
          ],
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (canPrevious) ...[
              _TertiaryButton(
                key: const Key('desktop-watch-feed-previous'),
                tooltip: l10n.playerPrevious,
                onPressed: onPrevious,
                child: const Icon(Icons.keyboard_arrow_up_rounded, size: 28),
              ),
              const SizedBox(height: 8),
            ],
            // 首次翻页前的「下一首」胶囊浮在对话框右下角（见 _buildRow），这里不重复放。
            if (interacted || !canNext)
              _TertiaryButton(
                key: const Key('desktop-watch-feed-next'),
                tooltip: l10n.playerNext,
                onPressed: canNext ? onNext : null,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: size == _Size.small ? 24 : 28,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Encore 三级按钮：无底色，图标 #B3B3B3，悬停变白并加 30% 白底圆。
class _TertiaryButton extends StatelessWidget {
  const _TertiaryButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      // Encore 三级图标按钮：36×36，比 Material 默认的 48 紧凑（右栏最窄只有 54 宽）。
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0x4DFFFFFF)
              : states.contains(WidgetState.hovered)
              ? Colors.white
              : const Color(0xFFB3B3B3),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? const Color(0x1AFFFFFF)
              : Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      icon: child,
    );
  }
}

/// 首次翻页前的「下一首」白色胶囊：带向下箭头，0.8s 上下跳动并在白色 / 60% 白之间呼吸，悬停停住。
class _NextPill extends StatefulWidget {
  const _NextPill({
    required this.label,
    required this.onPressed,
    this.large = true,
  });

  final String label;
  final VoidCallback onPressed;

  /// 中 / 大档：高 48、字号 16；小档：高 40、字号 14。
  final bool large;

  @override
  State<_NextPill> createState() => _NextPillState();
}

class _NextPillState extends State<_NextPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !MediaQuery.disableAnimationsOf(context)) {
        _bounce.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(
      parent: _bounce,
      curve: const Cubic(0.58, 0, 0.43, 1),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        _bounce.stop();
      },
      onExit: (_) {
        setState(() => _hover = false);
        if (!MediaQuery.disableAnimationsOf(context)) {
          _bounce.repeat(reverse: true);
        }
      },
      child: GestureDetector(
        key: const Key('desktop-watch-feed-next-pill'),
        onTap: widget.onPressed,
        child: AnimatedBuilder(
          animation: curve,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, _hover ? 0 : -8 * curve.value),
            child: Container(
              height: widget.large ? 48 : 40,
              padding: EdgeInsets.symmetric(horizontal: widget.large ? 24 : 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover
                    ? Colors.white
                    : Color.lerp(
                        const Color(0xFFFFFFFF),
                        const Color(0x99FFFFFF),
                        curve.value,
                      ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x4D000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: child,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                    fontSize: widget.large ? 16 : 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_downward_rounded,
                size: widget.large ? 20 : 18,
                color: Colors.black,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 静音按钮里的小均衡器（官方是一张白色动图）：三根竖条，播放时跳动。
class _MiniEqualizer extends StatefulWidget {
  const _MiniEqualizer({required this.playing});

  final bool playing;

  @override
  State<_MiniEqualizer> createState() => _MiniEqualizerState();
}

class _MiniEqualizerState extends State<_MiniEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _MiniEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.playing) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.white;
    return SizedBox.square(
      dimension: 20,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                height:
                    4 +
                    12 *
                        (widget.playing
                            ? (0.5 -
                                  0.5 *
                                      math.cos(
                                        (_c.value + i * 0.3) * 2 * math.pi,
                                      ))
                            : 0.3),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
