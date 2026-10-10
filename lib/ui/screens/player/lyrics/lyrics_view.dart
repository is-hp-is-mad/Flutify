import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/app_preferences.dart';
import '../../../../models/lyrics.dart';
import '../../../../models/lyrics_query.dart';
import '../../../../models/track.dart';
import '../../../../providers/connect_provider.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../providers/spotify_provider.dart';
import '../../../../services/lyrics/lyrics_translation.dart';
import '../../../widgets/connect/connect_actions.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/skeleton.dart';
import 'breathing_dots.dart';
import 'apple_music_motion.dart';
import 'lyric_line_view.dart';

/// 歌词滚动区。
///
/// 行为（对齐 Apple Music）：
/// - 当前行顶端停在用户设置的可视区位置，上下句按距离逐级模糊；
/// - 前奏与间奏（无人声片段）显示三个呼吸点，只在该片段内出现，结束时收起；歌曲末尾的无人声不显示；
/// - 用户手动拖动时全部行变清晰（[_browsing]）并显示滚动条；Apple 模式在手指离开、
///   惯性滚动结束后等待 5 秒再跟随，其他模式保持 3 秒；
///   自动滚动时不显示滚动条；
/// - 点击任意行跳转到该行时间点；
/// - 非同步歌词（UNSYNCED）全部清晰显示、不可点击。
///
/// 性能：手动监听 positionNotifier，只有「当前行」变化时才 setState；
/// 当前行用二分查找定位。
class LyricsView extends StatefulWidget {
  /// 曲目：官方歌词按 ID 取，LRCLIB 补全按曲名 / 歌手 / 专辑 / 时长匹配。
  final SpotifyTrack track;

  /// 顶部 / 底部被玻璃控件覆盖的高度，歌词可从其下方滚过。
  final double topInset;
  final double bottomInset;

  /// 歌词字号：手机 / 右栏 30，桌面沉浸式更大。
  final double fontSize;

  /// 歌词区左右留白。
  final double horizontalPadding;

  /// 跟随正在遥控的远程设备：进度取 [ConnectProvider.position]，点行跳转发给远程设备。
  /// 创建后不可切换，调用方用包含它的 key 让本地 / 远程切换时重建。
  final bool remote;
  final bool appleMusicStyle;

  /// 可跳转歌词行的鼠标指针；沉浸式传 [MouseCursor.defer]，由外层控制隐藏光标。
  final MouseCursor lineCursor;

  const LyricsView({
    super.key,
    required this.track,
    this.topInset = 0,
    this.bottomInset = 0,
    this.fontSize = 30,
    this.horizontalPadding = 28,
    this.remote = false,
    this.lineCursor = SystemMouseCursors.click,
    this.appleMusicStyle = false,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const Duration _browseHold = Duration(seconds: 3);
  static const Duration _appleBrowseHold = Duration(seconds: 5);

  /// 提前切行量：进度流约 200ms 一次，加上对焦/滚动动画耗时，
  /// 不提前的话视觉上会比演唱慢半拍（Apple Music 同样提前切行）。
  static const int _leadMs = 300;

  /// 第一句开唱前的留白至少这么长才显示前奏呼吸点。
  static const int _minIntroMs = 3000;

  /// 间奏短于这个时长不显示呼吸点（一闪而过反而打扰），对焦停在上一句。
  static const int _minGapMs = 1500;

  /// 切行滚动与间奏收起 / 展开共用的时长与曲线（两者同步，位置才不会跳）。
  static const Duration _scrollDuration = Duration(milliseconds: 560);
  static const Curve _scrollCurve = Cubic(0.22, 1.0, 0.36, 1.0);

  /// 歌词区可视高度（由 LayoutBuilder 写入），用于定位当前行。
  double _viewportHeight = 0;

  late final ValueListenable<Duration> _position;
  late final void Function(Duration position) _seek;
  late final ScrollController _scroll = _LyricsScrollController(
    reflowTarget: _translationLayoutTarget,
  );

  SpotifyLyrics? _lyrics;
  late final LyricsTranslationController _translation;
  late final bool _ownsTranslation;
  SpotifyLyrics? _translationLyrics;
  String? _translationTrackUri;
  late final AnimationController _translationReveal = AnimationController(
    vsync: this,
  )..addListener(_onTranslationFrame);
  List<String>? _visibleTranslations;
  double _translationTarget = 0;
  double _translationScrollStart = 0;
  double _translationScrollDelta = 0;
  bool _translationFramePending = false;
  int _loadRevision = 0;
  List<GlobalKey> _lineKeys = const [];
  final GlobalKey _introKey = GlobalKey();

  /// 每行是否为空行（间奏占位：空串或 ♪）。
  List<bool> _blank = const [];

  /// 空行所在间奏的结束时间（其后第一句有词歌词的开始）；歌曲末尾的空行为 null（不显示呼吸点）。
  List<int?> _gapEnd = const [];

  /// 第一句之前是否有足够长的前奏（第一行本身就是空行时由该行承担前奏）。
  bool _hasIntro = false;
  int _activeIndex = -1;
  bool _browsing = false;
  Timer? _browseTimer;
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 813),
    value: 1,
  );
  Map<int, double> _moveOffsets = {};
  int _moveFocus = 0;
  int? _renderedFocus;
  int? _renderedGap;
  final Set<int> _touches = {};
  bool _userScrolling = false;
  bool _pendingAnchor = false;
  bool _gapReflowPending = false;
  bool _appActive = true;
  bool _tickerEnabled = true;

  bool get _interactionActive => _appActive && _tickerEnabled;

  double _moveOffset(int i) =>
      (_moveOffsets[i] ?? 0) *
      AppleMusicMotion.remainingMove(i - _moveFocus, _move.value * 813);

  Map<int, double> _captureRows() => {
    for (var i = -1; i < _lineKeys.length; i++)
      if (_boxOf(i < 0 ? _introKey : _lineKeys[i]) case final box?)
        i: box.localToGlobal(Offset.zero).dy + _moveOffset(i),
  };

  /// 歌词样式（设置页「歌词」分组）；没有 PreferencesProvider（部分测试）时用默认值。
  AppPreferences _style = AppPreferences.defaults;

  bool get _isSynced => _lyrics?.isSynced ?? false;
  bool get _translationIsCurrent =>
      identical(_lyrics, _translationLyrics) &&
      widget.track.uri == _translationTrackUri;

  /// 用于切行的时间点：固定提前量 + 远程模式下用户设置的提前量（服务端快照推算会有偏差）。
  int get _lookupMs =>
      _position.value.inMilliseconds +
      (widget.appleMusicStyle ? _appleLeadMs : _leadMs) +
      (widget.remote ? _style.remoteLyricsLeadMs : 0);

  int get _rawMs =>
      _position.value.inMilliseconds +
      (widget.remote ? _style.remoteLyricsLeadMs : 0);

  int get _appleLeadMs {
    final next = _indexFor(_rawMs + 750);
    if (next > 0 && !_blank[next] && _blank[next - 1]) {
      var head = next - 1;
      while (head > 0 && _blank[head - 1]) {
        head--;
      }
      return AppleMusicMotion.leadMs(
        silentGapMs:
            _lyrics!.lines[next].startTimeMs - _lyrics!.lines[head].startTimeMs,
      );
    }
    return AppleMusicMotion.leadMs();
  }

  @override
  void initState() {
    super.initState();
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_releasePointer);
    final shared = context.read<LyricsTranslationController?>();
    _ownsTranslation = shared == null;
    _translation =
        shared ??
        LyricsTranslationController(
          lookup: context.read<SpotifyProvider>().fetchLyricsTranslation,
        );
    _translation.addListener(_onTranslation);
    if (widget.remote) {
      final connect = context.read<ConnectProvider>();
      _position = connect.position;
      _seek = (d) =>
          ConnectActions.run(context, () => connect.seekTo(d.inMilliseconds));
    } else {
      final playback = context.read<PlaybackProvider>();
      _position = playback.positionNotifier;
      _seek = playback.seekTo;
    }
    _position.addListener(_onPosition);
    _load();
  }

  /// 已加载的歌词对应的缓存代数（[SpotifyProvider.lyricsGeneration]），变化时重新加载。
  int _generation = 0;

  void _load() {
    final revision = ++_loadRevision;
    final spotify = context.read<SpotifyProvider>();
    _generation = spotify.lyricsGeneration;
    final cached = spotify.cachedLyrics(widget.track.id);
    if (cached != null) {
      _setLyrics(cached);
      return;
    }
    final generation = _generation;
    spotify.fetchLyrics(LyricsQuery.fromTrack(widget.track)).then((lyrics) {
      if (mounted && generation == _generation && revision == _loadRevision) {
        setState(() => _setLyrics(lyrics));
      }
    });
  }

  void _setLyrics(SpotifyLyrics lyrics) {
    _move.value = 1;
    _moveOffsets = {};
    _browseTimer?.cancel();
    _browsing = false;
    _pendingAnchor = false;
    _gapReflowPending = false;
    _translationReveal.stop();
    _translationLyrics = null;
    _translationTrackUri = null;
    _visibleTranslations = null;
    _translationTarget = 0;
    _translationScrollStart = 0;
    _translationScrollDelta = 0;
    _translationReveal.value = 0;
    _translationFramePending = false;
    _lyrics = lyrics;
    _lineKeys = List.generate(lyrics.lines.length, (_) => GlobalKey());
    final lines = lyrics.lines;
    _blank = [for (final l in lines) _isBlankWords(l.words)];
    _gapEnd = List<int?>.filled(lines.length, null);
    int? next;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (_blank[i]) {
        _gapEnd[i] = next;
      } else {
        next = lines[i].startTimeMs;
      }
    }
    _hasIntro =
        lines.isNotEmpty &&
        !_blank[0] &&
        lines[0].startTimeMs >=
            (widget.appleMusicStyle
                ? AppleMusicMotion.minimumGapMs
                : _minIntroMs);
    _activeIndex = _indexFor(_lookupMs);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToActive(animate: false),
    );
  }

  void _onTranslation() {
    if (!mounted) return;
    final lines = _translationIsCurrent ? _translation.lines : null;
    if (lines != null) _visibleTranslations = lines;
    final target = lines == null ? 0.0 : 1.0;
    setState(() {});
    if (target == _translationTarget &&
        (_translationReveal.isAnimating ||
            _translationReveal.value == target)) {
      return;
    }
    _animateTranslationTo(target);
  }

  void _animateTranslationTo(double target) {
    _translationTarget = target;
    _translationScrollStart = _translationReveal.value;
    final position = _scroll.hasClients ? _scroll.position : null;
    _translationScrollDelta = position == null
        ? 0
        : (_activeScrollTarget() ?? position.pixels) - position.pixels;
    if (!_browsing && position is ScrollPositionWithSingleContext) {
      position.goIdle();
    }
    _translationReveal.animateTo(
      target,
      duration: context.motion(_scrollDuration),
      curve: _scrollCurve,
    );
  }

  void _onTranslationFrame() {
    if (!mounted) return;
    setState(() {
      _translationFramePending = true;
      if (_translationTarget == 0 && _translationReveal.value == 0) {
        _visibleTranslations = null;
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    if (tickerEnabled != _tickerEnabled) {
      _tickerEnabled = tickerEnabled;
      _onVisibilityChanged();
    }
    if (context.reduceMotion && _translationReveal.isAnimating) {
      _translationReveal.value = _translationTarget;
    }
    if (context.reduceMotion) _move.value = 1;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _onVisibilityChanged();
  }

  void _onVisibilityChanged() {
    if (!widget.appleMusicStyle) return;
    if (!_interactionActive) {
      _browseTimer?.cancel();
      // A system interruption or covered route can lose the final pointer event.
      _touches.clear();
      _userScrolling = false;
      _pendingAnchor = true;
      _move.stop();
      final position = _scroll.hasClients ? _scroll.position : null;
      if (position is ScrollPositionWithSingleContext) position.goIdle();
      return;
    }
    if (_browsing) {
      // Resuming a paused app need not produce a frame; timing is independent
      // of layout and must not wait indefinitely for one.
      _scheduleBrowseResume();
    } else if (_pendingAnchor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollToActive();
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _releasePointer(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointerUp(event.pointer);
    }
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.uri != widget.track.uri) {
      _lyrics = null;
      // The toolbar listens above this widget. Configure after the frame so a
      // cached track change cannot notify that ancestor during its build.
      _load();
    }
  }

  /// 对焦行：前奏阶段（尚未唱到第一句，_activeIndex 为 -1）对焦第一句，
  /// 保证任何时刻（包括暂停、刚打开）都有一句清晰地停在中间。
  static bool _isBlankWords(String words) {
    final t = words.trim();
    return t.isEmpty || t == '♪';
  }

  /// 正在进行的无人声片段（显示呼吸点）；不在其中时为 null。
  _Gap? get _currentGap {
    if (!_isSynced || _blank.isEmpty) return null;
    final lines = _lyrics!.lines;
    final index = widget.appleMusicStyle ? _indexFor(_rawMs) : _activeIndex;
    _Gap? gap;
    if (index < 0) {
      if (_blank[0] && _gapEnd[0] != null) {
        gap = _Gap(0, 0, _gapEnd[0]!);
      } else if (_hasIntro) {
        gap = _Gap(-1, 0, lines[0].startTimeMs);
      }
    } else if (_blank[index] && _gapEnd[index] != null) {
      // 连续多个空行算同一段间奏，由第一个空行显示呼吸点
      var head = index;
      while (head > 0 && _blank[head - 1]) {
        head--;
      }
      gap = _Gap(
        head,
        head == 0 ? 0 : lines[head].startTimeMs,
        _gapEnd[index]!,
      );
    }
    if (gap == null) return null;
    if (widget.appleMusicStyle && _rawMs >= gap.endMs - 300) return null;
    final minMs = widget.appleMusicStyle
        ? AppleMusicMotion.minimumGapMs
        : gap.entry < 0
        ? _minIntroMs
        : _minGapMs;
    return gap.endMs - gap.startMs >= minMs ? gap : null;
  }

  /// 对焦项：呼吸点所在项（-1 为前奏）或当前行。前奏阶段没有呼吸点时对焦第一句；
  /// 落在不显示呼吸点的空行（短间奏 / 歌曲末尾）时停在上一句有词的歌词。
  int _focusEntryFor(_Gap? gap) {
    if (gap != null) {
      if (widget.appleMusicStyle && _rawMs >= gap.endMs - 1300) {
        for (var i = gap.entry + 1; i < _blank.length; i++) {
          if (!_blank[i]) return i;
        }
      }
      return gap.entry;
    }
    if (_activeIndex < 0) return 0;
    if (_activeIndex < _blank.length && _blank[_activeIndex]) {
      for (var i = _activeIndex - 1; i >= 0; i--) {
        if (!_blank[i]) return i;
      }
    }
    return _activeIndex;
  }

  /// 对焦行顶端的纵坐标：按用户偏好定位在未被控件遮挡的区域内。
  double get _focusTopY => widget.appleMusicStyle
      ? math.max(widget.topInset, _viewportHeight * .08 - 2)
      : (widget.topInset +
                (_viewportHeight - widget.topInset - widget.bottomInset).clamp(
                      0.0,
                      double.infinity,
                    ) *
                    _style.lyricsFocusPosition)
            .clamp(0.0, _viewportHeight);

  /// 最后一个 startTimeMs <= ms 的行；在第一行之前返回 -1。
  int _indexFor(int ms) {
    final lines = _lyrics?.lines ?? const <LyricLine>[];
    var lo = 0, hi = lines.length - 1, result = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].startTimeMs <= ms) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  void _onPosition() {
    if (!_isSynced) return;
    final index = _indexFor(_lookupMs);
    final oldIndex = _activeIndex;
    _activeIndex = index;
    final focus = _focusEntryFor(_currentGap);
    final gap = _currentGap?.entry;
    final focusChanged = focus != _renderedFocus;
    final gapChanged = gap != _renderedGap;
    if (index == oldIndex &&
        (!widget.appleMusicStyle || (!focusChanged && !gapChanged))) {
      return;
    }
    final before = widget.appleMusicStyle && focusChanged
        ? _captureRows()
        : null;
    // The gap's visual exit and the lyric's early focus are one transition.
    // Removing the now-invisible spacer only changes layout; compensate during
    // that layout, without restarting the running per-row cascade.
    if (widget.appleMusicStyle && gapChanged && !focusChanged) {
      _gapReflowPending = true;
    }
    setState(() => _activeIndex = index);
    if (!_browsing && (!widget.appleMusicStyle || focusChanged)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_translationReveal.isAnimating) {
          _animateTranslationTo(_translationTarget);
        } else {
          _scrollToActive(before: before);
        }
      });
    }
  }

  RenderBox? _boxOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize ? box : null;
  }

  double? _activeScrollTarget() {
    if (!mounted || _lineKeys.isEmpty || _viewportHeight <= 0) return null;
    // 只滚歌词自己的滚动区：静态的 Scrollable.ensureVisible 会沿嵌套滚动容器一路向外滚
    // （右栏详情 ListView 会跟着歌词切行整体滑动），这里只改本滚动区的 position。
    final position = _scroll.hasClients ? _scroll.position : null;
    if (position == null || !position.hasContentDimensions) return null;
    final focus = _focusEntryFor(_currentGap);
    final box = _boxOf(
      focus < 0 ? _introKey : _lineKeys[focus.clamp(0, _lineKeys.length - 1)],
    );
    if (box == null) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;

    // 对焦项之上正在收起的呼吸点：收起动画与滚动同步进行，结束后对焦项会上移它当前的高度，
    // 目标位置预先扣掉，动画全程平滑、终点准确
    var collapsing = 0.0;
    if (focus >= 0 && !widget.appleMusicStyle) {
      final first = _offsetOf(viewport, _lineKeys.first);
      final intro = _offsetOf(viewport, _introKey);
      if (first != null && intro != null) collapsing += first - intro;
      for (var i = 0; i < focus; i++) {
        if (_blank[i]) {
          final start = _offsetOf(viewport, _lineKeys[i]);
          final end = _offsetOf(viewport, _lineKeys[i + 1]);
          if (start != null && end != null) collapsing += end - start;
        }
      }
    }

    final reveal = viewport.getOffsetToReveal(box, 0, rect: Rect.zero).offset;
    return math.max(position.minScrollExtent, reveal - _focusTopY - collapsing);
  }

  double? _offsetOf(RenderAbstractViewport viewport, GlobalKey key) {
    final box = _boxOf(key);
    return box == null
        ? null
        : viewport.getOffsetToReveal(box, 0, rect: Rect.zero).offset;
  }

  double? _translationLayoutTarget() {
    if (!_translationFramePending && !_gapReflowPending) return null;
    _translationFramePending = false;
    _gapReflowPending = false;
    if (!mounted || _browsing || !_isSynced) return null;
    if (widget.appleMusicStyle &&
        (!_interactionActive || _touches.isNotEmpty || _userScrolling)) {
      _pendingAnchor = true;
      return null;
    }
    final target = _activeScrollTarget();
    if (target == null) return null;
    final distance = _translationTarget - _translationScrollStart;
    final progress = distance == 0
        ? 1.0
        : ((_translationReveal.value - _translationScrollStart) / distance)
              .clamp(0.0, 1.0);
    return target - _translationScrollDelta * (1 - progress);
  }

  void _scrollToActive({bool animate = true, Map<int, double>? before}) {
    if (!mounted) return;
    if (widget.appleMusicStyle && !_isSynced) return;
    if (widget.appleMusicStyle &&
        (!_interactionActive ||
            _touches.isNotEmpty ||
            _userScrolling ||
            _browsing)) {
      _pendingAnchor = true;
      return;
    }
    final target = _activeScrollTarget();
    if (target == null) return;
    final position = _scroll.position;
    if (widget.appleMusicStyle) {
      final bounded = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      final delta = bounded - position.pixels;
      final snapshots = before ?? _captureRows();
      _moveFocus = _focusEntryFor(_currentGap);
      final offsets = <int, double>{};
      for (var i = -1; i < _lineKeys.length; i++) {
        final box = _boxOf(i < 0 ? _introKey : _lineKeys[i]);
        if (box != null && snapshots.containsKey(i)) {
          offsets[i] =
              snapshots[i]! - (box.localToGlobal(Offset.zero).dy - delta);
        }
      }
      _moveOffsets = offsets;
      position.jumpTo(bounded);
      _pendingAnchor = false;
      if (animate && !context.reduceMotion) {
        _move.forward(from: 0);
      } else {
        _move.value = 1;
      }
      return;
    }
    if ((target - position.pixels).abs() < 0.5) return;
    if (animate && !context.reduceMotion) {
      position.animateTo(
        target,
        duration: _scrollDuration,
        curve: _scrollCurve,
      );
    } else {
      position.jumpTo(target);
    }
  }

  /// Start browsing only for user input, but wait for the entire ballistic
  /// scroll to end before starting the inactivity countdown.
  bool _onScrollNotification(ScrollNotification n) {
    if (!_isSynced || n.depth != 0) return false;
    if (widget.appleMusicStyle) {
      if ((n is ScrollStartNotification && n.dragDetails != null) ||
          (n is UserScrollNotification &&
              n.direction != ScrollDirection.idle)) {
        _browseTimer?.cancel();
        _userScrolling = true;
        _move.stop();
        if (!_browsing) setState(() => _browsing = true);
      } else if (n is ScrollEndNotification) {
        _userScrolling = false;
        if (_browsing) {
          // ScrollEnd is dispatched just before isScrollingNotifier becomes
          // false. Run after that update even when no other frame is pending.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scheduleBrowseResume(),
          );
          WidgetsBinding.instance.ensureVisualUpdate();
        }
      }
      return false;
    }
    if (n is! UserScrollNotification) return false;
    _browseTimer?.cancel();
    if (!_browsing) setState(() => _browsing = true);
    _browseTimer = Timer(_browseHold, _endBrowsing);
    return false;
  }

  void _scheduleBrowseResume() {
    if (!mounted) return;
    _browseTimer?.cancel();
    if (!_interactionActive ||
        !_browsing ||
        _touches.isNotEmpty ||
        _userScrolling) {
      return;
    }
    if (_scroll.hasClients && _scroll.position.isScrollingNotifier.value) {
      return;
    }
    _browseTimer = Timer(_appleBrowseHold, _endBrowsing);
  }

  void _pointerUp(int pointer) {
    if (!_touches.remove(pointer)) return;
    if (_touches.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_browsing) {
          _scheduleBrowseResume();
        } else if (_pendingAnchor) {
          _scrollToActive();
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _endBrowsing() {
    if (!mounted) return;
    if (widget.appleMusicStyle &&
        (!_interactionActive ||
            _touches.isNotEmpty ||
            _userScrolling ||
            (_scroll.hasClients &&
                _scroll.position.isScrollingNotifier.value))) {
      return;
    }
    setState(() => _browsing = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
  }

  void _seekToLine(LyricLine line) {
    _browseTimer?.cancel();
    _seek(Duration(milliseconds: line.startTimeMs));
    if (_browsing) setState(() => _browsing = false);
    if (widget.appleMusicStyle) {
      _pendingAnchor = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_releasePointer);
    _translation.removeListener(_onTranslation);
    if (_ownsTranslation) _translation.dispose();
    _browseTimer?.cancel();
    _position.removeListener(_onPosition);
    _translationReveal.dispose();
    _move.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = widget.remote
        ? context.select<ConnectProvider, bool>(
            (provider) => provider.player.isAudible,
          )
        : context.select<PlaybackProvider, bool>(
            (provider) => provider.isPlaying && !provider.isBuffering,
          );
    final style = context.select<PreferencesProvider?, AppPreferences>(
      (p) => p?.prefs ?? AppPreferences.defaults,
    );
    // 样式或停靠位置改变后，重新定位当前行。
    if (style.lyricsScale != _style.lyricsScale ||
        style.lyricsAlign != _style.lyricsAlign ||
        style.lyricsFocusPosition != _style.lyricsFocusPosition ||
        style.lyricsBilingual != _style.lyricsBilingual) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToActive(animate: false),
      );
    }
    _style = style;
    final target = Localizations.localeOf(context).toLanguageTag();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final translationNeedsSync = !_translationIsCurrent;
        _translationLyrics = _lyrics;
        _translationTrackUri = widget.track.uri;
        _translation.configure(
          _lyrics,
          style,
          target,
          query: LyricsQuery.fromTrack(widget.track),
        );
        // The shared controller can outlive this view and configure() is a
        // no-op for cached lyrics. Restore its current state after a remount
        // or reload without waiting for another translation notification.
        if (translationNeedsSync) _onTranslation();
      }
    });
    // 歌词缓存被清空或这首歌被要求重新获取：回到加载态重新取
    final generation = context.select<SpotifyProvider, int>(
      (s) => s.lyricsGeneration,
    );
    if (generation != _generation) {
      _lyrics = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_load);
      });
      _generation = generation;
    }
    final lyrics = _lyrics;
    if (lyrics == null) return _LoadingLines(topInset: widget.topInset);
    if (lyrics.lines.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(
          top: widget.topInset,
          bottom: widget.bottomInset,
        ),
        child: Center(
          child: EmptyState(
            icon: Icons.lyrics_outlined,
            title: context.l10n.lyricsUnavailableTitle,
            message: context.l10n.lyricsUnavailableMessage,
            onDark: true,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 窗口尺寸变化后按相同比例重新定位当前行。
        if (constraints.maxHeight != _viewportHeight) {
          _viewportHeight = constraints.maxHeight;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToActive(animate: false),
          );
        }
        return _buildLines(lyrics, isPlaying);
      },
    );
  }

  Widget _buildLines(SpotifyLyrics lyrics, bool isPlaying) {
    final focusY = _focusTopY;
    final centered = _style.lyricsAlign == LyricsAlign.center;
    final fontSize =
        (widget.appleMusicStyle ? 30 : widget.fontSize) * _style.lyricsScale;
    final lines = lyrics.lines;

    // 同步歌词：空行不再显示「• • •」文字，只有正在进行的那段无人声显示呼吸点，其余收起；
    // 模糊层级按「可见的行」计算，收起的空行不占一级
    final gap = _currentGap;
    final focus = _focusEntryFor(gap);
    _renderedFocus = focus;
    _renderedGap = gap?.entry;
    final rank = List<int>.filled(lines.length, 0);
    var visible = gap?.entry == -1 ? 1 : 0;
    for (var i = 0; i < lines.length; i++) {
      rank[i] = visible;
      if (!(_isSynced && _blank[i] && i != gap?.entry)) visible++;
    }
    final focusRank = focus < 0 ? 0 : rank[focus];

    return Listener(
      onPointerDown: widget.appleMusicStyle
          ? (event) {
              _touches.add(event.pointer);
              _browseTimer?.cancel();
            }
          : null,
      onPointerUp: widget.appleMusicStyle
          ? (event) => _pointerUp(event.pointer)
          : null,
      onPointerCancel: widget.appleMusicStyle
          ? (event) => _pointerUp(event.pointer)
          : null,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: ShaderMask(
          // 上下边缘柔和淡出，歌词像从玻璃下方浮现
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => widget.appleMusicStyle
              ? _appleEdgeFade(rect)
              : const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: [0.0, 0.14, 0.82, 1.0],
                ).createShader(rect),
          // 滚动条只在用户手动浏览时出现，跟随播放的自动滚动不显示
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              colors: widget.appleMusicStyle
                  ? const [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ]
                  : const [
                      Colors.black,
                      Colors.black,
                      Colors.black,
                      Colors.black,
                    ],
              stops: const [0, .01, .99, 1],
            ).createShader(rect),
            child: RawScrollbar(
              controller: _scroll,
              thumbColor: Colors.white38,
              thickness: 5,
              radius: const Radius.circular(3),
              notificationPredicate: (n) => n.depth == 0 && _browsing,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  controller: _scroll,
                  physics: const BouncingScrollPhysics(),
                  // 上下留出到对焦位置的距离，第一句和最后一句也能停在对焦位置
                  padding: EdgeInsets.fromLTRB(
                    widget.appleMusicStyle ? 32 : widget.horizontalPadding,
                    focusY,
                    widget.appleMusicStyle ? 32 : widget.horizontalPadding,
                    _viewportHeight - focusY,
                  ),
                  child: Column(
                    crossAxisAlignment: centered
                        ? CrossAxisAlignment.center
                        : CrossAxisAlignment.start,
                    children: [
                      if (!_isSynced)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            context.l10n.lyricsUnsynced,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (_isSynced)
                        KeyedSubtree(
                          key: _introKey,
                          child: _movingRow(
                            -1,
                            _gapEntry(
                              gap?.entry == -1 ? gap : null,
                              fontSize,
                              centered,
                              isPlaying: isPlaying,
                            ),
                          ),
                        ),
                      for (var i = 0; i < lyrics.lines.length; i++)
                        if (_isSynced && _blank[i])
                          KeyedSubtree(
                            key: _lineKeys[i],
                            child: _movingRow(
                              i,
                              _gapEntry(
                                gap?.entry == i ? gap : null,
                                fontSize,
                                centered,
                                isPlaying: isPlaying,
                              ),
                            ),
                          )
                        else
                          RepaintBoundary(
                            key: _lineKeys[i],
                            child: _movingRow(
                              i,
                              LyricLineView(
                                appleMusicStyle: widget.appleMusicStyle,
                                text: lyrics.lines[i].words,
                                translation: _translationIsCurrent
                                    ? _visibleTranslations?.elementAtOrNull(i)
                                    : null,
                                translationProgress: _translationReveal.value,
                                fontSize: fontSize,
                                centered: centered,
                                blurScale: _style.lyricsBlur,
                                // 以对焦行为中心：当句清晰，上下句按行距逐级模糊
                                distance: _isSynced ? rank[i] - focusRank : 0,
                                focusAll: !_isSynced || _browsing,
                                cursor: widget.lineCursor,
                                onTap: _isSynced
                                    ? () => _seekToLine(lyrics.lines[i])
                                    : null,
                              ),
                            ),
                          ),
                      if (lyrics.provider == LyricsProvider.lrclib ||
                          (_translationIsCurrent && _translation.fromLrclib))
                        Padding(
                          padding: const EdgeInsets.only(top: 28),
                          child: Text(
                            context.l10n.lyricsFromLrclib,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (_translationIsCurrent &&
                          (_translation.fromNetease ||
                              _translation.fromQqMusic))
                        Padding(
                          padding: const EdgeInsets.only(top: 28),
                          child: Text(
                            _translation.fromQqMusic
                                ? context.l10n.lyricsTranslationFromQqMusic
                                : context.l10n.lyricsTranslationFromNetease,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Shader _appleEdgeFade(Rect rect) {
    final controlTop = (1 - widget.bottomInset / math.max(1, rect.height))
        .clamp(.07, 1.0);
    final fadeStart = math.max(.07, controlTop - .2775);
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [
        Colors.transparent,
        Colors.black,
        Colors.black,
        Color(0x0D000000),
        Colors.transparent,
        Colors.transparent,
      ],
      stops: [
        0,
        .07,
        fadeStart,
        fadeStart + (controlTop - fadeStart) * (.24 / .2775),
        controlTop,
        1,
      ],
    ).createShader(rect);
  }

  Widget _movingRow(int index, Widget child) => !widget.appleMusicStyle
      ? child
      : AnimatedBuilder(
          animation: _move,
          child: child,
          builder: (_, child) => Transform.translate(
            offset: Offset(0, _moveOffset(index)),
            child: child,
          ),
        );

  /// 无人声片段占位：[gap] 非空时展开显示呼吸点，否则收起为零高度。
  /// 展开 / 收起与切行滚动同时长同曲线，配合 [_scrollToActive] 的收起补偿保持位置连贯。
  Widget _gapEntry(
    _Gap? gap,
    double fontSize,
    bool centered, {
    required bool isPlaying,
  }) {
    final child = gap == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: EdgeInsets.symmetric(vertical: fontSize * 0.4),
            child: SizedBox(
              width: double.infinity,
              height: fontSize * 1.3,
              child: Align(
                alignment: centered
                    ? Alignment.center
                    : AlignmentDirectional.centerStart,
                child: BreathingDots(
                  appleMusicStyle: widget.appleMusicStyle,
                  key: ValueKey(gap.startMs),
                  position: _position,
                  isPlaying: isPlaying,
                  leadMs: widget.appleMusicStyle
                      ? (widget.remote ? _style.remoteLyricsLeadMs : 0)
                      : _lookupMs - _position.value.inMilliseconds,
                  startMs: gap.startMs,
                  endMs: gap.endMs,
                  dotSize: widget.appleMusicStyle ? 10 : fontSize * 0.4,
                  centered: centered,
                ),
              ),
            ),
          );
    if (widget.appleMusicStyle) return child;
    return AnimatedSize(
      duration: context.motion(_scrollDuration),
      curve: _scrollCurve,
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}

/// 一段无人声片段：[entry] 为显示呼吸点的行（-1 为第一句之前的前奏）。
@immutable
class _Gap {
  final int entry;
  final int startMs;
  final int endMs;

  const _Gap(this.entry, this.startMs, this.endMs);
}

class _LyricsScrollController extends ScrollController {
  final double? Function() reflowTarget;

  _LyricsScrollController({required this.reflowTarget});

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _LyricsScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    reflowTarget: reflowTarget,
  );
}

class _LyricsScrollPosition extends ScrollPositionWithSingleContext {
  final double? Function() reflowTarget;

  _LyricsScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    required this.reflowTarget,
  });

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final target = reflowTarget();
    if (target != null && hasPixels) {
      final corrected = target.clamp(minScrollExtent, maxScrollExtent);
      if (corrected != pixels) correctBy(corrected - pixels);
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// 歌词加载中的骨架（白色半透明横条，适配深色流动背景）。
class _LoadingLines extends StatelessWidget {
  final double topInset;

  const _LoadingLines({required this.topInset});

  static const List<double> _widths = [0.82, 0.64, 0.9, 0.48, 0.74, 0.58];

  @override
  Widget build(BuildContext context) {
    // 不可滚动的 ScrollView：窗口很矮时直接裁掉多余骨架，而不是溢出报错
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(28, topInset + 24, 28, 0),
      child: SkeletonPulse(
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final w in _widths)
                Container(
                  width: constraints.maxWidth * w,
                  height: 26,
                  margin: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
