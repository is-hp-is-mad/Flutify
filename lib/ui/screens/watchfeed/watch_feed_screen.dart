import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/md3e_theme.dart';
import '../../../core/theme/system_bars.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playback_context.dart';
import '../../../models/track.dart';
import '../../../models/watch_feed.dart';
import '../../../providers/appearance_provider.dart';
import '../../../providers/playback_provider.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/spotify_api_service.dart';
import '../../../services/watchfeed/preview_player.dart';
import '../../shell/shell_chrome.dart';
import '../../widgets/skeleton.dart';
import '../detail/album_detail_screen.dart';
import 'widgets/feed_animations.dart';
import 'widgets/feed_item_card.dart';

/// 官方竖滑发现流（对齐 Spotify 的 watch feed / discovery feed）。
///
/// - 上下滑：同一个 feed 内逐条浏览（下一张从底部露出 6%，相邻页 0.8 透明度）；
/// - 左右滑：在主 feed 与服务端下发的关联 feed（`pivoting.additional_pages_uris`）之间切换，
///   顶栏标题随之切换为对应的「#标签」，并显示页码点；
/// - 声音是条目自带的约 30 秒试听（独立播放器，进入即暂停主播放器）；点曲目行才用主播放器播完整歌曲；
/// - 点 #标签进入该标签的 feed（压栈，返回后继续）。
class WatchFeedScreen extends StatefulWidget {
  const WatchFeedScreen({
    super.key,
    required this.feedUri,
    this.title = '',
    this.player,
  });

  /// `spotify:watch-feed:…`
  final String feedUri;

  /// 入口卡片上的标题（服务端头部标题到达前先显示）。
  final String title;

  /// 外部注入的试听播放器（测试用）；为 null 时本页自建并负责释放。
  final WatchFeedPreviewPlayer? player;

  @override
  State<WatchFeedScreen> createState() => _WatchFeedScreenState();
}

class _WatchFeedScreenState extends State<WatchFeedScreen> {
  late final WatchFeedPreviewPlayer _player =
      widget.player ?? WatchFeedPreviewPlayer();
  final PageController _horizontal = PageController();
  late final AppLifecycleListener _lifecycle;

  /// 横向页：主 feed + 关联 feed。
  List<String> _feedUris = const [];

  /// 横向页标题（服务端头部；不足时用入口标题兜底）。
  List<String> _titles = const [];

  int _hIndex = 0;

  /// 当前是否被别的页面（如点进 #标签后的 feed）压住：压住时所有试听暂停。
  bool _covered = false;

  /// 从压在上面的页面（如专辑页）返回时主播放器正在放：试听保持暂停、不打断，
  /// 直到用户在 feed 里翻到别的歌（上下 / 左右滑）或轻点继续试听。
  bool _yieldedToMain = false;

  /// 竖滑引导（服务端文案；本机只展示一次）。
  String _verticalHint = '';
  bool _showVerticalHint = false;

  /// 横滑引导（「Swipe for more feeds」，本机只展示一次）。
  String _associatedHint = '';
  bool _showAssociatedHint = false;
  Timer? _associatedHintTimer;

  @override
  void initState() {
    super.initState();
    _feedUris = [widget.feedUri];
    _titles = [if (widget.title.isNotEmpty) widget.title];
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    // 本页即播放器：进入时暂停主播放（官方 feed 同样接管声音）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _pauseMainPlayback());
  }

  @override
  void dispose() {
    // 撤回「隐藏底部导航」请求；放到微任务里，避免在卸载树的过程中通知外壳重建。
    final chrome = ShellChrome.instance;
    final owner = this;
    scheduleMicrotask(() => chrome.request(owner, null, hide: false));
    _associatedHintTimer?.cancel();
    _lifecycle.dispose();
    _horizontal.dispose();
    if (widget.player == null) _player.dispose();
    super.dispose();
  }

  /// App 是否在前台：不在前台时试听暂停、视频卸载。
  bool _foreground = true;

  /// 切到后台时是否正在试听：回到前台只恢复原本在播的（用户手动暂停的保持暂停）。
  bool _resumeOnForeground = false;

  void _onLifecycle(AppLifecycleState state) {
    final foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (foreground == _foreground) return;
    if (!foreground) {
      _resumeOnForeground = _player.isPlaying || _player.isLoading;
      _player.pause();
    } else if (_resumeOnForeground && !_covered) {
      _resumeOnForeground = false;
      _player.resume();
    }
    setState(() => _foreground = foreground);
  }

  void _pauseMainPlayback() {
    if (!mounted) return;
    final playback = context.read<PlaybackProvider?>();
    if (playback != null && playback.isPlaying) playback.pause();
  }

  /// 主 feed 第一页到达：展开关联 feed、头部标题与引导。
  void _onMainFeedLoaded(WatchFeedPage page) {
    if (!mounted) return;
    final prefs = context.read<PreferencesProvider?>();
    setState(() {
      if (page.associatedFeedUris.isNotEmpty && _feedUris.length == 1) {
        _feedUris = [widget.feedUri, ...page.associatedFeedUris];
      }
      if (page.headerTitles.isNotEmpty) _titles = page.headerTitles;
      _verticalHint = page.verticalOnboardingText;
      _associatedHint = page.associatedOnboardingText;
      _showVerticalHint =
          _verticalHint.isNotEmpty &&
          !(prefs?.watchFeedOnboardingShown ?? true);
    });
    if (_feedUris.length > 1 &&
        _associatedHint.isNotEmpty &&
        !(prefs?.watchFeedPivotHintShown ?? true)) {
      // 官方 delay 5000ms 后从右侧滑入。
      _associatedHintTimer = Timer(const Duration(seconds: 5), () {
        if (mounted && !_covered) setState(() => _showAssociatedHint = true);
      });
    }
  }

  void _dismissVerticalHint() {
    if (!_showVerticalHint) return;
    context.read<PreferencesProvider?>()?.setWatchFeedOnboardingShown(true);
    setState(() => _showVerticalHint = false);
  }

  void _dismissAssociatedHint() {
    _associatedHintTimer?.cancel();
    if (!_showAssociatedHint) return;
    context.read<PreferencesProvider?>()?.setWatchFeedPivotHintShown(true);
    setState(() => _showAssociatedHint = false);
  }

  /// 用户翻到某条或轻点继续试听：feed 重新接管声音，主播放暂停。
  void _onItemActivated() {
    if (_yieldedToMain) setState(() => _yieldedToMain = false);
    _pauseMainPlayback();
    _dismissVerticalHint();
  }

  Future<void> _openHashtag(WatchFeedHashtag tag) => _cover(
    WatchFeedScreen(
      feedUri: tag.navigationUri,
      title: tag.title,
      player: widget.player,
    ),
  );

  /// 在本页之上压一个页面：期间试听暂停。返回时：
  /// - 用户在那边开始播放了（主播放器在放）：试听保持暂停，不打断，直到用户在 feed 里翻到下一首；
  /// - 否则本页重新接管声音（feed 即播放器）。
  Future<void> _cover(Widget page) async {
    await _player.pause();
    if (!mounted) return;
    setState(() => _covered = true);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    if (!mounted) return;
    final mainPlaying =
        context.read<PlaybackProvider?>()?.isPlaybackActive ?? false;
    setState(() {
      _covered = false;
      _yieldedToMain = mainPlaying;
    });
    if (!mainPlaying) _pauseMainPlayback();
  }

  /// 点左下角曲目行：进入这首歌所在的专辑并定位到这一首；
  /// 拿不到专辑（服务端没给曲目菜单组件）时退回为直接播放完整歌曲。
  void _openTrack(SpotifyTrack track, List<SpotifyTrack> queue) {
    final album = track.album;
    if (album == null || album.id.isEmpty) {
      _playFull(track, queue);
      return;
    }
    unawaited(_cover(AlbumDetailScreen(album: album, focusTrack: track)));
  }

  /// 播放完整歌曲：停掉试听，交给主播放器（队列 = 本 feed 已加载的曲目）。
  void _playFull(SpotifyTrack track, List<SpotifyTrack> queue) {
    _player.pause();
    context.read<PlaybackProvider?>()?.playTrack(
      track,
      contextQueue: queue,
      context: PlaybackContext.none,
    );
  }

  void _stepHorizontal(int delta) {
    final target = _hIndex + delta;
    if (target < 0 || target >= _feedUris.length || !_horizontal.hasClients) {
      return;
    }
    _horizontal.animateToPage(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _stepHorizontal(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _stepHorizontal(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // 本页是所在 Tab 的当前页时请求外壳隐藏底部导航与迷你播放栏；上面压了专辑页等页面时撤回，
    // 那些页面照常显示边框。ModalRoute.isCurrentOf 会在路由栈变化时触发重建。
    final isCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final navigator = Navigator.maybeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ShellChrome.instance.request(this, navigator, hide: isCurrent);
      }
    });
    final theme =
        context.watch<AppearanceProvider?>()?.theme(Brightness.dark) ??
        MD3ETheme.dark;
    return Theme(
      data: theme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBarsStyle(Brightness.dark),
        child: ChangeNotifierProvider<WatchFeedPreviewPlayer>.value(
          value: _player,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Focus(
              autofocus: true,
              onKeyEvent: (_, event) => _onKey(event),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // feed 铺满状态栏以下的整块区域，顶栏浮在卡片顶部（对齐官方 pivoting_host_layout）。
                  Padding(
                    padding: EdgeInsets.only(
                      top: MediaQuery.paddingOf(context).top,
                    ),
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      removeBottom: true,
                      child: PageView.builder(
                        controller: _horizontal,
                        itemCount: _feedUris.length,
                        onPageChanged: (i) {
                          // 左右换 feed 也算换歌：重新接管声音。
                          setState(() {
                            _hIndex = i;
                            _yieldedToMain = false;
                          });
                          _pauseMainPlayback();
                          _dismissAssociatedHint();
                        },
                        itemBuilder: (context, i) => _FeedPager(
                          key: ValueKey(_feedUris[i]),
                          feedUri: _feedUris[i],
                          active: i == _hIndex && !_covered,
                          autoplay: !_yieldedToMain,
                          foreground: _foreground,
                          player: _player,
                          onFirstPage: i == 0 ? _onMainFeedLoaded : null,
                          onItemActivated: _onItemActivated,
                          onOpenHashtag: _openHashtag,
                          onPlayFull: _openTrack,
                        ),
                      ),
                    ),
                  ),
                  _buildTopBar(context),
                  if (_showAssociatedHint) _buildAssociatedHint(context),
                  if (_showVerticalHint) _buildVerticalHint(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final l10n = context.l10n;
    final title = _hIndex < _titles.length
        ? _titles[_hIndex]
        : (_titles.isNotEmpty ? _titles.first : widget.title);
    // 顶栏浮在卡片顶部：垫一层由深到透明的渐变保证白字可读（不吃手势）。
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x99000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 72,
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: Text(
                            title,
                            key: ValueKey(title),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  shadows: const [
                                    Shadow(
                                      color: Colors.black54,
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                          ),
                        ),
                      ),
                      Selector<WatchFeedPreviewPlayer, bool>(
                        selector: (_, p) => p.muted,
                        builder: (context, muted, _) => IconButton(
                          key: const Key('watch-feed-mute'),
                          tooltip: muted
                              ? l10n.watchFeedUnmute
                              : l10n.watchFeedMute,
                          icon: Icon(
                            muted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            color: Colors.white,
                          ),
                          onPressed: () => _player.setMuted(!muted),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                if (_feedUris.length > 1)
                  _PagerDots(count: _feedUris.length, index: _hIndex),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 横滑引导：屏幕 33% 高处，从右侧滑入淡入（500ms），点一下或左右滑后消失。
  Widget _buildAssociatedHint(BuildContext context) {
    return Positioned(
      right: 16,
      top: MediaQuery.sizeOf(context).height * 0.33,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 500),
        curve: kFeedEase,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(40 * (1 - t), 0),
            child: child,
          ),
        ),
        child: GestureDetector(
          onTap: _dismissAssociatedHint,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.swipe_left_rounded,
                  color: Colors.black,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  _associatedHint,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 竖滑引导：70% 黑罩 + 手指上滑动画（宽 42%）+ 加粗文案；点击或第一次上滑后消失。
  Widget _buildVerticalHint(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        key: const Key('watch-feed-vertical-hint'),
        onTap: _dismissVerticalHint,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 300),
          builder: (context, t, child) => Opacity(opacity: t, child: child),
          child: ColoredBox(
            color: const Color(0xB3000000),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FractionallySizedBox(
                    widthFactor: 0.42,
                    child: const FeedSwipeUpHint(),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _verticalHint,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
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

/// 页码点：选中为 24dp 宽的白色胶囊，其余 6dp 圆点（#33FFFFFF）；页数多时只显示当前附近 7 个，
/// 两端的点缩小到 4dp（官方 WatchFeedPagerIndicatorView）。
class _PagerDots extends StatelessWidget {
  const _PagerDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    const window = 7;
    final start = count <= window
        ? 0
        : (index - window ~/ 2).clamp(0, count - window);
    final end = math.min(count, start + window);
    return SizedBox(
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = start; i < end; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index
                  ? 24
                  : ((i == start && start > 0) || (i == end - 1 && end < count))
                  ? 4
                  : 6,
              height: i == index ? 6 : 6,
              decoration: BoxDecoration(
                color: i == index ? Colors.white : const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单个 feed 的竖滑分页：加载 / 翻页 / 分页加载 / 试听切换。
class _FeedPager extends StatefulWidget {
  const _FeedPager({
    super.key,
    required this.feedUri,
    required this.active,
    this.autoplay = true,
    required this.foreground,
    required this.player,
    required this.onItemActivated,
    required this.onOpenHashtag,
    required this.onPlayFull,
    this.onFirstPage,
  });

  final String feedUri;

  /// 是否为当前横向页（且未被压住）：只有当前页播放试听。
  final bool active;

  /// 变为当前页时是否自动起播试听（让位给主播放器时为 false）。
  final bool autoplay;

  /// App 是否在前台：后台时卸载视频（WebView 不在后台解码）。
  final bool foreground;
  final WatchFeedPreviewPlayer player;
  final ValueChanged<WatchFeedPage>? onFirstPage;
  final VoidCallback onItemActivated;
  final ValueChanged<WatchFeedHashtag> onOpenHashtag;
  final void Function(SpotifyTrack track, List<SpotifyTrack> queue) onPlayFull;

  @override
  State<_FeedPager> createState() => _FeedPagerState();
}

class _FeedPagerState extends State<_FeedPager> {
  /// 下一张卡片从底部露出 6%（官方 discovery_feed_card_peek_percent）。
  static const double _peek = 0.06;

  final PageController _controller = PageController(
    viewportFraction: 1 - _peek,
  );
  final List<WatchFeedItem> _items = [];
  int _index = 0;
  bool _loading = false;
  bool _failed = false;
  bool _exhausted = false;
  Uint8List? _next;

  /// 滚轮冷却（按事件时间戳）。
  Duration? _lastWheel;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  @override
  void didUpdateWidget(covariant _FeedPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 变为当前横向页：首帧后再起播（didUpdateWidget 处于 build 阶段，播放器会同步通知）。
    if (widget.active && !oldWidget.active && widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playCurrent();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || _exhausted) return;
    final api = context.read<SpotifyApiService?>();
    if (api == null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await api.watchFeed.fetchFeed(
        widget.feedUri,
        pageToken: _next,
      );
      if (!mounted) return;
      final first = _items.isEmpty;
      setState(() {
        _items.addAll(page.items);
        _next = page.nextPageToken;
        _exhausted = _next == null || page.items.isEmpty;
        _loading = false;
      });
      if (first) {
        widget.onFirstPage?.call(page);
        if (widget.autoplay) _playCurrent();
      }
    } catch (e) {
      debugPrint('[watch-feed] 加载失败：$e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// 当前横向页的当前条目：播放其试听（没有试听就停掉上一条）。
  void _playCurrent() {
    if (!widget.active || _items.isEmpty) return;
    final item = _items[_index.clamp(0, _items.length - 1)];
    final audio = item.audio;
    if (audio == null) {
      widget.player.stop();
    } else {
      widget.player.play(audio);
    }
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    widget.onItemActivated();
    _playCurrent();
    if (index >= _items.length - 2) _loadMore();
  }

  void _togglePlay(int index) {
    if (index != _index) return;
    final player = widget.player;
    final audio = _items[index].audio;
    if (audio == null) return;
    if (player.currentUrl == audio.url) {
      player.toggle();
    } else {
      player.play(audio);
    }
    widget.onItemActivated();
  }

  void _step(int delta) {
    final target = _index + delta;
    if (target < 0 || target >= _items.length || !_controller.hasClients) {
      return;
    }
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final delta =
        key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.pageDown
        ? 1
        : key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.pageUp
        ? -1
        : 0;
    if (delta == 0) {
      if (key == LogicalKeyboardKey.space) {
        _togglePlay(_index);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    _step(delta);
    return KeyEventResult.handled;
  }

  /// 滚轮翻页：透明层叠在 PageView 之上抢先注册（放进页面内部的话，翻页动画期间 Scrollable 会让子树忽略指针，后续滚轮事件漏给 PageView 停在半页）。
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
      _step(dy > 0 ? 1 : -1);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      if (_failed || (_exhausted && !_loading)) return _buildError(context);
      return const _FeedSkeleton();
    }
    final queue = [for (final i in _items) ?i.playableTrack];
    return Focus(
      autofocus: widget.active,
      onKeyEvent: (_, event) =>
          widget.active ? _onKey(event) : KeyEventResult.ignored,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 高度为可视区的 94%（其余露出下一张）减 8dp 间距；手机上宽度贴满（左右各 6dp），
          // 只有宽屏（平板 / 桌面）才按 9:16 收窄居中。
          final pageHeight = constraints.maxHeight * (1 - _peek);
          final cardHeight = pageHeight - 8;
          final cardWidth = math.min(
            constraints.maxWidth - 12,
            cardHeight * 9 / 16,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: _controller,
                scrollDirection: Axis.vertical,
                padEnds: false,
                itemCount: _items.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Center(
                    child: SizedBox(
                      width: cardWidth,
                      height: cardHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          WatchFeedItemCard(
                            key: ValueKey(
                              _items[i].id.isNotEmpty ? _items[i].id : '$i',
                            ),
                            item: _items[i],
                            active: widget.active && i == _index,
                            foreground: widget.foreground,
                            player: widget.player,
                            onTogglePlay: () => _togglePlay(i),
                            onPlayFull: (track) =>
                                widget.onPlayFull(track, queue),
                            onOpenHashtag: widget.onOpenHashtag,
                          ),
                          _NeighborDim(controller: _controller, index: i),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: _onPointerSignal,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, size: 48, color: Colors.white54),
          const SizedBox(height: 16),
          Text(
            l10n.detailLoadFailed,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              setState(() => _exhausted = false);
              _loadMore();
            },
            child: Text(l10n.commonRetry),
          ),
        ],
      ),
    );
  }
}

/// 相邻卡片压暗：官方为透明度 `0.8 + 0.2 × (1 − |偏移|)`。底色是纯黑，等价于叠一层
/// 最多 20% 的黑色——比给含视频（平台视图）的整张卡片加 Opacity 图层便宜得多。
class _NeighborDim extends StatelessWidget {
  const _NeighborDim({required this.controller, required this.index});

  final PageController controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final page =
              controller.hasClients && controller.position.haveDimensions
              ? controller.page ?? 0
              : 0.0;
          final offset = (page - index).abs().clamp(0.0, 1.0);
          if (offset < 0.01) return const SizedBox.shrink();
          return DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2 * offset),
              borderRadius: BorderRadius.circular(24),
            ),
          );
        },
      ),
    );
  }
}

/// 加载骨架（对齐官方 discovery_feed_loading_layout）：圆角卡片内，左下 48dp 封面 + 两条文字，
/// 右侧三个 24dp 图标位 + 一个 32dp 圆。
class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: ColoredBox(
          color: const Color(0xFF1A1A1A),
          child: SkeletonPulse(
            child: Stack(
              children: [
                Positioned(
                  left: 16,
                  right: 80,
                  bottom: 24,
                  child: Row(
                    children: const [
                      SkeletonBox(
                        width: 48,
                        height: 48,
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SkeletonBox(width: 140, height: 14),
                            SizedBox(height: 8),
                            SkeletonBox(width: 90, height: 12),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 20,
                  bottom: 24,
                  child: Column(
                    children: const [
                      SkeletonBox(width: 24, height: 24, circular: true),
                      SizedBox(height: 24),
                      SkeletonBox(width: 24, height: 24, circular: true),
                      SizedBox(height: 24),
                      SkeletonBox(width: 24, height: 24, circular: true),
                      SizedBox(height: 24),
                      SkeletonBox(width: 32, height: 32, circular: true),
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
