import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../../core/rust_core.dart';
import '../../src/rust/api/backend.dart' as rust;
import '../audio/audio_engine.dart';
import 'chrome/linux_chrome.dart';
import 'eme_loopback_server.dart';
import 'eme_page_html.dart';
import 'fairplay.dart';

export 'eme_page_html.dart';

/// EME 播放器：用一个**隐藏 1×1 WebView2**（空白本地页 + HLS.js，不加载任何 Spotify 前端）
/// 做 Widevine 解密 + 播放。性能开销 ≈ 一个空白页 + 一路 AAC 解码，无渲染负担。
///
/// 为什么用 HLS.js 而不是手写 MSE：Spotify 的 fMP4 有「明文 lead-in + 后段加密」结构，
/// 手写 MSE 喂法会让 Chromium 丢失逐样本加密信息（卡在加密边界 9.5s）。HLS.js 是 Web 播放器
/// 同款引擎，按 EXT-X-MAP/BYTERANGE 正确喂段并处理 EME，实测能整曲播放。
///
/// 工作原理：
/// - Dart 在 127.0.0.1 起微型 HTTP 服务（安全上下文），供：页面、HLS.js、本地化的 m3u8、
///   加密 m4a（支持 Range，供 HLS.js 按 BYTERANGE 取段）、license/证书 反代；
/// - 页面用 HLS.js 加载本地 m3u8 → EME 发 license 请求 → 经 Dart 反代到 Spotify → 装钥 → 播放；
/// - 密钥全程不出 CDM；页面零外部网络请求（全部走 127.0.0.1）。
class EmePlayer {
  late final EmeLoopbackServer _loopback = EmeLoopbackServer(
    httpClient: _httpClient,
    isDisposed: () => _disposed,
    playGen: () => _playGen,
    emePageHtml: () => emePageHtml,
    hlsJsSource: () => hlsJsSource,
    localM3u8: () => _localM3u8,
    audioFile: () => _audioFile,
    licensePoster: () => _licensePoster,
    certFetcher: () => _certFetcher,
    fairPlayMode: () => _fairPlayMode,
    onRelayError: (name, error, webSignInSuggested) {
      lastError ??= EmePlaybackException(
        '$name 反代失败：$error',
        webSignInSuggested: webSignInSuggested,
        cause: error,
      );
      _stateController.add(EmePlayerState.error);
    },
  );
  InAppWebViewController? _controller;
  HeadlessInAppWebView? _headless;

  /// Linux：用系统 Chrome（含 Widevine）代替无头 WebView2/WKWebView。
  /// 页面仍是同一个本地 EME 宿主页，通过 CDP 注入的 `flutter_inappwebview` 兼容层通信。
  ChromePage? _chromePage;
  StreamSubscription<String>? _chromeSub;
  Future<void>? _chromeStarting;

  /// 当前这个无头 WebView 的页面加载完成（[_restartWebView] 重建时换新的）。
  Completer<void> _pageReady = Completer<void>();

  /// 等页面加载、等「开始播放」这次 JS 调用的上限。
  static const Duration pageReadyTimeout = Duration(seconds: 15);

  /// 暂停 / 继续 / 跳转 / 音量这类控制命令的上限：切歌前会先 await 暂停，
  /// 页面卡住时绝不能把整个播放器一起挂住。
  static const Duration controlTimeout = Duration(seconds: 3);

  /// Widevine 的 provision URL 由 CDM 提供，只允许官方 provisioning 主机。
  /// 不接受任意 HTTPS URL，避免本地回环服务被滥用成 SSRF 代理。
  static const Set<String> allowedProvisionHosts =
      EmeLoopbackServer.allowedProvisionHosts;

  /// 页面或 JS 调用超时过：页面 JS 卡住了（macOS 无头 WKWebView 没挂上主窗口时会整体冻结）。
  /// 控制命令直接丢弃，下一次 [play] 先重建 WebView。
  bool _webViewStalled = false;

  /// 最近一次设置的音量：每首歌都会新建 audio 元素（默认 1.0），开播时随调用一起下发。
  double _volume = 1.0;

  /// 当前服务的加密音频文件与本地化清单。
  File? _audioFile;
  String? get currentAudioPath => _audioFile?.path;
  Future<void> clearBrowserCache() async {
    final chrome = _chromePage;
    if (chrome != null) {
      try {
        await chrome.cdp.send('Network.clearBrowserCache');
      } catch (_) {}
      return;
    }
    if (_controller == null) return;
    if (Platform.isWindows) {
      await _controller!.callDevToolsProtocolMethod(
        methodName: 'Network.clearBrowserCache',
      );
    } else {
      await InAppWebViewController.clearAllCache();
    }
  }

  String? _localM3u8;

  /// 静态资源（hls.js 与证书）内容，由 [play] 注入。
  static String? hlsJsSource; // hls.min.js 内容（资产，启动时读一次）

  // ---- 播放状态流 ----
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<EmePlayerState>.broadcast();

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<EmePlayerState> get stateStream => _stateController.stream;

  /// 最近一次错误的详情（license 换取失败原因 / HLS.js fatal details 等）。
  /// [play] 时清空；上层（EmeAudioEngine）收到 error 状态事件时读取并上报。
  EmePlaybackException? lastError;

  /// 播放代次：每次 [play] / [serveHlsForNative] 自增。
  /// 反代请求在入口记下代次、页面事件（error 等）携带代次；代次已变说明是上一首的残留
  /// （快速切歌时上一首在途的 license / 证书请求晚到失败），只回 500、不记错误不发 error 状态，
  /// 否则新曲目会被误判失败 / 跳过。
  int _playGen = 0;
  int _intentRevision = 0;
  bool _wantsPlay = false;
  bool _disposed = false;

  /// 当前播放代次（测试用）。
  @visibleForTesting
  int get playGeneration => _playGen;

  /// 开启新一代播放：自增代次并清空上一首的错误。
  void _beginGeneration() {
    _playGen++;
    lastError = null;
  }

  /// 启动探测判定 Widevine / CDM 不可用（页面加载时探测一次）。
  /// 后续播放错误据此归类为「设备缺 Widevine」（重试无意义）。
  bool _widevineUnavailable = false;

  /// 启动探测判定 FairPlay 不可用（同 [play] 传入 fairPlay 时的错误归类）。
  bool _fairPlayUnavailable = false;

  /// 当前曲目是否走 FairPlay（macOS / iOS）：影响清单形态与错误归类。
  bool _fairPlayMode = false;

  /// 测试用：不经 WebView（[play]）切到 FairPlay 的错误归类。
  @visibleForTesting
  set fairPlayModeForTesting(bool value) => _fairPlayMode = value;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration get position => _position;
  Duration get duration => _duration;

  /// license 反代（Dart 代发到 Spotify）。
  Future<Uint8List> Function(Uint8List request)? _licensePoster;
  Future<Uint8List> Function()? _certFetcher;

  /// provision 反代用的共享 HTTP client（遵守全局 HttpOverrides / NetworkProxy）。
  /// 背景：部分设备 Widevine CDM 需 provisioning，但 CDM 自带的 Google
  /// provisioning 地址在用户网络被掐（静默重试、永不返回）——原生播放器的
  /// provision 请求改发到本地回环，由这里经 App 代理策略外发。
  final http.Client _httpClient = http.Client();

  String get _origin => _loopback.origin;

  /// 自定义 WebView2 环境：关闭自动播放手势限制（隐藏页没有用户手势）。
  static Future<WebViewEnvironment?>? _webViewEnvironment;

  /// 已创建的自定义环境（[ensureEnvironment] 完成后可用），供 buildHiddenView 默认使用。
  static WebViewEnvironment? cachedEnvironment;

  /// [ensureEnvironment] 建好环境后的回调（如把同一个环境交给地区检测门控复用）。
  static void Function(WebViewEnvironment? environment)? environmentReady;

  /// Clear the same cookie store used by login and EME, including HttpOnly
  /// cookies. Do not remove CDM data or an external browser's profile.
  static Future<void> clearSessionCookies() async {
    if (Platform.isLinux) {
      await LinuxChromeManager.instance.clearBrowserCookies();
      return;
    }
    final environment = await ensureEnvironment();
    final cleared = await CookieManager.instance(
      webViewEnvironment: environment,
    ).deleteAllCookies();
    // Android's callback reports whether any cookies were removed; false is
    // also the normal result for an already empty store.
    if (!cleared && !Platform.isAndroid) {
      throw StateError('WebView Cookie 清理失败，请重试');
    }
  }

  /// 退出前关闭后台 Chrome（Linux 全曲播放用；未启动时为无操作）。
  static Future<void> disposeExternalBrowser() =>
      LinuxChromeManager.instance.dispose();

  /// WebView2 用户数据目录：默认在 exe 旁边（`Flutify.exe.WebView2`），保持不变以留住已有数据；
  /// 程序装在不可写的目录（如 Program Files）时改放 %LOCALAPPDATA%，否则 WebView 建不起来、
  /// 登录页读不到 cookie。
  static String? _userDataFolder() {
    final dir = File(Platform.resolvedExecutable).parent;
    try {
      final probe = File('${dir.path}${Platform.pathSeparator}.flutify_write_probe');
      probe.writeAsStringSync('');
      probe.deleteSync();
      return null;
    } on FileSystemException {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local == null || local.isEmpty) return null;
      return '$local${Platform.pathSeparator}Flutify${Platform.pathSeparator}WebView2';
    }
  }

  /// 在 runApp 后尽早调用一次（WebView 创建前）。
  static Future<WebViewEnvironment?> ensureEnvironment() {
    return _webViewEnvironment ??= () async {
      if (!Platform.isWindows) return null;
      try {
        final env = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: _userDataFolder(),
            additionalBrowserArguments:
                '--autoplay-policy=no-user-gesture-required '
                '--disable-features=HardwareMediaKeyHandling',
          ),
        );
        cachedEnvironment = env;
        environmentReady?.call(env);
        return env;
      } catch (e) {
        debugPrint('[eme] 自定义 WebView 环境创建失败，用默认环境: $e');
        return null;
      }
    }();
  }

  /// 初始化：起本地 HTTP 服务。必须在 [buildHiddenView] 挂载前 await。
  Future<void> init() => _ensureServer();

  /// 启动无头 WebView2（不进 widget 树 → 窗口缩放/布局切换不影响播放，且零渲染开销）。
  /// 在 [init] 之后调用一次。
  Future<void> start() async {
    // Linux 没有 flutter_inappwebview：改用系统 Chrome（含 Widevine）+ CDP。
    if (Platform.isLinux) return _startChrome();
    if (_headless != null) return;
    // 回调只认自己这一代的页面：重建后旧 WebView 晚到的加载事件不能把新页面标成就绪
    final ready = _pageReady;
    final headless = HeadlessInAppWebView(
      webViewEnvironment: cachedEnvironment,
      initialUrlRequest: URLRequest(url: WebUri('$_origin/eme')),
      initialSettings: InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'emeEvent',
          callback: _onJsEvent,
        );
      },
      // Android WebView：Widevine 需要 App 显式授予「受保护媒体 ID」，否则 requestMediaKeySystemAccess 直接失败。
      // 只放行这一项，其余（摄像头 / 麦克风等）一律拒绝。WebView2 不走这里。
      onPermissionRequest: (_, request) async {
        final drm = request.resources.contains(
          PermissionResourceType.PROTECTED_MEDIA_ID,
        );
        debugPrint(
          '[eme] 权限请求 ${request.resources.map((r) => r.toNativeValue()).join(',')} → ${drm ? '允许' : '拒绝'}',
        );
        return PermissionResponse(
          resources: drm
              ? [PermissionResourceType.PROTECTED_MEDIA_ID]
              : const [],
          action: drm
              ? PermissionResponseAction.GRANT
              : PermissionResponseAction.DENY,
        );
      },
      onLoadStop: (controller, _) {
        if (!ready.isCompleted) ready.complete();
        _live.add(this);
        unawaited(
          _allowOutputSelection(controller).then((_) => _applyOutputLabel()),
        );
      },
      onReceivedError: (_, request, error) {
        if ((request.isForMainFrame ?? true) && !ready.isCompleted) {
          ready.completeError(StateError('EME 页加载失败：${error.description}'));
        }
      },
      onConsoleMessage: (_, msg) {
        if (msg.messageLevel == ConsoleMessageLevel.ERROR) {
          debugPrint('[eme-js] ${msg.message}');
        }
      },
    );
    _headless = headless;
    try {
      await headless.run();
    } catch (_) {
      _headless = null;
      _controller = null;
      try {
        await headless.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  /// Linux：用系统 Chrome 打开本地 EME 宿主页，经 CDP 收发事件与命令。
  Future<void> _startChrome() {
    if (_chromePage != null) return Future.value();
    // 并发调用（初始化 + 重试）合并为一次启动，避免拉起多个 Chrome。
    return _chromeStarting ??=
        _doStartChrome().whenComplete(() => _chromeStarting = null);
  }

  Future<void> _doStartChrome() async {
    debugPrint('[eme] 启动 Chrome EME 宿主：$_origin/eme');
    final ready = _pageReady;
    // 先订阅页面事件再导航，避免漏掉加载期（EME hook / Widevine 探测）的事件。
    final page = await LinuxChromeManager.instance.open(visible: false);
    _chromePage = page;
    await _chromeSub?.cancel();
    _chromeSub = page.emeEvents.listen((payload) => _onJsEvent([payload]));
    try {
      await page.navigate('$_origin/eme');
      await page.loaded.timeout(pageReadyTimeout);
    } catch (e) {
      if (!ready.isCompleted) ready.completeError(e);
      rethrow;
    }
    if (identical(ready, _pageReady) && !ready.isCompleted) ready.complete();
  }

  /// 丢掉卡住的 Chrome 页面重新加载（[play] 发现 [_webViewStalled] 时调用）。
  Future<void> _restartChrome() async {
    final page = _chromePage;
    if (page == null) return _startChrome();
    _pageReady = Completer<void>();
    await page.navigate('$_origin/eme');
    await page.loaded.timeout(pageReadyTimeout, onTimeout: () {});
    if (!_pageReady.isCompleted) _pageReady.complete();
  }

  /// 丢掉卡住的无头 WebView 重新建一个（[play] 发现 [_webViewStalled] 时调用）。
  /// macOS 的无头 WKWebView 只在创建那一刻挂到当时的主窗口下；用户再次点播放时窗口通常已在前台，
  /// 重建就能挂上。旧页面上的 audio 元素随 WebView 一起销毁。
  Future<void> _restartWebView() async {
    if (Platform.isLinux) return _restartChrome();
    final old = _headless;
    _headless = null;
    _controller = null;
    _pageReady = Completer<void>();
    try {
      await old?.dispose();
    } catch (e) {
      debugPrint('[eme] 释放旧 WebView 失败（忽略）: $e');
    }
    await start();
  }

  /// 等当前页面就绪（WebView/Chrome 通用）；超时 / 加载失败都记为卡住，下一次 [play] 重建。
  Future<void> _ensurePageReady() async {
    try {
      await _pageReady.future.timeout(pageReadyTimeout);
    } on TimeoutException {
      _webViewStalled = true;
      throw const EmePlaybackException('全曲播放页面未就绪（页面无响应）');
    } catch (_) {
      _webViewStalled = true;
      rethrow;
    }
  }

  /// 等当前页面就绪并取到 WebView controller；仅 WebView 路径使用。
  Future<InAppWebViewController> _readyController() async {
    await _ensurePageReady();
    final c = _controller;
    if (c == null) {
      _webViewStalled = true;
      throw StateError('EME WebView 未创建');
    }
    return c;
  }

  Future<void> _ensureServer() => _loopback.ensureStarted();

  @visibleForTesting
  static bool isOwnRequest(HttpHeaders headers, int port) =>
      EmeLoopbackServer.isOwnRequest(headers, port);

  @visibleForTesting
  static bool isAllowedProvisionTarget(String raw) =>
      EmeLoopbackServer.isAllowedProvisionTarget(raw);

  static Future<Uint8List> consolidatedBody(HttpRequest request) =>
      EmeLoopbackServer.consolidatedBody(request);

  /// 播放一首协议下载的加密曲目。
  /// [m4a] 加密 fMP4；[m3u8] sneaktables policy=1 原始清单（含 EXT-X-KEY/MAP/BYTERANGE）；
  /// [licensePoster] Dart 代发 license 到 Spotify；[certFetcher] 取 application-certificate。
  /// [fairPlay] 为真（macOS / iOS，见 fairplay.dart 的 useFairPlay）时：清单 KEY 行改写成 skd:// + com.apple.streamingkeydelivery，
  /// 页面按 keySystem `com.apple.fps` 起 EME；licensePoster/certFetcher 须对应 fairplay-license 端点。
  /// [fairPlayFileId] FairPlay 的 FPS content ID（= 该曲目的 file_id，见 fairplay.dart）。
  Future<void> play({
    required File m4a,
    required String m3u8,
    required Future<Uint8List> Function(Uint8List request) licensePoster,
    required Future<Uint8List> Function() certFetcher,
    bool fairPlay = false,
    String? fairPlayFileId,
    bool autoplay = true,
    Duration? initialPosition,
  }) async {
    // 先开新代次（同步、早于任何 await）：此后上一首晚到的反代失败 / 页面错误一律按残留丢弃
    _beginGeneration();
    final gen = _playGen;
    _intentRevision++;
    _wantsPlay = autoplay;
    await _ensureServer();
    if (_disposed || gen != _playGen) return;
    _licensePoster = licensePoster;
    _certFetcher = certFetcher;
    _audioFile = m4a;
    _fairPlayMode = fairPlay;
    _localM3u8 = _localizeM3u8(
      m3u8,
      fairPlay: fairPlay,
      fileIdHex: fairPlayFileId,
    );
    if (_webViewStalled) {
      _webViewStalled = false;
      debugPrint('[eme] 页面上次未响应，重建 WebView/Chrome 页面');
      await _restartWebView();
    }
    await _ensurePageReady();
    if (_disposed || gen != _playGen) return;

    // FairPlay 走 WebKit 原生 HLS + 旧版 EME（webkitneedkey），不走 hls.js/MSE：
    // MSE 路径下系统按样本 KID 要密钥、SPC 的 content ID 也随之变成 KID，Spotify 只认裸 file_id
    //（必 500）；原生 HLS 的密钥请求按清单 skd:// URI 对样本，content ID 由页面自填，两头都对得上。
    final options =
        '$_wantsPlay, $_intentRevision, ${(initialPosition?.inMilliseconds ?? 0) / 1000}';
    final fn = fairPlay
        ? 'emePlayNativeFps($gen, ${jsonEncode(fairPlayFileId)}, $options)'
        : 'emePlayHls(false, $gen, $options)';
    // 音量先行：新建的 audio 元素沿用页面记下的音量，不会以默认的 100% 起播
    final v = await _callAsync('emeSetVolume($_volume); return await $fn;').timeout(
      pageReadyTimeout,
      onTimeout: () {
        _webViewStalled = true;
        throw const EmePlaybackException('全曲播放启动超时（页面 JS 未响应）');
      },
    );
    if (_disposed || gen != _playGen) return;
    debugPrint('[eme] $fn 结果: $v');
    if (v is String && v.startsWith('ERR:')) {
      // 'ERR:NOFPS:'：本机 WebKit 没有播放实际使用的旧版 FairPlay（WebKitMediaKeys），重试无意义
      final noFairPlay = v.startsWith('ERR:NOFPS:');
      if (noFairPlay) _fairPlayUnavailable = true;
      throw EmePlaybackException(
        'EME 播放启动失败：$v',
        isWidevineMissing: noFairPlay,
      );
    }
  }

  /// 把 Spotify 的 HLS 清单本地化：MAP 与分段的 URL 全改指到本地 m4a（保留 BYTERANGE），
  /// EXT-X-KEY（PSSH data URI）原样保留——HLS.js 用它做 EME initData。
  /// [widevineKeyFormat] 为真时把 KEYFORMAT 改写成 Widevine UUID 形式：ExoPlayer 只按
  /// UUID 认 KEYFORMAT；只影响喂给原生播放器的这份清单，WebView/hls.js 路径不受影响。
  /// [fairPlay] 为真时把 KEY 行整体改写成 FairPlay 形态（skd:// + file_id +
  /// KEYFORMAT=com.apple.streamingkeydelivery），file_id 由 [fileIdHex] 传入。
  String _localizeM3u8(
    String m3u8, {
    bool widevineKeyFormat = false,
    bool fairPlay = false,
    String? fileIdHex,
  }) {
    if (RustCore.ready) {
      try {
        return rust.rustLocalizeHlsManifest(
          m3U8: m3u8,
          origin: _origin,
          widevineKeyFormat: widevineKeyFormat,
          fairPlay: fairPlay,
          fileIdHex: fileIdHex,
        );
      } catch (_) {}
    }
    final local = '$_origin/audio/current.m4a';
    final out = <String>[];
    for (final line in m3u8.split('\n')) {
      if (line.startsWith('#EXT-X-MAP:')) {
        // 替换 URI="..." 为本地，保留 BYTERANGE
        out.add(line.replaceAll(RegExp(r'URI="[^"]*"'), 'URI="$local"'));
      } else if (line.startsWith('#EXT-X-KEY:') && fairPlay) {
        if (fileIdHex == null || fileIdHex.isEmpty) {
          throw StateError('FairPlay 清单生成失败：缺 file_id（FPS content ID）');
        }
        out.add(fairPlayKeyLine(fileIdHex));
      } else if (line.startsWith('#EXT-X-KEY:') && widevineKeyFormat) {
        out.add(_withWidevineKeyFormat(line));
      } else if (line.startsWith('http')) {
        out.add(local);
      } else {
        out.add(line);
      }
    }
    return out.join('\n');
  }

  /// Widevine 的 KEYFORMAT UUID（ExoPlayer 按它把 EXT-X-KEY 的 data URI 解析成 PSSH）。
  static const _widevineKeyFormatUuid =
      'urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed';

  /// 把 EXT-X-KEY 行的 KEYFORMAT 改写/补为 Widevine UUID；已是该值则原样返回。
  static String _withWidevineKeyFormat(String line) {
    if (line.contains('KEYFORMAT="$_widevineKeyFormatUuid"')) return line;
    if (line.contains('KEYFORMAT="')) {
      return line.replaceAll(
        RegExp(r'KEYFORMAT="[^"]*"'),
        'KEYFORMAT="$_widevineKeyFormatUuid"',
      );
    }
    return '$line,KEYFORMAT="$_widevineKeyFormatUuid"';
  }

  /// Android 原生 DRM 引擎的宿主入口：只起本地回环服务（**不开 WebView**），
  /// 清单按 ExoPlayer 要求把 KEYFORMAT 改写为 Widevine UUID，返回喂给原生播放器的 URL。
  /// 下载后的加密 m4a、license/证书反代、流式区间等待全部复用本类既有实现。
  Future<({String hlsUrl, String licenseUrl, String provisionUrl})>
  serveHlsForNative({
    required File m4a,
    required String m3u8,
    required Future<Uint8List> Function(Uint8List request) licensePoster,
    required Future<Uint8List> Function() certFetcher,
  }) async {
    _beginGeneration();
    await _ensureServer();
    _licensePoster = licensePoster;
    _certFetcher = certFetcher;
    _audioFile = m4a;
    _localM3u8 = _localizeM3u8(m3u8, widevineKeyFormat: true);
    return (
      hlsUrl: '$_origin/audio.m3u8',
      licenseUrl: '$_origin/license',
      provisionUrl: '$_origin/provision',
    );
  }

  Future<void> pause() {
    _wantsPlay = false;
    return _js('emePause($_playGen, ${++_intentRevision})');
  }

  Future<void> resume() {
    _wantsPlay = true;
    return _js('emeResume($_playGen, ${++_intentRevision})');
  }

  Future<void> stop() {
    _beginGeneration();
    _wantsPlay = false;
    return _js('emeStop($_playGen, ${++_intentRevision})');
  }

  Future<void> seek(Duration pos) =>
      _js('emeSeek(${(pos.inMilliseconds / 1000).toStringAsFixed(3)})');
  Future<void> syncPosition() => _js('emeSyncPosition($_playGen)');
  Future<void> setVolume(double v) {
    _volume = v.clamp(0.0, 1.0);
    return _js('emeSetVolume($_volume)');
  }

  /// 本机输出设备名（系统设备友好名，与 libmpv 的设备描述一致）；空串 = 系统默认。
  /// 进程内所有 EME 页面共用，页面重建后自动补发。
  static String _outputLabel = '';
  static final Set<EmePlayer> _live = {};

  static Future<void> setOutputDeviceLabel(String label) async {
    _outputLabel = label;
    await Future.wait(_live.map((p) => p._applyOutputLabel()));
  }

  Future<void> _applyOutputLabel() =>
      _js('emeSetSink(${jsonEncode(_outputLabel)})');

  /// WebView2：Chromium 只在来源持有麦克风权限时列出输出设备、允许 setSinkId。
  /// 本地补丁直接设置权限状态（不打开任何采集设备），只对本机回环来源生效。
  Future<void> _allowOutputSelection(InAppWebViewController controller) async {
    if (!Platform.isWindows) return;
    try {
      final id = controller.getViewId();
      final ok = await MethodChannel(
        'com.pichillilorenzo/flutter_inappwebview_$id',
      ).invokeMethod<bool>('flutifyAllowAudioOutputSelection', {
        'origin': _origin,
      });
      if (ok != true) debugPrint('[eme] 输出设备选择权限设置失败');
    } catch (e) {
      debugPrint('[eme] 输出设备选择权限设置异常：$e');
    }
  }

  /// 执行一段返回 promise 的 JS，取回其解析值（Windows/macOS 走 WebView，Linux 走 Chrome）。
  Future<String?> _callAsync(String body) async {
    final chrome = _chromePage;
    if (chrome != null) return chrome.callAsync(body);
    final c = await _readyController();
    final res = await c.callAsyncJavaScript(functionBody: body);
    final v = res?.value;
    return v is String ? v : v?.toString();
  }

  Future<void> _js(String source) async {
    // Linux：Chrome 页面（CDP）。
    final chrome = _chromePage;
    if (chrome != null) {
      if (_webViewStalled) return;
      try {
        await _pageReady.future.timeout(pageReadyTimeout);
        await chrome.evaluate(source).timeout(controlTimeout);
      } on TimeoutException {
        _webViewStalled = true;
        debugPrint('[eme] Chrome 页面未响应（$source 超时），下次播放时重建');
      } catch (_) {}
      return;
    }
    final c = _controller;
    // 已判定页面卡住：控制命令直接丢弃（反正执行不了），下一次 play 重建 WebView
    if (c == null || _webViewStalled) return;
    try {
      // 页面脚本 ready 前 evaluate 会撞 ReferenceError（如启动音量下发时
      // emeSetVolume 尚未定义）；等页载完再打。加载失败时 _pageReady 以 error
      // 完成，这里 catch 后丢弃，不会死锁。
      await _pageReady.future.timeout(pageReadyTimeout);
      await c.evaluateJavascript(source: source).timeout(controlTimeout);
    } on TimeoutException {
      // 切歌前会 await 暂停：页面卡住时只能超时放行，否则连播客 / 本地文件也播不了
      _webViewStalled = true;
      debugPrint('[eme] 页面未响应（$source 超时），下次播放时重建 WebView');
    } catch (_) {}
  }

  /// 页面事件入口（测试用）。
  @visibleForTesting
  void handleJsEvent(List<dynamic> args) => _onJsEvent(args);

  void _onJsEvent(List<dynamic> args) {
    final raw = args.isEmpty ? null : args.first;
    if (raw is! String) return;
    if (_disposed) return;
    final Map<String, dynamic> ev = jsonDecode(raw);
    // 页面按曲目实例给事件打上代次（emePlayHls 传入）；与当前代次不符即上一首残留：
    // 只留日志，不推进状态（否则旧 hls / 旧 stall 计时器的 error 会把新曲目标成失败）
    final gen = ev['gen'];
    if (gen is num && gen.toInt() != _playGen && ev['type'] != 'log') {
      debugPrint(
        '[eme] 忽略上一首残留事件 ${ev['type']}（gen=$gen，当前 $_playGen）: ${ev['msg'] ?? ''}',
      );
      return;
    }
    switch (ev['type']) {
      case 'position':
        _position = Duration(
          milliseconds: ((ev['position'] ?? 0) * 1000).round(),
        );
        final dur = (ev['duration'] ?? 0) * 1000;
        if (dur > 0) {
          final d = Duration(milliseconds: dur.round());
          if (d != _duration) {
            _duration = d;
            _durationController.add(d);
          }
        }
        _positionController.add(_position);
      case 'playing':
        _stateController.add(EmePlayerState.playing);
      case 'buffering':
        _stateController.add(EmePlayerState.buffering);
      case 'ended':
        _stateController.add(EmePlayerState.ended);
      case 'error':
        final msg = (ev['msg'] ?? 'unknown').toString();
        debugPrint('[eme] 播放错误: $msg');
        // 反代失败已写过更具体的原因（license / 证书），保留第一条
        lastError ??= _classifyError(msg);
        _stateController.add(EmePlayerState.error);
      case 'widevineUnavailable':
        _widevineUnavailable = true;
        if (!useFairPlay) {
          debugPrint('[eme] Widevine 不可用（后续播放错误按缺 Widevine 归类）: ${ev['msg']}');
        }
      case 'fairplayUnavailable':
        _fairPlayUnavailable = true;
        if (useFairPlay) {
          debugPrint('[eme] FairPlay 不可用（后续播放错误按缺 FairPlay 归类）: ${ev['msg']}');
        }
      case 'log':
        debugPrint('[eme-js] ${ev['msg']}');
    }
  }

  /// 按 HLS.js details / 错误文本归类：明确 DRM/CDM 缺失时打标记（重试无意义），
  /// 页面媒体错误不能证明 Web 登录失效；令牌 / 许可证错误由反代按类型判断。
  /// [_fairPlayMode] 时按 FairPlay 判定（macOS 缺 Widevine 是必然，不能拿它当依据）。
  EmePlaybackException _classifyError(String msg) {
    if (_fairPlayMode) {
      final noFps =
          _fairPlayUnavailable ||
          msg.toLowerCase().contains('keysystemnoaccess');
      return EmePlaybackException(
        'FairPlay/EME：$msg',
        isWidevineMissing: noFps,
      );
    }
    final noWidevine =
        _widevineUnavailable || msg.toLowerCase().contains('keysystemnoaccess');
    return EmePlaybackException(msg, isWidevineMissing: noWidevine);
  }

  Future<void> dispose() async {
    _live.remove(this);
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _headless?.dispose();
    _headless = null;
    _controller = null;
    await _chromeSub?.cancel();
    _chromeSub = null;
    _chromePage = null;
    await _loopback.close();
    _httpClient.close();
  }
}

enum EmePlayerState { playing, paused, buffering, ended, error }

