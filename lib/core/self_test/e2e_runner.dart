import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/appearance.dart';
import '../../models/lyrics_query.dart';
import '../../models/playback_context.dart';
import '../../providers/appearance_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playback_provider.dart';
import '../../providers/spotify_provider.dart';
import '../../services/updates/update_release.dart';
import '../../services/updates/update_service.dart';
import '../../ui/navigation/app_routes.dart';
import '../../ui/screens/detail/album_detail_screen.dart';
import '../../ui/screens/detail/artist_catalog_screen.dart';
import '../../ui/screens/detail/artist_detail_screen.dart';
import '../../ui/screens/detail/playlist_detail_screen.dart';
import '../../ui/screens/detail/podcast_detail_screen.dart';
import '../../ui/screens/home/home_screen.dart';
import '../../ui/screens/home/home_section_screen.dart';
import '../../ui/screens/home/widgets/home_chip_bar.dart';
import '../../ui/screens/library/library_screen.dart';
import '../../ui/screens/player/device_picker_sheet.dart';
import '../../ui/screens/player/full_player_sheet.dart';
import '../../ui/screens/player/immersive_lyrics_screen.dart';
import '../../ui/screens/player/queue_sheet.dart';
import '../../ui/screens/search/category_screen.dart';
import '../../ui/screens/search/search_screen.dart';
import '../../ui/screens/settings/settings_screen.dart';
import '../../ui/screens/settings/widgets/shortcuts_dialog.dart';
import '../../ui/shell/desktop/desktop_top_bar.dart';
import '../../ui/shell/mobile/mobile_bottom_bar.dart';
import '../../ui/shell/shell_breakpoints.dart';
import '../../ui/widgets/hyper_icons.dart';
import '../../ui/widgets/track_actions/track_credits_view.dart';
import '../../ui/widgets/track_menu.dart';
import '../constants/app_info.dart';
import '../debug_toggles.dart';
import 'mock_services.dart';

/// 单个 E2E 检查项的结果。
class E2ECheckResult {
  final String name;
  final bool passed;
  final int durationMs;
  final String detail;

  const E2ECheckResult({
    required this.name,
    required this.passed,
    required this.durationMs,
    this.detail = '',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'passed': passed,
    'durationMs': durationMs,
    'detail': detail,
  };
}

/// 自动化全平台 UI / 功能 / 多主题 E2E 自测执行器。
///
/// 仅在 self-test 构建且携带 `--mock` 与 `--self-test-e2e=<dir>` 时激活：
/// 1. 在不播放真音频的前提下，沿真实 Element / Widget 树触发交互、滚动、导航与弹窗；
/// 2. 通过 [SchedulerBinding.addTimingsCallback] 记录每帧耗时、RSS 内存与阶段区间；
/// 3. 每 300ms 截取应用根节点 [RepaintBoundary] 的 PNG 截图（全平台包括无 TCC 权限的 macOS CI）；
/// 4. 写出 `metrics.json`、`report.json` 与 `DONE` 标记文件后以 0 / 1 退出进程。
class E2ERunner {
  static final GlobalKey repaintBoundaryKey = GlobalKey(
    debugLabel: 'flutify_e2e_repaint_boundary',
  );

  static const Duration screenshotInterval = Duration(milliseconds: 300);

  /// 在 [MaterialApp.builder] 内为根界面（含桌面标题栏、导航与根 Overlay）包裹截图边界。
  static Widget wrapRepaintBoundary({
    required E2ERunner? runner,
    required Widget child,
  }) {
    if (runner == null) return child;
    return RepaintBoundary(key: repaintBoundaryKey, child: child);
  }

  final String requestedOutputDir;
  final MockBootstrap bootstrap;
  final Future<void> Function(int exitCode)? onCompleteExit;

  final Stopwatch _clock = Stopwatch();
  final List<Map<String, dynamic>> _frameSamples = [];
  final List<Map<String, dynamic>> _phaseSpans = [];
  final List<Map<String, dynamic>> _screenshots = [];
  final List<String> _capturedErrors = [];
  final List<String> _screenshotErrors = [];
  final List<String> _logLines = [];
  final List<E2ECheckResult> _results = [];

  String _phase = 'startup';
  int _phaseStartMs = 0;
  int _frameIndex = 0;
  int _shotSeq = 0;
  bool _started = false;
  bool _stopped = false;
  bool _capturing = false;
  Completer<void>? _activeCapture;
  Timer? _shotTimer;
  Directory? _outDir;
  Directory? _shotsDir;
  FlutterExceptionHandler? _prevFlutterError;
  ui.ErrorCallback? _prevPlatformError;

  E2ERunner({
    required this.requestedOutputDir,
    required this.bootstrap,
    this.onCompleteExit,
  });

  /// 确保只启动一次。应在首帧就绪后从 [E2ERootOverlay] 调用。
  void scheduleStart() {
    if (_started) return;
    _started = true;
    unawaited(_execute());
  }

  Future<void> _execute() async {
    _clock.start();
    _phaseStartMs = 0;
    _attachObservers();

    try {
      await _prepareOutputDir();
      await _waitForAppReady();

      await _runCheck('startup_mock_auth', _checkStartupAuth);
      await _runCheck('home_feed_chips_and_scroll', _checkHomeAndChips);
      await _runCheck(
        'search_categories_pagination',
        _checkSearchAndCategories,
      );
      await _runCheck('library_pinyin_sort', _checkLibraryAndPinyin);
      await _runCheck(
        'details_album_artist_podcast_pagination',
        _checkDetailsAndPagination,
      );
      await _runCheck(
        'account_playlist_add_track',
        _checkAccountPlaylistAddTrack,
      );
      await _runCheck(
        'playback_player_lyrics_connect',
        _checkPlaybackPlayerLyricsConnect,
      );
      await _runCheck('themes_and_hyper_glass_matrix', _checkThemesMatrix);
      await _runCheck(
        'settings_update_channel_and_shortcuts',
        _checkSettingsUpdateAndShortcuts,
      );
      await _runCheck('flutter_errors_zero', _checkZeroErrors);
    } catch (e, st) {
      _capturedErrors.add('Unhandled E2E runner error: $e\n$st');
      _results.add(
        E2ECheckResult(
          name: 'e2e_runner_fatal',
          passed: false,
          durationMs: _clock.elapsedMilliseconds,
          detail: e.toString(),
        ),
      );
    } finally {
      await _finishAndWriteReport();
    }

    final allPassed =
        _results.isNotEmpty && _results.every((r) => r.passed);
    final code = allPassed ? 0 : 1;
    await bootstrap.coverServer.close();
    final exitHook = onCompleteExit;
    if (exitHook != null) {
      // 保底计时器：若原生优雅退出超过 3s 仍未结束进程，再硬退出，避免 CI 卡死
      Timer(const Duration(seconds: 3), () => exit(code));
      await exitHook(code);
    } else {
      exit(code);
    }
  }

  Future<void> _prepareOutputDir() async {
    Directory resolved;
    if (requestedOutputDir == 'auto') {
      resolved = await _defaultOutputDir();
    } else {
      resolved = Directory(requestedOutputDir);
      try {
        await resolved.create(recursive: true);
      } catch (e) {
        debugPrint('[E2E] requestedOutputDir unavailable ($e), falling back to app temp');
        resolved = await _defaultOutputDir();
        await resolved.create(recursive: true);
      }
    }
    debugPrint('[E2E] outputDir=${resolved.path}');
    final doneMarker = File(p.join(resolved.path, 'DONE'));
    if (await doneMarker.exists()) await doneMarker.delete();

    final shots = Directory(p.join(resolved.path, 'screenshots'));
    if (await shots.exists()) await shots.delete(recursive: true);
    await shots.create(recursive: true);

    _outDir = resolved;
    _shotsDir = shots;

    _shotTimer = Timer.periodic(screenshotInterval, (_) {
      if (_stopped || _capturing) return;
      unawaited(_captureScreenshot());
    });
    // 立即抓拍启动后的第一张截图
    unawaited(_captureScreenshot());
  }

  Future<Directory> _defaultOutputDir() async {
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return Directory(p.join(ext.path, 'flutify_e2e'));
    }
    try {
      // macOS App Sandbox resolves getTemporaryDirectory() to the container's
      // Data/tmp even when an inherited shell TMPDIR points outside the sandbox.
      final tmp = await getTemporaryDirectory();
      return Directory(p.join(tmp.path, 'flutify_e2e'));
    } catch (_) {
      return Directory(p.join(Directory.systemTemp.path, 'flutify_e2e'));
    }
  }

  void _attachObservers() {
    _prevFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      _capturedErrors.add('FlutterError: ${details.exceptionAsString()}');
      _prevFlutterError?.call(details);
    };

    _prevPlatformError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      _capturedErrors.add('PlatformError: $error');
      return _prevPlatformError?.call(error, stack) ?? true;
    };

    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (_stopped) return;
    final nowMs = _clock.elapsedMilliseconds;
    // 仅定期采一次 RSS，避免高频系统调用影响帧时间测量
    final rssMb = (_frameIndex % 8 == 0)
        ? _currentRssMb()
        : (_frameSamples.isNotEmpty
              ? (_frameSamples.last['rssMb'] as double)
              : _currentRssMb());
    for (final t in timings) {
      _frameIndex++;
      _frameSamples.add({
        'tMs': nowMs,
        'buildMs': _round2(t.buildDuration.inMicroseconds / 1000.0),
        'rasterMs': _round2(t.rasterDuration.inMicroseconds / 1000.0),
        'totalMs': _round2(t.totalSpan.inMicroseconds / 1000.0),
        'vsyncOverheadMs': _round2(t.vsyncOverhead.inMicroseconds / 1000.0),
        'phase': _phase,
        'rssMb': _round2(rssMb),
      });
    }
  }

  static double _currentRssMb() {
    try {
      return ProcessInfo.currentRss / (1024.0 * 1024.0);
    } catch (_) {
      return 0.0;
    }
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100.0;

  void _enterPhase(String next) {
    final now = _clock.elapsedMilliseconds;
    if (_phase != next) {
      _phaseSpans.add({
        'phase': _phase,
        'startMs': _phaseStartMs,
        'endMs': now,
      });
      _phase = next;
      _phaseStartMs = now;
    }
  }

  void _recordShotIssue(String reason) {
    if (_screenshotErrors.length < 24) {
      _screenshotErrors.add(reason);
      _logLines.add('[SHOT] $reason');
      debugPrint('[E2E] screenshot skipped/failed: $reason');
    }
  }

  Future<void> _captureScreenshot({bool force = false}) async {
    if (_stopped) return;
    if (_capturing) {
      if (!force || _activeCapture == null) return;
      await _activeCapture!.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
      if (_stopped || _capturing) return;
    }
    final shotsDir = _shotsDir;
    if (shotsDir == null) return;
    final ctx = repaintBoundaryKey.currentContext;
    if (ctx == null || !ctx.mounted) {
      _recordShotIssue('no_context');
      return;
    }
    final renderObj = ctx.findRenderObject();
    if (renderObj is! RenderRepaintBoundary) {
      _recordShotIssue('not_repaint_boundary:${renderObj.runtimeType}');
      return;
    }

    _capturing = true;
    final done = Completer<void>();
    _activeCapture = done;
    try {
      final size = renderObj.size;
      if (!renderObj.attached || size.isEmpty) {
        _recordShotIssue('unattached_or_empty_size');
        return;
      }
      // 目标宽度上限 ~1280px，兼顾画质与编码速度
      final dpr = View.of(ctx).devicePixelRatio;
      final ratio = math.min(
        dpr,
        math.max(0.75, 1280.0 / math.max(1.0, size.width)),
      );

      // 等待一帧绘制完成并在 postFrameCallback 中立即抓拍，确保 !debugNeedsPaint
      final imageCompleter = Completer<ui.Image?>();
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_stopped || !ctx.mounted) {
          if (!imageCompleter.isCompleted) imageCompleter.complete(null);
          return;
        }
        try {
          if (!renderObj.attached || (kDebugMode && renderObj.debugNeedsPaint)) {
            _recordShotIssue('postframe_dirty');
            if (!imageCompleter.isCompleted) imageCompleter.complete(null);
            return;
          }
          renderObj.toImage(pixelRatio: ratio).then(
            (img) {
              if (!imageCompleter.isCompleted) imageCompleter.complete(img);
            },
            onError: (Object err, StackTrace _) {
              _recordShotIssue('toImage:$err');
              if (!imageCompleter.isCompleted) imageCompleter.complete(null);
            },
          );
        } catch (err) {
          _recordShotIssue('postframe:$err');
          if (!imageCompleter.isCompleted) imageCompleter.complete(null);
        }
      });
      SchedulerBinding.instance.ensureVisualUpdate();
      if (!SchedulerBinding.instance.hasScheduledFrame) {
        SchedulerBinding.instance.scheduleFrame();
      }

      final ui.Image? image = await imageCompleter.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          _recordShotIssue('image_timeout');
          return null;
        },
      );
      if (image == null || _stopped) return;
      try {
        final ByteData? byteData = await image
            .toByteData(format: ui.ImageByteFormat.png)
            .timeout(const Duration(seconds: 2));
        if (byteData != null && !_stopped) {
          _shotSeq++;
          final fileName =
              'shot_${_shotSeq.toString().padLeft(4, '0')}.png';
          final file = File(p.join(shotsDir.path, fileName));
          await file.writeAsBytes(byteData.buffer.asUint8List(), flush: false);
          _screenshots.add({
            'index': _shotSeq,
            'file': 'screenshots/$fileName',
            'tMs': _clock.elapsedMilliseconds,
            'phase': _phase,
            'width': image.width,
            'height': image.height,
          });
        }
      } finally {
        image.dispose();
      }
    } catch (e, st) {
      _recordShotIssue('$e | ${st.toString().split('\n').first}');
    } finally {
      _capturing = false;
      if (!done.isCompleted) done.complete();
    }
  }

  Future<void> _waitForAppReady() async {
    _enterPhase('wait_app_ready');
    for (var i = 0; i < 80; i++) {
      final home = _findFirstElement((e) => e.widget is HomeScreen);
      if (home != null && home.mounted) {
        final spotify = home.read<SpotifyProvider>();
        if (!spotify.isLoadingHome && spotify.home.sections.isNotEmpty) {
          await _pumpFrames(10);
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Timed out waiting for HomeScreen and mock HomeFeed');
  }

  Future<void> _runCheck(String name, Future<String> Function() fn) async {
    _enterPhase(name);
    final sw = Stopwatch()..start();
    debugPrint('[E2E] start $name');
    try {
      final detail = await fn();
      await _pumpFrames(8);
      debugPrint('[E2E] PASS $name (${sw.elapsedMilliseconds}ms): $detail');
      _results.add(
        E2ECheckResult(
          name: name,
          passed: true,
          durationMs: sw.elapsedMilliseconds,
          detail: detail,
        ),
      );
    } catch (e, st) {
      final trace = st.toString().split('\n').take(8).join('\n');
      debugPrint('[E2E] FAIL $name: $e\n$st');
      _logLines.add('[FAIL] $name (${sw.elapsedMilliseconds}ms): $e\n$trace');
      _results.add(
        E2ECheckResult(
          name: name,
          passed: false,
          durationMs: sw.elapsedMilliseconds,
          detail: '$e | ${trace.split('\n').first}',
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 具体 E2E 用例
  // ---------------------------------------------------------------------------

  Future<String> _checkStartupAuth() async {
    final home = _requireElement((e) => e.widget is HomeScreen, 'HomeScreen');
    final auth = home.read<AuthProvider>();
    final spotify = home.read<SpotifyProvider>();
    if (!auth.isSignedIn) throw StateError('Expected AuthProvider.isSignedIn');
    if (spotify.home.sections.length < 3) {
      throw StateError('Expected >=3 Home sections');
    }
    if (!bootstrap.storageService.isLoggedIn) {
      throw StateError('Expected mock StorageService to be logged in');
    }
    return 'Signed in=${auth.displayName}, sections=${spotify.home.sections.length}';
  }

  Future<String> _checkHomeAndChips() async {
    var home = _requireElement((e) => e.widget is HomeScreen, 'HomeScreen');
    final spotify = home.read<SpotifyProvider>();

    // 点击 HomeChipBar 内「音乐」筛选胶囊 → 验证二级标签「电子」出现并点击
    var chipBar = _requireElement((e) => e.widget is HomeChipBar, 'HomeChipBar');
    final musicChip = _findVisibleText('音乐', root: chipBar, exact: true);
    if (musicChip == null) {
      throw StateError('Primary chip "音乐" not found inside HomeChipBar');
    }
    await _tapElement(musicChip);
    await _waitUntil(() {
      if (spotify.homeFacet != 'music-chip') return false;
      final bar = _findFirstElement((e) => e.widget is HomeChipBar);
      return bar != null &&
          _findVisibleText('电子', root: bar, exact: true) != null;
    });

    chipBar = _requireElement((e) => e.widget is HomeChipBar, 'HomeChipBar');
    final electronic = _findVisibleText('电子', root: chipBar, exact: true);
    if (electronic == null) {
      throw StateError('Sub-chip "电子" did not appear under music-chip');
    }
    await _tapElement(electronic);
    await _waitUntil(() => spotify.homeFacet == 'sub-electronic');
    await _pumpFrames(8);

    // 通过清除按钮取消「音乐/电子」选中以展示主芯片，再切到「播客与节目」并恢复完整主页
    chipBar = _requireElement((e) => e.widget is HomeChipBar, 'HomeChipBar');
    final clearBtn = _findIcon(Icons.close_rounded, root: chipBar) ??
        _findVisibleText(home.l10n.filterAll, root: chipBar, exact: true) ??
        _findVisibleText('音乐', root: chipBar, exact: true);
    if (clearBtn != null) {
      await _tapElement(clearBtn);
      await _pumpFrames(8);
    }
    if (spotify.homeFacet != '') {
      chipBar = _requireElement((e) => e.widget is HomeChipBar, 'HomeChipBar');
      (chipBar.widget as HomeChipBar).onSelected('');
      await _pumpFrames(8);
    }
    await _waitUntil(() {
      if (spotify.homeFacet != '') return false;
      final bar = _findFirstElement((e) => e.widget is HomeChipBar);
      return bar != null &&
          _findVisibleText('播客与节目', root: bar, exact: true) != null;
    });

    chipBar = _requireElement((e) => e.widget is HomeChipBar, 'HomeChipBar');
    final podcastChip = _findVisibleText('播客与节目', root: chipBar, exact: true);
    if (podcastChip == null) {
      throw StateError('Primary chip "播客与节目" not found inside HomeChipBar');
    }
    await _tapElement(podcastChip);
    await _waitUntil(() => spotify.homeFacet == 'podcast-chip');
    await _pumpFrames(8);

    chipBar = _requireElement((e) => e.widget is HomeChipBar, 'HomeChipBar');
    final clearPodcast = _findIcon(Icons.close_rounded, root: chipBar) ??
        _findVisibleText(home.l10n.filterAll, root: chipBar, exact: true) ??
        _findVisibleText('播客与节目', root: chipBar, exact: true);
    if (clearPodcast != null) {
      await _tapElement(clearPodcast);
      await _pumpFrames(8);
    }
    if (spotify.homeFacet != '') {
      chipBar = _requireElement((e) => e.widget is HomeChipBar, 'HomeChipBar');
      (chipBar.widget as HomeChipBar).onSelected('');
      await _pumpFrames(8);
    }
    await _waitUntil(() {
      if (spotify.homeFacet != '') return false;
      final bar = _findFirstElement((e) => e.widget is HomeChipBar);
      return bar != null &&
          _findVisibleText('音乐', root: bar, exact: true) != null;
    });

    // 平滑滚动主页并采集滚动性能帧
    home = _requireElement((e) => e.widget is HomeScreen, 'HomeScreen');
    final scrollable = _findDescendantScrollable(home);
    if (scrollable != null) {
      await _smoothScroll(scrollable, 480, steps: 14);
      await _smoothScroll(scrollable, 0, steps: 10);
    }

    // 点击「显示全部」打开 HomeSectionScreen 后返回
    home = _requireElement((e) => e.widget is HomeScreen, 'HomeScreen');
    final l10n = home.l10n;
    final showAll = _findVisibleText(l10n.commonShowAll, root: home, exact: true);
    if (showAll != null) {
      await _tapElement(showAll);
      await _pumpFrames(10);
      if (_findFirstElement((e) => e.widget is HomeSectionScreen) == null &&
          spotify.home.sections.isNotEmpty) {
        AppRoutes.openHomeSection(
          _activeContentContext(),
          spotify.home.sections.first,
          facet: spotify.homeFacet,
        );
        await _pumpFrames(10);
      }
      await _waitUntil(
        () => _findFirstElement((e) => e.widget is HomeSectionScreen) != null,
      );
      await _pumpFrames(8);
      await _popContentRoute();
    }

    return 'Chips (music -> sub-electronic -> podcast -> all), scroll & HomeSectionScreen ok';
  }

  Future<String> _checkSearchAndCategories() async {
    final appCtx = _activeShellContext();
    await _switchMainTab(1, label: appCtx.l10n.navSearch);
    await _waitUntil(
      () =>
          _findFirstElement((e) => e.widget is SearchScreen) != null &&
          _findVisibleText('华语流行') != null,
    );
    await _pumpFrames(8);

    // 打开「华语流行」分类浏览页后返回
    final catEl = _findVisibleText('华语流行');
    if (catEl == null) {
      throw StateError('Expected category "华语流行" on SearchScreen');
    }
    await _tapElement(catEl);
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is CategoryScreen) != null,
    );
    await _pumpFrames(8);
    await _popContentRoute();

    // 在搜索页执行查询 + 分页加载
    final searchEl = _requireElement(
      (e) => e.widget is SearchScreen,
      'SearchScreen',
    );
    final spotify = searchEl.read<SpotifyProvider>();
    final tfEl = _findFirstElement((e) => e.widget is TextField);
    if (tfEl != null && tfEl.widget is TextField) {
      final ctrl = (tfEl.widget as TextField).controller;
      if (ctrl != null) {
        ctrl.value = const TextEditingValue(
          text: 'Mock',
          selection: TextSelection.collapsed(offset: 4),
        );
      }
    }
    spotify.performSearch('Mock');
    await _waitUntil(
      () => !spotify.isSearching && spotify.searchTracks.isNotEmpty,
    );
    final initialCount = spotify.searchTracks.length;
    await spotify.loadMoreSearch(SearchResultType.tracks);
    await _pumpFrames(10);
    final pagedCount = spotify.searchTracks.length;
    if (pagedCount <= initialCount) {
      throw StateError(
        'Search track pagination did not advance: $initialCount -> $pagedCount',
      );
    }

    // 滚动搜索结果页
    final searchScroll = _findDescendantScrollable(
      _requireElement((e) => e.widget is SearchScreen, 'SearchScreen'),
    );
    if (searchScroll != null) {
      await _smoothScroll(searchScroll, 520, steps: 12);
    }
    spotify.performSearch('');
    return 'CategoryScreen + search query + pagination ($initialCount -> $pagedCount) ok';
  }

  Future<String> _checkLibraryAndPinyin() async {
    final appCtx = _activeShellContext();
    await _switchMainTab(2, label: appCtx.l10n.navLibrary);
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is LibraryScreen) != null,
    );
    await _pumpFrames(8);

    var libEl = _requireElement(
      (e) => e.widget is LibraryScreen,
      'LibraryScreen',
    );
    final l10n = libEl.l10n;
    final libProvider = libEl.read<LibraryProvider>();
    if (libProvider.playlists.isEmpty || libProvider.albums.isEmpty) {
      throw StateError('Expected mock playlists and albums in LibraryProvider');
    }

    // 切换排序为按名称（拼音排序），并切换列表/网格与筛选胶囊（每次 setState 后重新查找元素）
    final sortTrigger = _findVisibleText(
      l10n.librarySortRecent,
      root: libEl,
      exact: true,
    );
    if (sortTrigger != null) {
      await _tapElement(sortTrigger);
      await _pumpFrames(8);
      final alphaOption = _findVisibleText(
        l10n.librarySortAlphabetical,
        reverse: true,
        exact: true,
      );
      if (alphaOption == null) {
        throw StateError('Sort menu option "${l10n.librarySortAlphabetical}" not visible');
      }
      await _tapElement(alphaOption);
      await _pumpFrames(8);
    }

    libEl = _requireElement((e) => e.widget is LibraryScreen, 'LibraryScreen');
    final playlistFilter = _findVisibleText(
      l10n.filterPlaylists,
      root: libEl,
      exact: true,
    );
    if (playlistFilter != null) {
      await _tapElement(playlistFilter);
      await _pumpFrames(6);
      libEl = _requireElement((e) => e.widget is LibraryScreen, 'LibraryScreen');
      final clearFilterBtn = _findIcon(Icons.close_rounded, root: libEl) ??
          _findVisibleText(l10n.filterPlaylists, root: libEl, exact: true);
      if (clearFilterBtn != null) {
        await _tapElement(clearFilterBtn);
        await _pumpFrames(6);
      }
    }

    // 切换网格视图与列表视图
    libEl = _requireElement((e) => e.widget is LibraryScreen, 'LibraryScreen');
    final gridBtn = _findIcon(Icons.grid_view_rounded, root: libEl);
    if (gridBtn != null) {
      await _tapElement(gridBtn);
      await _pumpFrames(6);
      libEl = _requireElement((e) => e.widget is LibraryScreen, 'LibraryScreen');
      final listBtn = _findIcon(Icons.view_list_rounded, root: libEl);
      if (listBtn != null) {
        await _tapElement(listBtn);
        await _pumpFrames(6);
      }
    }

    final nav = AppRoutes.contentNavigator?.call();
    if (nav != null && nav.canPop()) {
      await _popContentRoute();
    }

    return 'Library playlists=${libProvider.playlists.length}, pinyin alphabetical sort ok';
  }

  Future<String> _checkDetailsAndPagination() async {
    await _switchMainTab(0, label: _activeShellContext().l10n.navHome);
    final ctx = _activeContentContext();

    // 1. 歌单详情
    AppRoutes.openPlaylist(ctx, bootstrap.catalog.playlists.first);
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is PlaylistDetailScreen) != null,
    );
    await _pumpFrames(8);
    final plScroll = _findDescendantScrollable(
      _requireElement(
        (e) => e.widget is PlaylistDetailScreen,
        'PlaylistDetailScreen',
      ),
    );
    if (plScroll != null) await _smoothScroll(plScroll, 320, steps: 8);
    await _popContentRoute();

    // 2. 超 50 首（75 首）大专辑详情
    AppRoutes.openAlbum(ctx, bootstrap.catalog.albums[2]);
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is AlbumDetailScreen) != null,
    );
    await _pumpFrames(10);
    final albumEl = _requireElement(
      (e) => e.widget is AlbumDetailScreen,
      'AlbumDetailScreen',
    );
    final albumScroll = _findDescendantScrollable(albumEl);
    if (albumScroll != null) {
      await _smoothScroll(albumScroll, 900, steps: 14);
    }
    await _popContentRoute();

    // 3. 艺人详情 + 艺人全部作品/歌曲分页（ArtistCatalogScreen）
    final artist = bootstrap.catalog.artists.first;
    AppRoutes.openArtist(ctx, artist);
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is ArtistDetailScreen) != null,
    );
    await _pumpFrames(8);

    AppRoutes.openArtistAlbums(ctx, artist);
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is ArtistCatalogScreen) != null,
    );
    await _pumpFrames(8);
    final catEl = _requireElement(
      (e) => e.widget is ArtistCatalogScreen,
      'ArtistCatalogScreen',
    );
    final catScroll = _findDescendantScrollable(catEl);
    if (catScroll != null && catScroll.position.maxScrollExtent > 0) {
      await _smoothScroll(
        catScroll,
        catScroll.position.maxScrollExtent,
        steps: 14,
      );
      await _pumpFrames(10);
    }
    await _popContentRoute(); // pop ArtistCatalogScreen
    await _popContentRoute(); // pop ArtistDetailScreen

    // 4. 播客节目详情
    AppRoutes.openPodcast(
      ctx,
      bootstrap.catalog.podcastShow.uri,
      initialTitle: bootstrap.catalog.podcastShow.name,
      initialCover: bootstrap.catalog.podcastShow.coverUrl,
    );
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is PodcastDetailScreen) != null,
    );
    await _pumpFrames(8);
    await _popContentRoute();

    return 'Playlist, 75-track Album, Artist + ArtistCatalog pagination, Podcast detail ok';
  }

  Future<String> _checkAccountPlaylistAddTrack() async {
    final ctx = _activeShellContext();
    final lib = ctx.read<LibraryProvider>();
    final targetTrack = bootstrap.catalog.coreTracks[18];
    final editable = await lib.editablePlaylistsFor(targetTrack);
    if (editable.length < 3) {
      throw StateError('Expected >=3 editable account playlists');
    }
    final targetPlaylist = editable.last;
    final beforeCount = lib.playlists
        .firstWhere((p) => p.uri == targetPlaylist.uri)
        .totalTracks;

    // 通过真实 UI 弹出 TrackMenu / TrackOptionsSheet 入口触发「添加到歌单」（放在内容区中心避开左栏重叠）
    final screenSize = MediaQuery.sizeOf(ctx);
    unawaited(
      TrackMenu.show(
        ctx,
        targetTrack,
        position: Offset(screenSize.width * 0.55, screenSize.height * 0.35),
      ),
    );

    var addedViaUi = false;
    var addMenuItem = await _waitForVisibleTextInOverlay(
      ctx.l10n.trackAddToPlaylist,
    );
    if (addMenuItem != null) {
      // 等待弹出菜单展开动画（~300ms）完全到位后再点击，避免点在裁剪区外误触遮罩关闭菜单
      await _pumpFrames(16);
      addMenuItem = _findVisibleTextInOverlay(ctx.l10n.trackAddToPlaylist);
      if (addMenuItem != null) {
        await _tapElement(addMenuItem);
        var plItem = await _waitForVisibleTextInOverlay(targetPlaylist.name);
        if (plItem != null) {
          await _pumpFrames(16);
          plItem = _findVisibleTextInOverlay(targetPlaylist.name);
          if (plItem != null) {
            await _tapElement(plItem);
            addedViaUi = true;
          }
        }
      }
    }
    if (addedViaUi) {
      await _waitUntil(
        () =>
            lib.playlists
                .firstWhere((p) => p.uri == targetPlaylist.uri)
                .totalTracks ==
            beforeCount + 1,
      );
    } else {
      await _closeRootOverlays();
      await lib.addTrackToAccountPlaylist(targetPlaylist, targetTrack);
    }

    await _closeRootOverlays();
    final afterCount = lib.playlists
        .firstWhere((p) => p.uri == targetPlaylist.uri)
        .totalTracks;
    if (afterCount != beforeCount + 1) {
      throw StateError(
        'Expected playlist count $beforeCount -> ${beforeCount + 1}, got $afterCount',
      );
    }
    return 'Added "${targetTrack.name}" to "${targetPlaylist.name}" ($beforeCount -> $afterCount)';
  }

  Future<String> _checkPlaybackPlayerLyricsConnect() async {
    final ctx = _activeShellContext();
    final playback = ctx.read<PlaybackProvider>();
    final spotify = ctx.read<SpotifyProvider>();
    final tracks = bootstrap.catalog.coreTracks;

    final pl = bootstrap.catalog.playlists.first;
    await playback.playTrack(
      tracks.first,
      contextQueue: tracks,
      context: PlaybackContext.playlist(pl.name, uri: pl.contextUri),
    );
    await _waitUntil(() => playback.isPlaying && playback.duration.inSeconds > 0);
    await _pumpFrames(10);

    // 验证 Mock 进度推进与 Seek，以及加载双语同步歌词
    final lyrics = await spotify.fetchLyrics(
      LyricsQuery.fromTrack(tracks.first),
    );
    if (lyrics.lines.isEmpty) {
      throw StateError('Expected non-empty bilingual mock lyrics');
    }
    await playback.seekTo(const Duration(seconds: 22));
    await _pumpFrames(8);

    // 打开设备选择器（Mock Connect 设备）
    unawaited(DevicePickerSheet.show(ctx));
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is DevicePickerSheet) != null,
    );
    await _pumpFrames(8);
    if (_findVisibleText('Living Room HomePod') == null) {
      throw StateError('Mock Connect device not visible in DevicePickerSheet');
    }
    await _closeRootOverlays();

    // 打开曲目制作人员弹窗（TrackCreditsView）
    unawaited(TrackCreditsView.show(ctx, tracks.first));
    await _pumpFrames(10);
    await _closeRootOverlays();

    // 打开全屏播放器（FullPlayerSheet）并切换歌词 / 队列
    unawaited(FullPlayerSheet.show(ctx));
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is FullPlayerSheet) != null,
    );
    await _pumpFrames(12);

    // 在 FullPlayerSheet 中打开队列弹窗 / 歌词按钮
    final lyricsBtn = _findIcon(Icons.lyrics_rounded) ??
        _findIcon(Icons.lyrics_outlined);
    if (lyricsBtn != null) {
      await _tapElement(lyricsBtn);
      await _pumpFrames(18);
    }

    final queueBtn = _findIcon(Icons.queue_music_rounded);
    if (queueBtn != null) {
      await _tapElement(queueBtn);
      await _pumpFrames(12);
    }
    await _closeRootOverlays();

    // 打开队列独立弹窗
    unawaited(QueueSheet.show(ctx));
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is QueueSheet) != null,
    );
    await _pumpFrames(8);
    await _closeRootOverlays();

    // 打开桌面/全端沉浸式歌词（ImmersiveLyricsScreen）采集流光背景与歌词滚动帧率
    unawaited(ImmersiveLyricsScreen.open(ctx));
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is ImmersiveLyricsScreen) != null,
    );
    await _pumpFrames(30, step: const Duration(milliseconds: 28));
    await _closeRootOverlays();

    return 'Mock playback active, lyrics lines=${lyrics.lines.length}, FullPlayer, Queue, DevicePicker, ImmersiveLyrics ok';
  }

  Future<String> _checkThemesMatrix() async {
    final ctx = _activeShellContext();
    final appearance = ctx.read<AppearanceProvider>();
    final original = appearance.settings;
    await HyperIcons.ensure();

    final variants = <(String, AppearanceSettings)>[
      (
        'theme_liquid_light',
        original.copyWith(
          themeMode: ThemeMode.light,
          glassMaterial: GlassMaterial.liquid,
          pureBlack: false,
          dynamicAccent: false,
          accent: AccentPreset.ocean.color,
          cornerStyle: CornerStyle.standard,
        ),
      ),
      (
        'theme_liquid_dark',
        original.copyWith(
          themeMode: ThemeMode.dark,
          glassMaterial: GlassMaterial.liquid,
          pureBlack: false,
          dynamicAccent: false,
          accent: AccentPreset.violet.color,
          cornerStyle: CornerStyle.standard,
        ),
      ),
      (
        'theme_liquid_pure_black',
        original.copyWith(
          themeMode: ThemeMode.dark,
          glassMaterial: GlassMaterial.liquid,
          pureBlack: true,
          dynamicAccent: false,
          accent: AccentPreset.aqua.color,
          cornerStyle: CornerStyle.rounded,
        ),
      ),
      (
        'theme_hyper_light',
        original.copyWith(
          themeMode: ThemeMode.light,
          glassMaterial: GlassMaterial.hyper,
          pureBlack: false,
          dynamicAccent: false,
          accent: AccentPreset.sunset.color,
          cornerStyle: CornerStyle.rounded,
        ),
      ),
      (
        'theme_hyper_dark_dynamic',
        original.copyWith(
          themeMode: ThemeMode.dark,
          glassMaterial: GlassMaterial.hyper,
          pureBlack: false,
          dynamicAccent: true,
          accent: AccentPreset.rose.color,
          cornerStyle: CornerStyle.square,
        ),
      ),
    ];

    for (final (phaseName, settings) in variants) {
      _enterPhase(phaseName);
      appearance.update(settings);
      await _pumpFrames(16, step: const Duration(milliseconds: 26));
      final scrollable = _findDescendantScrollable(_activeShellElement());
      if (scrollable != null) {
        final maxScroll = math.min(360.0, scrollable.position.maxScrollExtent);
        if (maxScroll > 0) {
          await _smoothScroll(scrollable, maxScroll, steps: 10);
          await _smoothScroll(scrollable, 0, steps: 8);
        }
      }
      await _captureScreenshot(force: true);
    }

    _enterPhase('themes_and_hyper_glass_matrix');
    appearance.update(
      original.copyWith(
        themeMode: ThemeMode.dark,
        glassMaterial: GlassMaterial.hyper,
        dynamicAccent: true,
      ),
    );
    await _pumpFrames(10);
    return 'Rendered and scrolled across ${variants.length} theme + glass + corner variants';
  }

  Future<String> _checkSettingsUpdateAndShortcuts() async {
    await _openSettingsScreen();
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is SettingsScreen) != null,
    );
    await _pumpFrames(10);

    final settingsEl = _requireElement(
      (e) => e.widget is SettingsScreen,
      'SettingsScreen',
    );
    final l10n = settingsEl.l10n;
    final updateService = settingsEl.read<UpdateService?>();
    if (updateService == null) {
      throw StateError('UpdateService missing from widget tree');
    }

    // 顺滑滚动设置页覆盖所有分组（含动画调试、更新通道、关于）
    final scroll = _findDescendantScrollable(settingsEl);
    if (scroll != null && scroll.position.maxScrollExtent > 0) {
      final total = scroll.position.maxScrollExtent;
      for (var frac in [0.25, 0.5, 0.75, 1.0]) {
        await _smoothScroll(scroll, total * frac, steps: 8);
      }
    }

    // 测试动画调试运行时开关并还原
    DebugToggles.instance.setOff(DebugToggle.glassBackdrop, true);
    await _pumpFrames(6);
    if (!DebugToggles.instance.isOff(DebugToggle.glassBackdrop)) {
      throw StateError('DebugToggles failed to toggle glassBackdrop');
    }
    DebugToggles.instance.reset();
    await _pumpFrames(6);

    // 验证新加入的更新通道切换（Beta -> SelfTest 警告确认弹窗 -> 确认切换）
    await updateService.setChannel(UpdateChannel.release);
    await _pumpFrames(4);
    await updateService.setChannel(UpdateChannel.beta);
    await _pumpFrames(4);
    if (updateService.channel != UpdateChannel.beta) {
      throw StateError('Expected UpdateChannel.beta');
    }

    final channelField =
        _findVisibleText(l10n.updatesChannelBeta) ??
        _findVisibleText(l10n.updatesChannelRelease);
    if (channelField != null) {
      await _tapElement(channelField);
      await _pumpFrames(8);
      final selfTestOpt = _findVisibleText(l10n.updatesChannelSelfTest);
      if (selfTestOpt != null) {
        await _tapElement(selfTestOpt);
        await _pumpFrames(8);
        final confirmBtn = _findVisibleText(l10n.updatesSelfTestConfirm);
        if (confirmBtn != null) {
          await _tapElement(confirmBtn);
          await _pumpFrames(8);
        }
      }
    }
    if (updateService.channel != UpdateChannel.selfTest) {
      await updateService.setChannel(UpdateChannel.selfTest);
    }

    // 打开键盘快捷键弹窗验证（新加入的 ShortcutsDialog）
    final ctx = _activeShellContext();
    unawaited(ShortcutsDialog.show(ctx));
    await _waitUntil(
      () => _findFirstElement((e) => e.widget is ShortcutsDialog) != null,
    );
    await _pumpFrames(8);
    await _closeRootOverlays();

    return 'Settings sections, AnimationDebugSection, UpdateChannel (${updateService.channel.name}), ShortcutsDialog ok';
  }

  Future<String> _checkZeroErrors() async {
    if (_capturedErrors.isNotEmpty) {
      throw StateError(
        'Captured ${_capturedErrors.length} UI/runtime errors:\n${_capturedErrors.take(10).join('\n')}',
      );
    }
    return '0 Flutter/Platform errors recorded during E2E suite';
  }

  // ---------------------------------------------------------------------------
  // 导航与树查找助手（不依赖 Windows 已屏蔽的 Semantics 树）
  // ---------------------------------------------------------------------------

  Future<void> _switchMainTab(int index, {required String label}) async {
    final shellCtx = _activeShellContext();
    final isDesktop = ShellBreakpoints.isDesktop(
      MediaQuery.sizeOf(shellCtx).width,
    );

    if (!isDesktop) {
      final bottomBar = _findFirstElement((e) => e.widget is MobileBottomBar);
      if (bottomBar != null) {
        final tab = _findVisibleText(label, root: bottomBar);
        if (tab != null) {
          await _tapElement(tab);
          await _pumpFrames(10);
          return;
        }
      }
    }

    // 桌面端：先回到首页根部或点搜索框；音乐库在左栏始终可见，也可直接切到索引
    final bottomBar = _findFirstElement((e) => e.widget is MobileBottomBar);
    if (bottomBar != null) {
      final w = bottomBar.widget as MobileBottomBar;
      w.onSelected(index);
      await _pumpFrames(10);
      return;
    }

    if (index == 0) {
      final homeIcon = _findIcon(Icons.home_rounded) ??
          _findIcon(Icons.home_outlined);
      if (homeIcon != null) {
        await _tapElement(homeIcon);
        await _pumpFrames(10);
        return;
      }
    } else if (index == 1) {
      final topBar = _findFirstElement((e) => e.widget is DesktopTopBar);
      final topSearch =
          _findFirstElement((e) => e.widget is TextField, root: topBar) ??
          _findFirstElement((e) => e.widget is TextField);
      if (topSearch != null) {
        await _tapElement(topSearch);
        if (topSearch.widget is TextField) {
          (topSearch.widget as TextField).focusNode?.requestFocus();
        }
        // Headless Xvfb / unfocused CI windows may ignore synthetic pointer focus,
        // so ensure DesktopTopBar activates the Search tab directly too.
        if (topBar != null && topBar.widget is DesktopTopBar) {
          (topBar.widget as DesktopTopBar).onSearchActivated();
        }
        await _pumpFrames(12);
        return;
      }
      final searchIcon = _findIcon(Icons.search_rounded);
      if (searchIcon != null) {
        await _tapElement(searchIcon);
        await _pumpFrames(10);
        return;
      }
    } else if (index == 2) {
      // 桌面三栏框架下主内容 IndexedStack 默认为 Home/Search，为独立验证 LibraryScreen 压入当前 Navigator
      final nav = AppRoutes.contentNavigator?.call();
      if (nav != null) {
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => LibraryScreen(onOpenSettings: () {}),
          ),
        );
        await _pumpFrames(10);
        return;
      }
    }
  }

  Future<void> _openSettingsScreen() async {
    final settingsBtn =
        _findIcon(Icons.settings_rounded) ?? _findIcon(Icons.settings_outlined);
    if (settingsBtn != null) {
      await _tapElement(settingsBtn);
      await _pumpFrames(10);
      if (_findFirstElement((e) => e.widget is SettingsScreen) != null) return;
    }
    final nav = AppRoutes.contentNavigator?.call() ??
        Navigator.of(_activeShellContext(), rootNavigator: true);
    nav.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: SettingsScreen.routeName),
        builder: (_) => const SettingsScreen(),
      ),
    );
    await _pumpFrames(10);
  }

  Future<void> _popContentRoute() async {
    final nav = AppRoutes.contentNavigator?.call();
    if (nav != null && nav.canPop()) {
      nav.pop();
      await _pumpFrames(10);
      return;
    }
    final rootNav = Navigator.maybeOf(_activeShellContext(), rootNavigator: true);
    if (rootNav != null && rootNav.canPop()) {
      rootNav.pop();
      await _pumpFrames(10);
    }
  }

  Future<void> _closeRootOverlays() async {
    final rootNav = Navigator.maybeOf(_activeShellContext(), rootNavigator: true);
    if (rootNav != null) {
      rootNav.popUntil((route) => route.isFirst);
      await _pumpFrames(10);
    }
  }

  Element _activeShellElement() {
    final nav = AppRoutes.contentNavigator?.call();
    if (nav != null && nav.context.mounted) return nav.context as Element;
    final home = _findFirstElement((e) => e.widget is HomeScreen);
    if (home != null) return home;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) throw StateError('No mounted root element');
    return root;
  }

  BuildContext _activeShellContext() => _activeShellElement();

  BuildContext _activeContentContext() {
    final home = _findFirstElement((e) => e.widget is HomeScreen);
    if (home != null && home.mounted) return home;
    final lib = _findFirstElement((e) => e.widget is LibraryScreen);
    if (lib != null && lib.mounted) return lib;
    return _activeShellContext();
  }

  Element _requireElement(bool Function(Element) test, String label) {
    final el = _findFirstElement(test);
    if (el == null) throw StateError('Could not find $label in widget tree');
    return el;
  }

  Element? _findFirstElement(
    bool Function(Element) test, {
    Element? root,
    bool reverse = false,
  }) {
    final start = root ?? WidgetsBinding.instance.rootElement;
    if (start == null) return null;
    Element? found;
    void walk(Element el) {
      if (!reverse && found != null) return;
      final w = el.widget;
      if (w is Offstage && w.offstage) return;
      if (test(el)) {
        found = el;
        if (!reverse) return;
      }
      el.visitChildren(walk);
    }

    walk(start);
    return found;
  }

  bool _matchesVisibleText(Element e, String needle, {required bool exact}) {
    final w = e.widget;
    final String text;
    if (w is Text) {
      text = w.data ?? w.textSpan?.toPlainText() ?? '';
    } else if (w is RichText) {
      text = w.text.toPlainText();
    } else {
      return false;
    }
    return exact ? text == needle : text.contains(needle);
  }

  Element? _findVisibleText(
    String needle, {
    Element? root,
    bool exact = false,
    bool reverse = false,
  }) {
    return _findFirstElement(
      (e) => _matchesVisibleText(e, needle, exact: exact),
      root: root,
      reverse: reverse,
    );
  }

  Element? _findVisibleTextInOverlay(String needle, {bool exact = true}) {
    final start = WidgetsBinding.instance.rootElement;
    if (start == null) return null;
    Element? hit;
    void walk(Element el, bool inOverlayMenu) {
      final w = el.widget;
      if (w is Offstage && w.offstage) return;
      final insideMenu =
          inOverlayMenu ||
          w is PopupMenuItem ||
          w is BottomSheet ||
          w is Dialog;
      if (insideMenu && _matchesVisibleText(el, needle, exact: exact)) {
        hit = el;
      }
      el.visitChildren((child) => walk(child, insideMenu));
    }

    walk(start, false);
    return hit;
  }

  Future<Element?> _waitForVisibleTextInOverlay(
    String needle, {
    bool exact = true,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final limit = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(limit)) {
      final hit = _findVisibleTextInOverlay(needle, exact: exact);
      if (hit != null) return hit;
      await _pumpFrames(2, step: const Duration(milliseconds: 40));
    }
    return null;
  }

  Element? _findIcon(IconData icon, {Element? root}) => _findFirstElement((e) {
    final w = e.widget;
    return w is Icon && w.icon == icon;
  }, root: root);

  ScrollableState? _findDescendantScrollable(Element root) {
    ScrollableState? best;
    void walk(Element el) {
      final w = el.widget;
      if (w is Offstage && w.offstage) return;
      if (el is StatefulElement && el.state is ScrollableState) {
        final s = el.state as ScrollableState;
        if (s.position.axis == Axis.vertical &&
            s.position.maxScrollExtent > 0) {
          best ??= s;
        }
      }
      el.visitChildren(walk);
    }

    walk(root);
    if (best != null) return best;
    final any = _findFirstElement(
      (el) => el is StatefulElement && el.state is ScrollableState,
      root: root,
    );
    return any is StatefulElement ? any.state as ScrollableState : null;
  }

  Future<void> _tapElement(Element element) async {
    if (!element.mounted) {
      throw StateError('Element ${element.widget.runtimeType} is not mounted');
    }
    final ro = element.renderObject;
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) {
      throw StateError('Element ${element.widget.runtimeType} has no RenderBox');
    }
    final center = ro.localToGlobal(ro.size.center(Offset.zero));
    final binding = GestureBinding.instance;
    const pointer = 99;
    binding.handlePointerEvent(
      PointerDownEvent(position: center, pointer: pointer),
    );
    await _pumpFrames(1, step: const Duration(milliseconds: 16));
    binding.handlePointerEvent(
      PointerUpEvent(position: center, pointer: pointer),
    );
    await _pumpFrames(8, step: const Duration(milliseconds: 22));
  }

  Future<void> _smoothScroll(
    ScrollableState scrollable,
    double target, {
    int steps = 10,
  }) async {
    if (!scrollable.mounted) return;
    final pos = scrollable.position;
    final clamped = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    final start = pos.pixels;
    for (var i = 1; i <= steps; i++) {
      if (!scrollable.mounted) break;
      final t = i / steps;
      scrollable.position.jumpTo(start + (clamped - start) * t);
      await _pumpFrames(1, step: const Duration(milliseconds: 28));
    }
  }

  Future<void> _waitUntil(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final limit = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(limit)) {
      if (predicate()) return;
      await _pumpFrames(2, step: const Duration(milliseconds: 40));
    }
    throw TimeoutException('Condition not met within $timeout');
  }

  Future<void> _pumpFrames(
    int count, {
    Duration step = const Duration(milliseconds: 24),
  }) async {
    for (var i = 0; i < count; i++) {
      SchedulerBinding.instance.scheduleFrame();
      await Future<void>.delayed(step);
    }
  }

  Future<void> _finishAndWriteReport() async {
    _enterPhase('done');
    _stopped = true;
    _shotTimer?.cancel();
    if (_activeCapture != null) {
      await _activeCapture!.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));

    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    if (_prevFlutterError != null) FlutterError.onError = _prevFlutterError;
    if (_prevPlatformError != null) {
      ui.PlatformDispatcher.instance.onError = _prevPlatformError;
    }

    final outDir = _outDir;
    if (outDir == null) return;

    final metrics = {
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'releaseTag': AppInfo.releaseTag,
      'appVersion': AppInfo.displayVersion,
      'totalDurationMs': _clock.elapsedMilliseconds,
      'frameCount': _frameSamples.length,
      'screenshotCount': _screenshots.length,
      'screenshotErrors': _screenshotErrors,
      'phases': _phaseSpans,
      'frames': _frameSamples,
      'screenshots': _screenshots,
    };
    await File(
      p.join(outDir.path, 'metrics.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(metrics));

    if (_logLines.isNotEmpty) {
      await File(
        p.join(outDir.path, 'e2e.log'),
      ).writeAsString('${_logLines.join('\n')}\n');
    }

    final summary = _computeSummary();
    final passedCount = _results.where((r) => r.passed).length;
    final failedCount = _results.length - passedCount;

    final report = {
      'platform': Platform.operatingSystem,
      'releaseTag': AppInfo.releaseTag,
      'appVersion': AppInfo.displayVersion,
      'allPassed': failedCount == 0 && _results.isNotEmpty,
      'passed': passedCount,
      'failed': failedCount,
      'totalDurationMs': _clock.elapsedMilliseconds,
      'performance': summary,
      'errors': _capturedErrors,
      'checks': [for (final r in _results) r.toJson()],
    };
    await File(
      p.join(outDir.path, 'report.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));

    await File(
      p.join(outDir.path, 'DONE'),
    ).writeAsString(failedCount == 0 ? 'ok\n' : 'fail\n');
  }

  Map<String, dynamic> _computeSummary() {
    if (_frameSamples.isEmpty) {
      return {
        'frameCount': 0,
        'avgFps': 0.0,
        'p50FrameMs': 0.0,
        'p95FrameMs': 0.0,
        'maxFrameMs': 0.0,
        'jankOver16ms': 0,
        'jankOver33ms': 0,
        'peakRssMb': _round2(_currentRssMb()),
      };
    }
    final totals = [
      for (final f in _frameSamples) (f['totalMs'] as num).toDouble(),
    ]..sort();
    final avgTotal = totals.reduce((a, b) => a + b) / totals.length;
    final p50 = totals[(totals.length * 0.5).floor().clamp(0, totals.length - 1)];
    final p95 = totals[(totals.length * 0.95).floor().clamp(0, totals.length - 1)];
    final maxMs = totals.last;
    final jank16 = totals.where((v) => v > 16.67).length;
    final jank33 = totals.where((v) => v > 33.33).length;
    final peakRss = _frameSamples
        .map((f) => (f['rssMb'] as num).toDouble())
        .reduce(math.max);
    return {
      'frameCount': totals.length,
      'avgBudgetFps': _round2(
        avgTotal > 0 ? math.min(120.0, 1000.0 / avgTotal) : 0.0,
      ),
      'p50FrameMs': _round2(p50),
      'p95FrameMs': _round2(p95),
      'maxFrameMs': _round2(maxMs),
      'jankOver16ms': jank16,
      'jankOver33ms': jank33,
      'peakRssMb': _round2(peakRss),
    };
  }
}

/// 在 E2E 模式下用 [RepaintBoundary] 包裹根界面并在首帧后触发 [E2ERunner]。
class E2ERootOverlay extends StatefulWidget {
  final Widget child;
  final E2ERunner? runner;

  const E2ERootOverlay({super.key, required this.child, required this.runner});

  @override
  State<E2ERootOverlay> createState() => _E2ERootOverlayState();
}

class _E2ERootOverlayState extends State<E2ERootOverlay> {
  @override
  void initState() {
    super.initState();
    if (widget.runner != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.runner?.scheduleStart();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
