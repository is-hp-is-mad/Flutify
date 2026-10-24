import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../audio/audio_engine.dart';
import '../auth/web_token_exception.dart';
import 'chrome/linux_chrome.dart';
import 'fairplay.dart';
import 'license_client.dart';
import 'streaming_download.dart';

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
  HttpServer? _server;
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
  static const Set<String> allowedProvisionHosts = {
    'www.googleapis.com',
    'www.googleapis.cn',
    'android.clients.google.com',
  };

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
  Future<void>? _serverStarting;

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

  String get _origin => 'http://127.0.0.1:${_server!.port}';

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

  /// 在 runApp 后尽早调用一次（WebView 创建前）。
  static Future<WebViewEnvironment?> ensureEnvironment() {
    return _webViewEnvironment ??= () async {
      if (!Platform.isWindows) return null;
      try {
        final env = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
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

  Future<void> _ensureServer() => _serverStarting ??= _startServer().catchError(
    (Object error, StackTrace stack) {
      _serverStarting = null;
      Error.throwWithStackTrace(error, stack);
    },
  );

  Future<void> _startServer() async {
    if (_disposed) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_disposed) {
      await server.close(force: true);
      return;
    }
    _server = server;
    server.listen((request) async {
      if (!isOwnRequest(request.headers, server.port)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final path = request.uri.path;
      try {
        if (path == '/eme') {
          request.response.headers.contentType = ContentType.html;
          request.response.write(emePageHtml);
          await request.response.close();
        } else if (path == '/hls.js') {
          request.response.headers.contentType = ContentType(
            'application',
            'javascript',
          );
          request.response.write(hlsJsSource ?? '');
          await request.response.close();
        } else if (path == '/audio.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(_localM3u8 ?? '#EXTM3U');
          await request.response.close();
        } else if (path == '/audio/current.m4a') {
          await _serveAudio(request);
        } else if (path == '/license' && request.method == 'POST') {
          await _relayLicense(request);
        } else if (path == '/cert') {
          await _relayCert(request);
        } else if (path == '/provision' && request.method == 'POST') {
          await _relayProvision(request);
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      } catch (_) {
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  /// 本地服务只认自己的页面与本机播放器：
  /// - Host 必须是本服务的回环地址（127.0.0.1 / localhost，带端口时须是本端口）——挡 DNS rebinding：
  ///   网页把自己的域名解析到 127.0.0.1 后发来的请求，Host 仍是那个域名；
  /// - 带 Origin 的请求只放行本服务自己的页面——浏览器里别的网页发来的 POST 必带 Origin。
  ///   AVFoundation / ExoPlayer / 页面自己的同源 GET 不带 Origin，不受影响。
  /// 否则 /license（带用户的 Web token）与 /provision（转发到任意 https 地址）可被当成跳板。
  @visibleForTesting
  static bool isOwnRequest(HttpHeaders headers, int port) {
    final host = headers.value(HttpHeaders.hostHeader)?.toLowerCase();
    if (host == null) return false;
    final hostOk =
        host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '127.0.0.1:$port' ||
        host == 'localhost:$port';
    if (!hostOk) return false;
    final origin = headers.value('origin')?.toLowerCase();
    return origin == null ||
        origin == 'http://127.0.0.1:$port' ||
        origin == 'http://localhost:$port';
  }

  /// 供加密 m4a，支持 Range（HLS.js 按 BYTERANGE 取段）。
  /// 流式下载中时，若要的区间还没下完就等它（边下边播）。
  Future<void> _serveAudio(HttpRequest request) async {
    final file = _audioFile;
    if (file == null) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final response = request.response;
    response.headers.contentType = ContentType('audio', 'mp4');

    // 流式下载登记（有则说明还在下，需按区间等待）
    final dl = StreamingDownloads.of(file.path);

    // 解析 Range
    int start = 0;
    int? endExclusive;
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (m == null) {
        response.statusCode = 416;
        await response.close();
        return;
      }
      start = int.parse(m.group(1)!);
      endExclusive = m.group(2)!.isEmpty ? null : int.parse(m.group(2)!) + 1;
    }

    // 流式中：等到要的区间下完
    if (dl != null && !dl.done) {
      final need =
          endExclusive ?? (dl.expectedTotal > 0 ? dl.expectedTotal : start + 1);
      try {
        await dl.waitFor(need);
      } catch (e) {
        response.statusCode = 503;
        await response.close();
        return;
      }
    }

    final total = file.lengthSync();
    final end = (endExclusive ?? total).clamp(0, total);
    final len = end - start;
    if (len <= 0) {
      response.statusCode = 416;
      await response.close();
      return;
    }
    if (rangeHeader != null) {
      response.statusCode = 206;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/$total',
      );
    }
    response.headers.set(HttpHeaders.contentLengthHeader, len);
    await file.openRead(start, end).pipe(response);
  }

  /// license 反代：页面 HLS.js POST 的 CDM 请求 → Dart 代发到 Spotify → 返回响应。
  /// 失败不再是静默的 HTTP 500：真实原因写进响应体（HLS.js 错误数据可带回），
  /// 同时直接记入 [lastError] 并发 error 状态，不等 JS 侧的事件接力。
  Future<void> _relayLicense(HttpRequest request) async {
    final gen = _playGen;
    final body = await consolidatedBody(request);
    final poster = _licensePoster;
    if (poster == null) {
      await _failRelay(
        request,
        'license',
        StateError('licensePoster 未注入'),
        gen,
      );
      return;
    }
    try {
      final resp = await poster(body);
      debugPrint('[eme] license 反代：请求 ${body.length}B → 响应 ${resp.length}B');
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      request.response.add(resp);
      await request.response.close();
    } catch (e) {
      await _failRelay(request, 'license', e, gen);
    }
  }

  Future<void> _relayCert(HttpRequest request) async {
    final gen = _playGen;
    final fetcher = _certFetcher;
    if (fetcher == null) {
      await _failRelay(request, '证书', StateError('certFetcher 未注入'), gen);
      return;
    }
    try {
      final cert = await fetcher();
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      request.response.add(cert);
      await request.response.close();
    } catch (e) {
      await _failRelay(request, '证书', e, gen);
    }
  }

  /// provision 反代：原生播放器把 CDM 的 provision 请求体 POST 到本地回环，
  /// 这里经 App 代理策略外发到 CDM 给定的目标地址，响应字节与状态码原样回传。
  /// [target] 为 CDM 报的原始 provisioning URL（v1/v2 signedRequest 都走这里）。
  Future<void> _relayProvision(HttpRequest request) async {
    final gen = _playGen;
    final target = request.uri.queryParameters['target'];
    if (target == null || !isAllowedProvisionTarget(target)) {
      debugPrint('[eme] provision 反代：拒绝非法 target=$target');
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final body = await consolidatedBody(request);
    try {
      final resp = await _httpClient
          .post(
            Uri.parse(target),
            headers: {'Content-Type': 'application/octet-stream'},
            body: body,
          )
          .timeout(const Duration(seconds: 15));
      var line =
          '[eme] provision 反代：请求 ${body.length}B → HTTP ${resp.statusCode} ${resp.bodyBytes.length}B';
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // 失败原因写在响应体（Google provisioning 报错是文本），带前 200 字符进日志
        line =
            '$line | ${utf8.decode(resp.bodyBytes.take(200).toList(), allowMalformed: true)}';
      }
      debugPrint(line);
      request.response.statusCode = resp.statusCode;
      request.response.headers.contentType = ContentType(
        'application',
        'octet-stream',
      );
      request.response.add(resp.bodyBytes);
      await request.response.close();
    } catch (e) {
      await _failRelay(request, 'provision', e, gen);
    }
  }

  @visibleForTesting
  static bool isAllowedProvisionTarget(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      return false;
    }
    if (uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != 443))
      return false;
    return allowedProvisionHosts.contains(uri.host.toLowerCase());
  }

  /// 反代失败：原因写进 500 响应体（页面侧随 HLS 错误带回），并推进错误通道。
  /// 之所以走 [lastError] + stateStream（与 JS 侧 HLS/audio 错误汇合），
  /// 是因为上层只在 error 状态时读错误详情，一条通道即可覆盖两类来源。
  /// [gen] 为请求入口时的播放代次：已切歌（代次变了）则只回 500，不污染当前曲目的错误状态。
  Future<void> _failRelay(
    HttpRequest request,
    String name,
    Object error,
    int gen,
  ) async {
    if (gen != _playGen) {
      debugPrint('[eme] $name 反代失败（上一首残留，忽略）: $error');
    } else {
      debugPrint('[eme] $name 反代失败: $error');
      // 只记第一条：随后 hls.js 还会发 fatal 错误事件，别让泛化 details 覆盖真实原因
      lastError ??= EmePlaybackException(
        '$name 反代失败：$error',
        webSignInSuggested: _usesWebToken(name) && _isWebAuthFailure(error),
        cause: error,
      );
      _stateController.add(EmePlayerState.error);
    }
    try {
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType(
        'text',
        'plain',
        charset: 'utf-8',
      );
      request.response.write('$error');
      await request.response.close();
    } catch (_) {}
  }

  /// 这一路反代是否依赖 Web token（sp_dc 铸造）：license 总是；证书只有 FairPlay 要带鉴权
  ///（Widevine 证书只用 client-token）。FairPlay 的原生页面先取证书，Web 登录失效最先在这一步暴露。
  bool _usesWebToken(String relay) =>
      relay == 'license' || (relay == '证书' && _fairPlayMode);

  /// Only an explicit login requirement or an authenticated endpoint's 401
  /// suggests signing in. A 403 or digits in an arbitrary error are insufficient.
  static bool _isWebAuthFailure(Object error) => switch (error) {
    WebSignInRequiredException() => true,
    WebTokenHttpException(:final statusCode) => statusCode == 401,
    LicenseHttpException(:final statusCode) => statusCode == 401,
    _ => false,
  };

  static Future<Uint8List> consolidatedBody(HttpRequest request) async {
    final builder = BytesBuilder();
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

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
    await _serverStarting;
    await _server?.close(force: true);
    _server = null;
    _httpClient.close();
  }
}

enum EmePlayerState { playing, paused, buffering, ended, error }

/// 空白 EME 宿主页（HLS.js 驱动；无任何 UI/Spotify 前端；零外部请求）。
/// 页面加载 HLS.js → 加载本地 m3u8 → EME 解密 → MSE 播放。
const String emePageHtml = r'''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Flutify</title></head>
<body>
<script src="/hls.js"></script>
<script>
'use strict';
let hls = null, audio = null, telemetryTimer = null;
// 最近一次 emeSetVolume 的音量：每首歌都新建 audio 元素（默认 1.0），建好就沿用它
let pageVolume = 1;
// 本机输出设备（按系统设备名匹配；空串 = 系统默认）。每首歌新建 audio 元素后都要重新应用
let pageSinkLabel = '';
async function applySink(el) {
  if (!el || typeof el.setSinkId !== 'function') return;
  let id = '';
  if (pageSinkLabel) {
    try {
      // 只取输出设备，并去掉 Chromium 给出的「默认值 - xxx」「通信 - xxx」两个别名项
      const outs = (await navigator.mediaDevices.enumerateDevices()).filter((d) =>
        d.kind === 'audiooutput' && d.deviceId !== 'default' && d.deviceId !== 'communications');
      // 1) 完整名称精确匹配
      let hit = outs.find((d) => d.label === pageSinkLabel);
      // 2) 兜底：系统与 libmpv 的设备名写法略有出入时，比较括号里的硬件名（如「(Realtek(R) Audio)」）；
      //   只有唯一命中才用，同一声卡有多个输出时宁可回落系统默认也不切错
      if (!hit) {
        const hw = (t) => { const i = t.indexOf('('); return i >= 0 ? t.slice(i).trim() : ''; };
        const key = hw(pageSinkLabel);
        const same = key ? outs.filter((d) => hw(d.label) === key) : [];
        if (same.length === 1) hit = same[0];
      }
      if (hit) id = hit.deviceId;
      else send('log', {msg: '输出设备未唯一匹配（可选 ' + outs.length + ' 个），使用系统默认'});
    } catch (e) {
      send('log', {msg: '枚举输出设备失败: ' + e});
    }
  }
  try { await el.setSinkId(id); } catch (e) { send('log', {msg: 'setSinkId 失败: ' + e}); }
}
// 页面级：createMediaKeys 曾挂起则置真，之后所有 hls 实例不再带 serverCertificateUrl
//（部分 Android WebView 的 EME 带证书请求时 createMediaKeys 永不 settle；不带也能播）
let certDegraded = false;
// 当前曲目实例的播放代次（Dart 侧 emePlayHls 传入）；hook 在调用点捕获它给 stall 信号打标，
// 旧实例遗留的 6s 计时器晚到时带的是旧代次，新曲目的监听据此忽略
let curGen = 0;
let intentGen = 0, intentRevision = 0, playRequested = false;
const acceptIntent = (gen, revision, playing) => {
  if (gen < intentGen || (gen === intentGen && revision < intentRevision)) return false;
  intentGen = gen; intentRevision = revision; playRequested = playing;
  return true;
};
const playIfRequested = (el, gen) => {
  if (audio !== el || gen !== intentGen || !playRequested) return;
  el.muted = true;
  el.play().then(() => {
    if (audio === el && gen === intentGen && playRequested) el.muted = false;
    else el.pause();
  }).catch(() => {});
};
// 当前曲目的 'emeStall' 监听（模块级保存，换歌时先摘掉上一首的，避免旧闭包对新曲目报错）
let stallListener = null;

const send = (type, data) => {
  try { window.flutter_inappwebview.callHandler('emeEvent', JSON.stringify({type, ...(data||{})})); } catch (e) {}
};

// ---- EME 原生 API 时间戳 hook（非侵入 monkey-patch：只记录，不改时序、不吞错、返回原 Promise） ----
// 用于定位「无 encrypted、无 /license、无报错」卡死：hls.js / 页面里任何人走
// createMediaKeys → setServerCertificate → createSession → generateRequest 都会被记下。
// Promise 类步骤用 settle 标记，5s 未 settle 报「疑似挂起」。
try {
  const tapPromise = (p, tag, t0, timeout) => {
    timeout = timeout || 5000;
    const gen = curGen; // 调用时所属曲目实例的代次
    let settled = false;
    p.then(() => { settled = true; send('log', {msg: '[hook] ' + tag + ' resolve ' + (performance.now() - t0).toFixed(0) + 'ms'}); },
           (e) => { settled = true; send('log', {msg: '[hook] ' + tag + ' reject: ' + e}); });
    setTimeout(() => {
      if (settled) return;
      send('log', {msg: '[hook] ' + tag + ' ' + (timeout / 1000) + 's 未 settle（疑似挂起）'});
      // createMediaKeys 挂起是可恢复场景：除日志外发 stall 信号，
      // Dart 侧记一条，页面内广播给 emePlayHls 触发「无 serverCertificate」降级重建
      if (tag === 'createMediaKeys') {
        send('emeStall', {stage: tag, gen});
        try { window.dispatchEvent(new CustomEvent('emeStall', {detail: {stage: tag, gen}})); } catch (e) {}
      }
    }, timeout);
    return p;
  };
  if (window.MediaKeySystemAccess) {
    const _cmk = MediaKeySystemAccess.prototype.createMediaKeys;
    MediaKeySystemAccess.prototype.createMediaKeys = function (...args) {
      send('log', {msg: '[hook] createMediaKeys 调用'});
      return tapPromise(_cmk.apply(this, args), 'createMediaKeys', performance.now(), 6000);
    };
  }
  if (window.MediaKeys) {
    const _ssc = MediaKeys.prototype.setServerCertificate;
    MediaKeys.prototype.setServerCertificate = function (...args) {
      const cert = args[0];
      send('log', {msg: '[hook] setServerCertificate 调用 cert=' + (cert && cert.byteLength || 0) + 'B'});
      return tapPromise(_ssc.apply(this, args), 'setServerCertificate', performance.now());
    };
    const _cs = MediaKeys.prototype.createSession;
    MediaKeys.prototype.createSession = function (...args) {
      send('log', {msg: '[hook] createSession 调用'});
      const s = _cs.apply(this, args);
      s.addEventListener('message', (ev) => send('log',
        {msg: '[hook] session message type=' + ev.messageType + ' body=' + (ev.message ? ev.message.byteLength : 0) + 'B'}));
      s.addEventListener('keystatuseschange', () => send('log', {msg: '[hook] session keystatuseschange'}));
      return s;
    };
  }
  if (window.MediaKeySession) {
    const _gr = MediaKeySession.prototype.generateRequest;
    MediaKeySession.prototype.generateRequest = function (initDataType, initData) {
      send('log', {msg: '[hook] generateRequest 调用 initDataType=' + initDataType + ' initData=' + (initData && initData.byteLength || 0) + 'B'});
      return tapPromise(_gr.apply(this, arguments), 'generateRequest', performance.now());
    };
  }
  send('log', {msg: '[hook] EME API hook 已安装'});
} catch (e) {
  send('log', {msg: '[hook] EME API hook 安装失败: ' + e});
}

// 诊断（FairPlay）：每 2s 看一眼 currentTime 是否推进、缓冲范围、是否被置 mute，
// 只在「没暂停却不走 / 数据不够」时记日志（正常播放不刷屏，诊断日志尾部不被它挤掉）；
// 暂停、播完、出错时停表，再次 playing 时重开。
// 注意不能用 WebAudio（createMediaElementSource）接管元素输出来测电平：受 EME 保护的
// 媒体经 WebAudio 一律输出静音，明文 lead-in（约前 10s）有声、进入加密段即无声。
const watchStall = (el, gsend) => {
  let timer = null, lastT = -1;
  const stop = () => {
    if (!timer) return;
    clearInterval(timer);
    if (telemetryTimer === timer) telemetryTimer = null;
    timer = null;
  };
  const start = () => {
    if (timer || audio !== el) return;
    lastT = -1;
    timer = setInterval(() => {
      if (audio !== el) { stop(); return; }
      const t = el.currentTime || 0;
      const stuck = !el.paused && !el.ended && (el.readyState < 3 || Math.abs(t - lastT) < 0.05);
      lastT = t;
      if (!stuck) return;
      const end = el.buffered.length ? el.buffered.end(el.buffered.length - 1) : -1;
      gsend('log', {msg: '遥测（疑似卡住）t=' + t.toFixed(1) + ' rdy=' + el.readyState +
        ' net=' + el.networkState + ' buf→' + end.toFixed(1) + ' paused=' + el.paused +
        ' muted=' + el.muted + ' vol=' + el.volume});
    }, 2000);
    telemetryTimer = timer;
  };
  el.addEventListener('playing', start);
  ['pause', 'ended', 'error', 'emptied'].forEach((n) => el.addEventListener(n, stop));
  start();
};

// [gen] 为 Dart 侧播放代次：本实例发出的所有事件都带上它，Dart 据此丢弃上一首的残留事件
//（旧 audio / 旧 hls 的晚到 error、旧 stall 计时器等），不会把健康的新曲目标成失败。
window.emePlayHls = (fairPlay, gen, autoplay = true, revision = 0, position = 0) => (async () => {
  const myGen = Number(gen) || 0;
  const gsend = (type, data) => send(type, {...(data||{}), gen: myGen});
  try {
    if (myGen < intentGen || myGen < curGen) return 'cancelled';
    acceptIntent(myGen, revision, autoplay);
    curGen = myGen;
    // 先摘掉上一首的 stall 监听（它只在 stall 触发时才自摘，正常换歌会一直挂着）
    if (stallListener) { window.removeEventListener('emeStall', stallListener); stallListener = null; }
    if (!window.Hls) return 'ERR:Hls.js 未加载';
    if (!Hls.isSupported()) return 'ERR:HLS 不支持';
    const useFairPlay = !!fairPlay;
    window.__fpsContentId = null; // 换歌清掉上一首的 FairPlay content ID
    // FairPlay 的 generateRequest 过滤器（等价于 hls.js 官方 FPS 集成）：
    // 播放列表 KEY 不带 pssh，改成 initDataType 'skd' 交给 CDM。
    // 实测：FPS content ID 必须是「剥掉 skd:// scheme 的裸 file_id」（40 位 hex）——
    // 带 scheme 的完整 URI（包括 sneaktables 自产的 skd:///fairplay-license/... 形态）
    // 换 license 一律 HTTP 500，裸 file_id 返回 200 CKC（2026-10 线上实测，见 fairplay.dart）。
    const fpsDrmSystems = {
      'com.apple.fps': {
        licenseUrl: '/license',
        serverCertificateUrl: '/cert',
        generateRequest: (initDataType, initData, keyContext) => {
          const uri = keyContext && keyContext.decryptdata && keyContext.decryptdata.uri;
          let contentId = (uri || '').replace(/^skd:\/\//, '');
          // fmp4 moov 里的 FPS pssh 会再触发一次 initDataType=sinf 的会话，hls 给它
          // 合成的 uri 是截断 KID（必 400）；它与 playlist KEY 是同一内容密钥，复用即可
          // 注意：此 hls.js/MSE 路径在 macOS 上已不用于 FairPlay（见 emePlayNativeFps）：
          // MSE 下系统按样本 KID 要密钥，skd 会话的密钥对不上 KID → 进度走但无声；
          // 把 sinf 原样透传则 SPC 的 content ID 变成 KID → Spotify license 500。
          if (initDataType === 'cenc' && contentId) {
            window.__fpsContentId = contentId;
          } else if (window.__fpsContentId) {
            contentId = window.__fpsContentId;
          }
          gsend('log', {msg: 'fairplay generateRequest: ' + initDataType + ' → skd contentId=' + contentId});
          return { initDataType: 'skd', initData: new TextEncoder().encode(contentId) };
        },
      },
    };
    // 换歌 / 失败重试：销毁上一首的 hls 与 audio，避免残留状态串台
    if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
    if (audio) { try { audio.pause(); audio.remove(); } catch (e) {} audio = null; }
    audio = document.createElement('audio');
    audio.volume = pageVolume;
    applySink(audio);
    document.body.appendChild(audio);
    const el = audio;
    el.addEventListener('loadedmetadata', () => { if (position > 0) el.currentTime = position; }, {once: true});
    audio.addEventListener('timeupdate', () => gsend('position', {position: audio.currentTime, duration: audio.duration}));
    audio.addEventListener('playing', () => gsend('playing', {}));
    audio.addEventListener('waiting', () => gsend('buffering', {}));
    audio.addEventListener('ended', () => gsend('ended', {}));
    audio.addEventListener('error', () => gsend('error', {msg: audio.error ? (audio.error.code + ':' + audio.error.message) : 'unknown'}));
    audio.addEventListener('encrypted', (ev) => gsend('log', {msg: 'encrypted 事件 initDataType=' + ev.initDataType + ' initData=' + (ev.initData ? ev.initData.byteLength : 0) + 'B'}));
    // 诊断：媒体元素状态迁移（定位「不出声也不报错」卡在 readyState 哪一级）
    ['play','pause','waiting','stalled','canplay','canplaythrough','playing','waitingforkey','loadeddata','loadedmetadata','durationchange']
      .forEach((n) => audio.addEventListener(n, () => gsend('log',
        {msg: 'audio 事件 ' + n + ' t=' + (audio.currentTime || 0).toFixed(2) + ' readyState=' + audio.readyState})));
    // 诊断（FairPlay）：卡住检测遥测，见 watchStall
    if (telemetryTimer) { clearInterval(telemetryTimer); telemetryTimer = null; }
    if (useFairPlay) watchStall(audio, gsend);

    // hls 实例构建（降级重建时复用）：certDegraded 为真则不带 serverCertificateUrl，
    // 让 EMEController 跳过 setServerCertificate（已验证桌面 Chrome 无证书也能播）。
    // FairPlay 无此降级：WebKit FPS CDM 无 serverCertificate 直接拒绝 generateRequest。
    const buildHls = () => {
      if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
      const widevine = certDegraded
        ? { licenseUrl: '/license' }                                    // 降级：不碰 setServerCertificate
        : { licenseUrl: '/license', serverCertificateUrl: '/cert' };
      hls = new Hls({
        startPosition: position > 0 ? position : -1,
        emeEnabled: true,
        drmSystems: useFairPlay ? fpsDrmSystems : {
          'com.widevine.alpha': widevine,
        },
        // 宽限：本地服务，无需重试策略
        fragLoadingMaxRetry: 2,
        manifestLoadingMaxRetry: 2,
      });
      // 诊断：hls 管线关键事件逐个埋点；bundle 是 hls.js 1.5.13，不暴露
      // KEY_SYSTEM_* 公共事件（只有 ErrorDetails 常量），按存在性守卫自动跳过
      let firstFragLogged = false, firstBufferedLogged = false;
      const evt = (name, fn) => {
        if (Hls.Events && Hls.Events[name]) { hls.on(Hls.Events[name], fn); return true; }
        gsend('log', {msg: 'hls.js 无 ' + name + ' 事件（当前版本不暴露，跳过）'});
        return false;
      };
      evt('MEDIA_ATTACHED', () => gsend('log', {msg: 'MSE attach 完成'}));
      evt('BUFFER_CREATED', (e, d) => gsend('log', {msg: 'MSE SourceBuffer 已建: ' + Object.keys(d.tracks || {}).join('+')}));
      evt('LEVEL_LOADED', (e, d) => gsend('log', {
        msg: 'LEVEL_LOADED 分段数='
          + (d.details && d.details.fragments ? d.details.fragments.length : '?')
          + ' 时长=' + (d.details ? d.details.totalduration.toFixed(1) : '?') + 's'}));
      evt('FRAG_LOADED', (e, d) => {
        if (!firstFragLogged) {
          firstFragLogged = true;
          gsend('log', {msg: '首个 FRAG_LOADED sn=' + (d.frag ? d.frag.sn : '?') + ' bytes=' + (d.payload ? d.payload.byteLength : '?')});
        }
      });
      evt('FRAG_BUFFERED', (e, d) => {
        if (!firstBufferedLogged) {
          firstBufferedLogged = true;
          gsend('log', {msg: '首个 FRAG_BUFFERED（分段已进 MSE）sn=' + (d.frag ? d.frag.sn : '?')});
        }
      });
      evt('BUFFER_APPENDED', (e, d) => gsend('log', {msg: 'BUFFER_APPENDED type=' + d.type}));
      evt('KEY_SYSTEM_ACCESS', (e, d) => gsend('log', {msg: 'KEY_SYSTEM_ACCESS'}));
      hls.on(Hls.Events.ERROR, (ev, data) => {
        // 反代把 license / 证书失败原因写在 500 响应体里；HLS.js 错误数据带响应时就一并带回 Dart
        let extra = '';
        try {
          const r = data.response;
          if (r && r.code) extra += ' http=' + r.code;
          const d = r && r.data;
          if (d) {
            const text = typeof d === 'string' ? d : new TextDecoder().decode(d.slice(0, 256));
            if (text) extra += ' ' + text;
          }
        } catch (e) {}
        gsend('log', {msg: 'HLS ERROR ' + data.type + '/' + data.details + ' fatal=' + data.fatal + extra});
        if (data.fatal) gsend('error', {msg: data.details + extra});
      });
      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        gsend('log', {msg: '清单已解析'});
        playIfRequested(el, myGen);
      });
      hls.loadSource('/audio.m3u8');
      hls.attachMedia(audio);
      gsend('log', {msg: certDegraded ? 'hls 已启动（降级：无 serverCertificate）' : 'hls 已启动'});
    };

    // createMediaKeys 挂起（hook 6s 未 settle 广播 'emeStall'）→ 原地销毁 hls 重建为无证书配置。
    // 只降级一次（stallHandled）；降配实例仍挂起则 gsend('error') 交回 Dart 现有错误通道。
    let stallHandled = certDegraded; // 已降级的页面本次直接算「已降级」，再挂立即报错
    const onEmeStall = (ev) => {
      if (!ev.detail || ev.detail.stage !== 'createMediaKeys') return;
      // 旧曲目实例的计时器晚到（代次不符）：与本曲目无关，忽略
      if (ev.detail.gen !== myGen || curGen !== myGen || intentGen !== myGen) return;
      if (useFairPlay) {
        // FairPlay 依赖 serverCertificate，无「去证书」降级空间，直接报错
        window.removeEventListener('emeStall', onEmeStall);
        if (stallListener === onEmeStall) stallListener = null;
        gsend('error', {msg: 'createMediaKeys 挂起（FairPlay，本机 WebView EME 不可用）'});
        return;
      }
      if (stallHandled) {
        // 降配实例仍挂起：不可恢复，只报一次并摘除监听
        window.removeEventListener('emeStall', onEmeStall);
        if (stallListener === onEmeStall) stallListener = null;
        gsend('error', {msg: 'createMediaKeys 仍挂起（已按无 serverCertificate 降级重建，本机 WebView EME 不可用）'});
        return;
      }
      stallHandled = true;
      certDegraded = true;
      gsend('log', {msg: 'createMediaKeys 挂起 → 原地重建 hls（去掉 serverCertificateUrl）'});
      buildHls(); // 监听保留：继续观察降配实例是否也挂起
    };
    stallListener = onEmeStall;
    window.addEventListener('emeStall', onEmeStall);
    buildHls();
    return 'ok';
  } catch (e) {
    return 'ERR:' + String(e);
  }
})();

// macOS FairPlay：WebKit 原生 HLS（<audio src=m3u8>）+ 旧版 EME（webkitneedkey / WebKitMediaKeys
// 'com.apple.fps.1_0'），即 Spotify 自家 Safari 播放器与 Apple FPS 示例的路线。
// 不用 hls.js/MSE 的原因：MSE 下 AVFoundation 按样本 KID 发起密钥请求，SPC 的 content ID 只能是 KID，
// Spotify 的 license 服务只认裸 file_id → 500；而 playlist skd 会话虽拿到密钥却对不上 KID → 无声。
// 旧版 EME 里 SPC 的 content ID 由页面拼进 createSession 的 initData（裸 file_id），
// 密钥则按清单 skd:// URI 回填给原生播放器的那次请求，两头一致。
window.emePlayNativeFps = (gen, fileIdHex, autoplay = true, revision = 0, position = 0) => (async () => {
  const myGen = Number(gen) || 0;
  const gsend = (type, data) => send(type, {...(data||{}), gen: myGen});
  try {
    if (myGen < intentGen || myGen < curGen) return 'cancelled';
    acceptIntent(myGen, revision, autoplay);
    curGen = myGen;
    if (stallListener) { window.removeEventListener('emeStall', stallListener); stallListener = null; }
    // 'ERR:NOFPS:' 前缀：本机缺 FairPlay（Dart 侧据此提示「设备不支持」而不是「请重试」）
    if (typeof WebKitMediaKeys === 'undefined') return 'ERR:NOFPS:本机 WebView 无旧版 EME（WebKitMediaKeys）';
    if (!WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'audio/mp4')) return 'ERR:NOFPS:本机 WebView 不支持 com.apple.fps.1_0';
    if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
    if (audio) { try { audio.pause(); audio.removeAttribute('src'); audio.load(); audio.remove(); } catch (e) {} audio = null; }
    if (telemetryTimer) { clearInterval(telemetryTimer); telemetryTimer = null; }
    audio = document.createElement('audio');
    audio.volume = pageVolume;
    applySink(audio);
    document.body.appendChild(audio);
    const el = audio;
    el.addEventListener('loadedmetadata', () => { if (position > 0) el.currentTime = position; }, {once: true});
    el.addEventListener('timeupdate', () => gsend('position', {position: el.currentTime, duration: el.duration}));
    el.addEventListener('playing', () => gsend('playing', {}));
    el.addEventListener('waiting', () => gsend('buffering', {}));
    el.addEventListener('ended', () => gsend('ended', {}));
    el.addEventListener('error', () => gsend('error', {msg: 'native-hls ' + (el.error ? (el.error.code + ':' + el.error.message) : 'unknown')}));
    ['play','pause','waiting','stalled','canplay','canplaythrough','playing','loadedmetadata','durationchange']
      .forEach((n) => el.addEventListener(n, () => gsend('log',
        {msg: 'audio 事件 ' + n + ' t=' + (el.currentTime || 0).toFixed(2) + ' readyState=' + el.readyState})));
    watchStall(el, gsend);

    // needkey 的 initData 是 UTF-16LE 的 skd:// URI；content ID = 剥掉 scheme 的裸 file_id。
    // createSession 的 initData 按 Apple 示例拼：initData | len(u32le) | contentId(UTF-16LE) | len(u32le) | cert
    const utf16 = (bytes) => { let s = ''; for (let i = 0; i + 1 < bytes.length; i += 2) s += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8)); return s; };
    const toUtf16 = (str) => { const out = new Uint8Array(str.length * 2); for (let i = 0; i < str.length; i++) { const c = str.charCodeAt(i); out[i * 2] = c & 0xff; out[i * 2 + 1] = c >> 8; } return out; };
    const buildSpcInit = (initData, contentId, cert) => {
      const id = toUtf16(contentId);
      const buf = new Uint8Array(initData.byteLength + 4 + id.byteLength + 4 + cert.byteLength);
      const dv = new DataView(buf.buffer);
      let o = 0;
      buf.set(initData, o); o += initData.byteLength;
      dv.setUint32(o, id.byteLength, true); o += 4;
      buf.set(id, o); o += id.byteLength;
      dv.setUint32(o, cert.byteLength, true); o += 4;
      buf.set(cert, o);
      return buf;
    };
    let certBytes = null;
    const sessions = {};
    el.addEventListener('webkitneedkey', async (ev) => {
      try {
        const initData = new Uint8Array(ev.initData);
        // initData 的编码随 WebKit 版本而异（UTF-16 URI / 其他封装），只做诊断打印；
        // content ID 直接用 Dart 传来的 file_id（与清单 skd:// 一致），不依赖解析 initData
        const hex = Array.from(initData.slice(0, 48), (b) => b.toString(16).padStart(2, '0')).join('');
        const asU16 = utf16(initData).replace(/[^\x20-\x7e]/g, '.');
        const asU8 = new TextDecoder().decode(initData).replace(/[^\x20-\x7e]/g, '.');
        gsend('log', {msg: 'webkitneedkey initData=' + initData.byteLength + 'B hex=' + hex + ' u16=' + asU16.slice(0, 80) + ' u8=' + asU8.slice(0, 80)});
        const contentId = String(fileIdHex || '');
        if (!contentId) throw new Error('缺 file_id（content ID）');
        if (sessions[contentId]) { gsend('log', {msg: 'needkey 重复（已有会话），忽略'}); return; }
        if (!el.webkitKeys) el.webkitSetMediaKeys(new WebKitMediaKeys('com.apple.fps.1_0'));
        if (!certBytes) {
          const r = await fetch('/cert');
          if (!r.ok) throw new Error('证书 HTTP ' + r.status);
          certBytes = new Uint8Array(await r.arrayBuffer());
        }
        if (audio !== el || curGen !== myGen || intentGen !== myGen) return;
        const session = el.webkitKeys.createSession('audio/mp4', buildSpcInit(initData, contentId, certBytes));
        sessions[contentId] = session;
        gsend('log', {msg: 'FPS 会话已建 sessionId=' + session.sessionId});
        session.addEventListener('webkitkeymessage', async (e) => {
          if (audio !== el || curGen !== myGen || intentGen !== myGen) return;
          const spc = new Uint8Array(e.message);
          gsend('log', {msg: 'webkitkeymessage SPC=' + spc.byteLength + 'B'});
          try {
            const r = await fetch('/license', {method: 'POST', body: spc});
            if (!r.ok) { gsend('error', {msg: 'license HTTP ' + r.status + ' ' + (await r.text()).slice(0, 200)}); return; }
            const ckc = new Uint8Array(await r.arrayBuffer());
            gsend('log', {msg: 'CKC=' + ckc.byteLength + 'B → session.update'});
            if (audio === el && curGen === myGen && intentGen === myGen) session.update(ckc);
          } catch (err) { gsend('error', {msg: 'license 请求异常: ' + err}); }
        });
        session.addEventListener('webkitkeyadded', () => gsend('log', {msg: 'FPS 密钥已装载（webkitkeyadded）'}));
        session.addEventListener('webkitkeyerror', () => gsend('error',
          {msg: 'FPS keyerror code=' + (session.error && session.error.code) + ' systemCode=' + (session.error && session.error.systemCode)}));
      } catch (err) { gsend('error', {msg: 'needkey 处理异常: ' + err}); }
    });
    el.src = '/audio.m3u8';
    el.load();
    playIfRequested(el, myGen);
    gsend('log', {msg: '原生 HLS 已启动（FairPlay 旧版 EME）'});
    return 'ok';
  } catch (e) {
    return 'ERR:' + String(e);
  }
})();

// 启动时探测一次各 DRM 体系是否可用：结果写进日志，不可用时上报给 Dart
//（该设备随后的播放错误按「缺 Widevine/FairPlay」归类，提示重试无意义。
// 两套都探：macOS 用 com.apple.fps，桌面其余用 com.widevine.alpha；
// FairPlay 的 initDataTypes 对齐 hls.js 的 ['cenc','sinf']）
(async () => {
  // 原生 HLS + 旧版 EME（Spotify 自家 Safari 播放器走的路：SPC 的 content ID 由页面自填）能力探测
  try {
    const a = document.createElement('audio');
    const legacy = typeof WebKitMediaKeys !== 'undefined';
    const fps10 = legacy && WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'audio/mp4');
    send('log', {msg: '原生 HLS canPlayType=' + JSON.stringify(a.canPlayType('application/vnd.apple.mpegurl'))
      + ' WebKitMediaKeys=' + legacy
      + ' fps.1_0=' + (legacy ? fps10 : 'n/a')
      + ' webkitSetMediaKeys=' + (typeof a.webkitSetMediaKeys)});
    // FairPlay 播放走的就是这套旧版 API（emePlayNativeFps），可用与否以它为准
    if (!fps10) send('fairplayUnavailable', {msg: legacy ? 'WebKitMediaKeys 不支持 com.apple.fps.1_0' : '无 WebKitMediaKeys（旧版 EME）'});
  } catch (e) { send('log', {msg: '原生 HLS/旧版 EME 探测异常: ' + e}); }
  for (const [ks, label, init] of [
    ['com.widevine.alpha', 'widevine', ['cenc']],
    ['com.apple.fps', 'fairplay', ['cenc', 'sinf']],
  ]) {
    try {
      const access = await navigator.requestMediaKeySystemAccess(ks, [{
        initDataTypes: init,
        audioCapabilities: [{contentType: 'audio/mp4; codecs="mp4a.40.2"'}],
      }]);
      send('log', {msg: ks + ' 可用 ' + JSON.stringify(access.getConfiguration().audioCapabilities)});
    } catch (e) {
      send('log', {msg: ks + ' 不可用: ' + e});
      // 新版 com.apple.fps 只记日志：FairPlay 的可用性以上面的旧版 API 探测为准
      if (label !== 'fairplay') send(label + 'Unavailable', {msg: String(e)});
    }
  }
  send('log', {msg: 'UA ' + navigator.userAgent});
})();

window.emePause = (gen = curGen, revision = intentRevision + 1) => {
  if (acceptIntent(gen, revision, false) && audio) audio.pause();
};
window.emeResume = (gen = curGen, revision = intentRevision + 1) => {
  if (acceptIntent(gen, revision, true) && curGen === gen && audio) playIfRequested(audio, gen);
};
window.emeStop = (gen, revision) => {
  if (!acceptIntent(gen, revision, false)) return;
  if (hls) { hls.destroy(); hls = null; }
  if (audio) { audio.pause(); audio.removeAttribute('src'); audio.load(); audio.remove(); audio = null; }
  if (telemetryTimer) { clearInterval(telemetryTimer); telemetryTimer = null; }
};
window.emeSeek = (sec) => { if (audio) audio.currentTime = sec; };
window.emeSetSink = (label) => {
  pageSinkLabel = typeof label === 'string' ? label : '';
  if (audio) applySink(audio);
};
window.emeSetVolume = (v) => {
  if (!(v >= 0 && v <= 1)) return;
  pageVolume = v;
  if (audio) audio.volume = v;
};
</script>
</body>
</html>
''';
