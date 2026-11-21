import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 极简 Chrome DevTools Protocol 客户端（仅用 `dart:io` WebSocket，无第三方依赖）。
///
/// 协议为 JSON-RPC 风格：`{id, method, params}` → `{id, result|error}`；
/// 服务端主动事件为不带 `id` 的消息。响应按 id 配对，事件经 [events] 广播。
class CdpSession {
  final WebSocket _socket;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> _closed = Completer<void>();

  CdpSession._(this._socket) {
    _socket.listen(
      _onData,
      onDone: _onDone,
      onError: (Object e) => _onDone(),
      cancelOnError: false,
    );
  }

  static Future<CdpSession> connect(Uri webSocketUrl) async {
    final ws = await WebSocket.connect(webSocketUrl.toString());
    return CdpSession._(ws);
  }

  Stream<Map<String, dynamic>> get events => _events.stream;
  Future<void> get closed => _closed.future;

  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
    String? sessionId,
  ]) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode({
        'id': id,
        'method': method,
        if (params != null) 'params': params,
        if (sessionId != null) 'sessionId': sessionId,
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('CDP $method timed out');
      },
    );
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    final decoded = jsonDecode(data);
    if (decoded is! Map) return;
    final message = decoded.cast<String, dynamic>();
    final id = message['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (message.containsKey('error')) {
        completer.completeError(StateError('CDP error: ${message['error']}'));
      } else {
        final result = message['result'];
        completer.complete(
          result is Map ? result.cast<String, dynamic>() : <String, dynamic>{},
        );
      }
      return;
    }
    if (!_events.isClosed) _events.add(message);
  }

  void _onDone() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('CDP connection closed'));
    }
    _pending.clear();
    if (!_closed.isCompleted) _closed.complete();
    if (!_events.isClosed) _events.close();
  }

  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
  }
}

/// 一个受 Chrome 管理的页面标签：执行 JS、接收 `__emeEvent` 绑定调用、读 cookie。
///
/// 通过 CDP 的扁平会话（flatten session）工作：所有命令带 [sessionId]，事件按会话过滤。
class ChromePage {
  final CdpSession cdp;
  final String sessionId;
  final StreamController<String> _emeEvents =
      StreamController<String>.broadcast();

  /// 当前文档的 load 完成；每次 [navigate] 都会换成新的 completer，
  /// 否则会命中上一份文档的 load（导致在新页面脚本还没跑时就执行命令）。
  Completer<void> _loaded = Completer<void>();
  bool _disposed = false;

  ChromePage._(this.cdp, this.sessionId) {
    cdp.events.listen(_onEvent);
  }

  /// 页面通过 `window.__emeEvent(json)` 发来的事件负载（原样字符串）。
  Stream<String> get emeEvents => _emeEvents.stream;

  Future<void> get loaded => _loaded.future;

  Future<Map<String, dynamic>> _send(
    String method, [
    Map<String, dynamic>? params,
  ]) => cdp.send(method, params, sessionId);

  Future<void> initialize() async {
    await _send('Page.enable');
    await _send('Runtime.enable');
    await _send('Network.enable');
    // 页面把 `window.flutter_inappwebview.callHandler('emeEvent', json)` 转发到这个绑定，
    // 复用现有 EME 宿主页（无需改动页面脚本）。
    await _send('Runtime.addBinding', {'name': '__emeEvent'});
    await _send('Page.addScriptToEvaluateOnNewDocument', {
      'source': 'window.flutter_inappwebview={callHandler:function(n,d){'
          'try{window.__emeEvent(d)}catch(e){}}};',
    });
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['sessionId'] != sessionId) return;
    switch (event['method']) {
      case 'Page.loadEventFired':
        if (!_loaded.isCompleted) _loaded.complete();
      case 'Runtime.bindingCalled':
        final params = event['params'];
        if (params is Map && params['name'] == '__emeEvent') {
          final payload = params['payload'];
          if (payload is String && !_emeEvents.isClosed) _emeEvents.add(payload);
        }
      case 'Inspector.detached':
        if (!_loaded.isCompleted) {
          _loaded.completeError(StateError('Chrome page detached'));
        }
    }
  }

  Future<void> navigate(String url) {
    if (_loaded.isCompleted) _loaded = Completer<void>();
    return _send('Page.navigate', {'url': url});
  }

  /// 等价于 WebView 的 `evaluateJavascript(source)`。
  Future<void> evaluate(String source) async {
    await _send('Runtime.evaluate', {
      'expression': source,
      'userGesture': true,
      'awaitPromise': false,
    });
  }

  /// 等价于 WebView 的 `callAsyncJavaScript(functionBody:)`：
  /// 把 [body] 作为 async 函数体执行，返回其 promise 的解析值（字符串化）。
  Future<String?> callAsync(String body) async {
    final result = await _send('Runtime.evaluate', {
      'expression': '(async()=>{ $body })()',
      'awaitPromise': true,
      'returnByValue': true,
      'userGesture': true,
    });
    final remote = result['result'];
    if (remote is Map) {
      final value = remote['value'];
      if (value == null) return null;
      return value is String ? value : value.toString();
    }
    return null;
  }

  /// 读取某 URL 下的全部 cookie（含 HttpOnly，用于捕获 `sp_dc`）。
  Future<Map<String, String>> cookies(String url) async {
    final result = await _send('Network.getCookies', {
      'urls': [url],
    });
    final list = result['cookies'];
    final out = <String, String>{};
    if (list is List) {
      for (final c in list) {
        if (c is Map && c['name'] is String && c['value'] is String) {
          out[c['name'] as String] = c['value'] as String;
        }
      }
    }
    return out;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_emeEvents.isClosed) await _emeEvents.close();
  }
}

/// 定位并启动 Google Chrome / Chromium（含 Widevine），建立 CDP 会话并管理窗口可见性。
class LinuxChrome {
  final Process process;
  final CdpSession browser;
  final int port;
  final Directory userDataDir;
  bool _headless;

  LinuxChrome._(this.process, this.browser, this.port, this.userDataDir,
      this._headless);

  /// 是否以 `--headless=new` 运行（无窗口）。
  bool get isHeadless => _headless;

  /// 候选浏览器可执行文件（优先自带 Widevine 的 Google Chrome）。
  static const List<String> _candidates = [
    'google-chrome',
    'google-chrome-stable',
    'chromium',
    'chromium-browser',
    'brave-browser',
    'microsoft-edge',
  ];

  static String? findExecutable() {
    for (final name in _candidates) {
      final found = _which(name);
      if (found != null) return found;
    }
    return null;
  }

  static String? _which(String name) {
    try {
      final result = Process.runSync('which', [name]);
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        if (path.isNotEmpty) return path;
      }
    } catch (_) {}
    return null;
  }

  /// 启动 Chrome 并连接浏览器级 CDP。
  ///
  /// [headless] 为 true 用 `--headless=new`；否则开一个窗口，[visible] 控制是否可见
  /// （不可见时移到屏幕外）。播放需要真实窗口才能出声，登录需要可见窗口。
  static Future<LinuxChrome> launch({
    required Directory userDataDir,
    bool headless = false,
    bool visible = false,
    Uri? initialUrl,
  }) async {
    final exe = findExecutable();
    if (exe == null) {
      throw StateError('Chrome / Chromium not found; Widevine full-track playback is unavailable');
    }
    await userDataDir.create(recursive: true);
    // 持久化 profile 会残留上一次运行写的 DevToolsActivePort；若不删除，_waitDevTools
    // 会立刻读到这个过期端口并连接一个已关闭的端口（Connection refused）。
    try {
      File('${userDataDir.path}/DevToolsActivePort').deleteSync();
    } catch (_) {}
    final url = initialUrl?.toString() ?? 'about:blank';
    final args = <String>[
      '--user-data-dir=${userDataDir.path}',
      // 端口交给系统分配并写入 DevToolsActivePort：固定端口时 Chrome 不写该文件。
      '--remote-debugging-port=0',
      '--remote-allow-origins=*',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-timer-throttling',
      '--disable-backgrounding-occluded-windows',
      '--disable-renderer-backgrounding',
      '--autoplay-policy=no-user-gesture-required',
      '--disable-features=HardwareMediaKeyHandling,MediaSessionService,CalculateNativeWinOcclusion',
      if (headless) ...[
        '--headless=new',
        url,
      ] else ...[
        if (visible)
          '--window-size=1080,760'
        else ...[
          '--window-position=-32000,-32000',
          '--window-size=240,200',
        ],
        '--app=$url',
      ],
    ];
    final process = await Process.start(exe, args);
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    try {
      final endpoint = await _waitDevTools(process, userDataDir);
      final browser = await CdpSession.connect(endpoint.wsUrl);
      return LinuxChrome._(process, browser, endpoint.port, userDataDir, headless);
    } catch (_) {
      // 启动/连接失败：杀掉刚拉起的进程，避免留下孤儿 Chrome（重复窗口/进程的根源）
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {}
      rethrow;
    }
  }

  static Future<({int port, Uri wsUrl})> _waitDevTools(
    Process process,
    Directory userDataDir,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      final exited =
          await process.exitCode.timeout(Duration.zero, onTimeout: () => -1);
      if (exited != -1) throw StateError('Chrome exited right after launch (code=$exited)');
      try {
        final file = File('${userDataDir.path}/DevToolsActivePort');
        if (await file.exists()) {
          final lines = await file.readAsLines();
          if (lines.length >= 2 && lines[1].isNotEmpty) {
            final port = int.tryParse(lines[0].trim());
            if (port != null) {
              return (
                port: port,
                wsUrl: Uri.parse('ws://127.0.0.1:$port${lines[1].trim()}'),
              );
            }
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError('Chrome DevTools not ready');
  }

  Future<List<({String targetId, String? url})>> _pageTargets() async {
    final res = await browser.send('Target.getTargets');
    final infos = res['targetInfos'];
    final out = <({String targetId, String? url})>[];
    if (infos is List) {
      for (final t in infos) {
        if (t is Map && t['type'] == 'page' && t['targetId'] is String) {
          out.add((targetId: t['targetId'] as String, url: t['url'] as String?));
        }
      }
    }
    return out;
  }

  Future<ChromePage> _attach(String targetId) async {
    final attached = await browser.send('Target.attachToTarget', {
      'targetId': targetId,
      'flatten': true,
    });
    final sessionId = attached['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('Failed to attach to the Chrome page');
    }
    final page = ChromePage._(browser, sessionId);
    await page.initialize();
    return page;
  }

  /// 附着到 Chrome 中已有的页面标签（启动时 `--app=<url>` 打开的那个）。
  Future<ChromePage> attachPage() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final targets = await _pageTargets();
      if (targets.isNotEmpty) return _attach(targets.first.targetId);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError('Chrome page not found');
  }

  /// 新建一个标签页。
  Future<ChromePage> newPage({String url = 'about:blank'}) async {
    final created = await browser.send('Target.createTarget', {'url': url});
    final targetId = created['targetId'];
    if (targetId is! String) throw StateError('Failed to create a Chrome tab');
    return _attach(targetId);
  }

  /// 显示 / 隐藏窗口（隐藏时移到屏幕外，避免最小化导致音频被节流）。
  Future<void> setVisible(bool visible) async {
    if (_headless) return;
    try {
      final targets = await _pageTargets();
      if (targets.isEmpty) return;
      final info = await browser.send('Browser.getWindowForTarget', {
        'targetId': targets.first.targetId,
      });
      final windowId = info['windowId'];
      if (windowId is! int) return;
      await browser.send('Browser.setWindowBounds', {
        'windowId': windowId,
        'bounds': visible
            ? {
                'windowState': 'normal',
                'left': 120,
                'top': 90,
                'width': 1080,
                'height': 760,
              }
            : {
                'windowState': 'normal',
                'left': -32000,
                'top': -32000,
                'width': 240,
                'height': 200,
              },
      });
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await browser.close();
    } catch (_) {}
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}
  }
}

/// 全进程共享的 Chrome 实例（同一 `--user-data-dir` 只允许一个 Chrome 进程）。
///
/// 播放与 Linux Web 登录共用它：登录一次后 profile 持久化，之后播放不需要再登录；
/// 同一页面按需在「EME 播放页（隐藏）」与「Spotify 登录页（可见）」之间导航。
class LinuxChromeManager {
  LinuxChromeManager._();

  static final LinuxChromeManager instance = LinuxChromeManager._();

  LinuxChrome? _chrome;
  ChromePage? _page;
  Future<void>? _starting;

  bool get isRunning => _chrome != null;

  /// 是否用无窗口的 headless 模式。
  /// 默认 headless（无窗口，音频仍输出到系统）；[visible] 需要窗口时总是窗口模式。
  /// 设 `FLUTIFY_CHROME_WINDOW=1`（或旧的 `FLUTIFY_CHROME_HEADLESS=0`）可强制窗口模式便于排查。
  static bool _desiredHeadless(bool visible) {
    if (visible) return false;
    final forceWindow =
        Platform.environment['FLUTIFY_CHROME_WINDOW'] == '1' ||
        Platform.environment['FLUTIFY_CHROME_HEADLESS'] == '0';
    return !forceWindow;
  }

  /// 取得共享页面（不导航）；[visible] 控制窗口是否可见。
  /// 供播放侧在导航前先订阅页面事件，避免漏掉加载期的事件。
  Future<ChromePage> open({required bool visible}) async {
    // 运行模式不符（headless ↔ 窗口）时重建：不同模式不能复用同一进程。
    if (_chrome != null && _chrome!.isHeadless != _desiredHeadless(visible)) {
      await _chrome!.dispose();
      _chrome = null;
      _page = null;
    }
    // 上一次启动只完成了一半（进程在、页面没附着）：先清掉，避免复用坏状态或重复拉起。
    if (_chrome != null && _page == null) {
      await _chrome!.dispose();
      _chrome = null;
    }
    if (_chrome != null && _page != null && !await _isAlive(_chrome!)) {
      await _chrome!.dispose();
      _chrome = null;
      _page = null;
    }
    if (_chrome == null) {
      _starting ??= _launch(visible);
      try {
        await _starting;
      } finally {
        _starting = null;
      }
    }
    final chrome = _chrome!;
    await chrome.setVisible(visible);
    return _page!;
  }

  /// 取得共享页面并加载 [url]；[visible] 控制窗口是否可见。
  Future<ChromePage> page(Uri url, {required bool visible}) async {
    final page = await open(visible: visible);
    await page.navigate(url.toString());
    await page.loaded.timeout(
      const Duration(seconds: 20),
      onTimeout: () {},
    );
    return page;
  }

  /// 读取当前页面在 [url] 下的全部 cookie（含 HttpOnly）。
  Future<Map<String, String>> cookies(String url) async {
    final page = _page;
    if (page == null) return const {};
    return page.cookies(url);
  }

  Future<void> setVisible(bool visible) async {
    await _chrome?.setVisible(visible);
  }

  /// 清空共享 Chrome 的全部 cookie（登出时清 sp_dc）。
  Future<void> clearBrowserCookies() async {
    final page = _page;
    if (page == null) return;
    try {
      await page.cdp.send('Network.clearBrowserCookies');
    } catch (_) {}
  }

  Future<bool> _isAlive(LinuxChrome chrome) async {
    try {
      return await chrome.process.exitCode
              .timeout(Duration.zero, onTimeout: () => -1) ==
          -1;
    } catch (_) {
      return false;
    }
  }

  Future<void> _launch(bool visible) async {
    final override = Platform.environment['FLUTIFY_CHROME_PROFILE_DIR'];
    final dir = override != null && override.isNotEmpty
        ? Directory(override)
        : Directory(
            '${(await getApplicationSupportDirectory()).path}/chrome-eme-profile',
          );
    final headless = _desiredHeadless(visible);
    final chrome = await LinuxChrome.launch(
      userDataDir: dir,
      headless: headless,
      visible: visible,
      initialUrl: Uri.parse('about:blank'),
    );
    _chrome = chrome;
    try {
      _page = await chrome.attachPage();
    } catch (e) {
      await chrome.dispose();
      _chrome = null;
      _page = null;
      rethrow;
    }
  }

  Future<void> dispose() async {
    await _chrome?.dispose();
    _chrome = null;
    _page = null;
  }
}
