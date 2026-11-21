import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/platform/flutify_platform.dart';
import '../../services/eme/eme_player.dart';
import 'mpv_looping_video.dart';

/// 静音循环播放一段 MP4（铺满、居中裁切）。
///
/// 第一帧出现前、失败或超时时显示 [placeholder]（通常是同一位艺人的静态照片），
/// 因此调用方总能直接叠在照片上。[playing] 为 false 时保留播放器、停在当前帧。
///
/// - Android：原生 ExoPlayer 硬解到 Flutter 纹理（`MotionVideoPlugin`），与页面同层合成，
///   滚动、缩放都不经过平台视图；应用退到后台或页面被盖住时自动暂停。
/// - Windows / macOS / Linux：media_kit（libmpv）硬解到 Flutter 纹理，与 Android 同等效果。
/// - iOS：内容以 data: URL 交给内嵌 WebView 的 `<video>`，CSP 禁止一切网络请求。
class MotionVideo extends StatelessWidget {
  final Uint8List bytes;
  final Widget placeholder;
  final bool playing;

  const MotionVideo({
    super.key,
    required this.bytes,
    required this.placeholder,
    this.playing = true,
  });

  @override
  Widget build(BuildContext context) {
    if (FlutifyPlatform.isTest) return placeholder;
    if (!kIsWeb && Platform.isAndroid) {
      return _TextureMotionVideo(
        bytes: bytes,
        placeholder: placeholder,
        playing: playing,
      );
    }
    // 桌面端（Windows / macOS / Linux）：media_kit 纹理播放
    if (mpvVideoSupported) {
      return MpvLoopingVideo(
        bytes: bytes,
        placeholder: placeholder,
        playing: playing,
      );
    }
    // iOS 仍走 WebView；不支持 WebView 的平台显示占位
    if (!FlutifyPlatform.supportsInAppWebView) return placeholder;
    return _WebMotionVideo(bytes: bytes, placeholder: placeholder);
  }
}

/// Android 纹理实现：每个实例对应原生侧一个播放器，纹理 id 即实例 id。
class _TextureMotionVideo extends StatefulWidget {
  final Uint8List bytes;
  final Widget placeholder;
  final bool playing;

  const _TextureMotionVideo({
    required this.bytes,
    required this.placeholder,
    required this.playing,
  });

  @override
  State<_TextureMotionVideo> createState() => _TextureMotionVideoState();
}

class _TextureMotionVideoState extends State<_TextureMotionVideo>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel(
    'com.flutify/motion_video',
  );
  static final Map<int, _TextureMotionVideoState> _live = {};
  static bool _handlerSet = false;

  static Future<void> _onNativeEvent(MethodCall call) async {
    final args = call.arguments;
    if (args is! Map) return;
    final state = _live[(args['id'] as num?)?.toInt()];
    if (state == null || !state.mounted) return;
    switch (call.method) {
      case 'size':
        final width = (args['width'] as num?)?.toDouble() ?? 0;
        final height = (args['height'] as num?)?.toDouble() ?? 0;
        if (width > 0 && height > 0) {
          state.setState(() => state._size = Size(width, height));
        }
      case 'ready':
        state.setState(() => state._ready = true);
      case 'error':
        state._fail();
    }
  }

  int? _id;
  Size? _size;
  bool _ready = false;
  bool _failed = false;
  bool _foreground = true;
  bool _visible = true;

  /// 已告知原生侧的播放状态，避免重复调用。
  bool? _sentPlaying;

  /// 内容变化或销毁时递增，作废还在路上的 create 结果。
  int _revision = 0;

  bool get _shouldPlay => widget.playing && _foreground && _visible;

  @override
  void initState() {
    super.initState();
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler(_onNativeEvent);
    }
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _create();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面被其他不透明页面盖住时 TickerMode 关闭，视频跟着停
    _visible = TickerMode.valuesOf(context).enabled;
    _syncPlaying();
  }

  @override
  void didUpdateWidget(covariant _TextureMotionVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _release();
      _size = null;
      _ready = _failed = false;
      _create();
    } else {
      _syncPlaying();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncPlaying();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    super.dispose();
  }

  Future<void> _create() async {
    final revision = _revision;
    final playing = _shouldPlay;
    try {
      final id = await _channel.invokeMethod<int>('create', {
        'bytes': widget.bytes,
        'playing': playing,
      });
      if (id == null) return _fail();
      if (!mounted || revision != _revision) {
        _disposeNative(id);
        return;
      }
      _live[id] = this;
      _sentPlaying = playing;
      setState(() => _id = id);
      _syncPlaying();
    } catch (_) {
      if (mounted && revision == _revision) _fail();
    }
  }

  void _syncPlaying() {
    final id = _id;
    final playing = _shouldPlay;
    if (id == null || _sentPlaying == playing) return;
    _sentPlaying = playing;
    _channel
        .invokeMethod<void>('setPlaying', {'id': id, 'playing': playing})
        .catchError((Object _) {});
  }

  void _release() {
    _revision++;
    final id = _id;
    _id = null;
    _sentPlaying = null;
    if (id == null) return;
    _live.remove(id);
    _disposeNative(id);
  }

  static void _disposeNative(int id) {
    _channel
        .invokeMethod<void>('dispose', {'id': id})
        .catchError((Object _) {});
  }

  void _fail() {
    if (!mounted) return;
    _release();
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    final size = _size;
    if (_failed) return widget.placeholder;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (id != null && size != null)
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: Texture(textureId: id),
            ),
          ),
        // 照片盖在视频上，第一帧出来后淡出，不会有黑帧
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _ready ? 0 : 1,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
            child: widget.placeholder,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// iOS：WebView base64 播放（保留兼容）
// ---------------------------------------------------------------------------

class _WebMotionVideo extends StatefulWidget {
  final Uint8List bytes;
  final Widget placeholder;

  const _WebMotionVideo({required this.bytes, required this.placeholder});

  @override
  State<_WebMotionVideo> createState() => _WebMotionVideoState();
}

class _WebMotionVideoState extends State<_WebMotionVideo> {
  late String _html = _buildHtml(widget.bytes);
  int _revision = 0;
  bool _ready = false;
  bool _failed = false;
  Timer? _timeout;

  @override
  void didUpdateWidget(covariant _WebMotionVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _timeout?.cancel();
      _revision++;
      _html = _buildHtml(widget.bytes);
      _ready = _failed = false;
    }
  }

  @override
  void dispose() {
    _revision++;
    _timeout?.cancel();
    super.dispose();
  }

  void _fail(int revision) {
    if (!mounted || revision != _revision) return;
    _timeout?.cancel();
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.placeholder;
    final revision = _revision;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.placeholder,
        IgnorePointer(
          child: InAppWebView(
            key: ValueKey(revision),
            webViewEnvironment: EmePlayer.cachedEnvironment,
            initialSettings: InAppWebViewSettings(
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              transparentBackground: true,
              disableContextMenu: true,
              supportZoom: false,
              disableHorizontalScroll: true,
              disableVerticalScroll: true,
            ),
            initialData: InAppWebViewInitialData(data: _html),
            onWebViewCreated: (controller) {
              if (!mounted || revision != _revision) return;
              _timeout?.cancel();
              _timeout = Timer(
                const Duration(seconds: 10),
                () => _fail(revision),
              );
              controller.addJavaScriptHandler(
                handlerName: 'videoReady',
                callback: (_) {
                  if (!mounted || revision != _revision) return;
                  _timeout?.cancel();
                  setState(() => _ready = true);
                },
              );
              controller.addJavaScriptHandler(
                handlerName: 'videoError',
                callback: (_) => _fail(revision),
              );
            },
            onReceivedError: (_, _, _) => _fail(revision),
          ),
        ),
        // 照片盖在 WebView 上直到第一帧出现，避免透明 / 黑色闪烁
        if (!_ready) IgnorePointer(child: widget.placeholder),
      ],
    );
  }

  static String _buildHtml(Uint8List bytes) =>
      '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}video{width:100%;height:100%;object-fit:cover}</style>
</head><body><video id="v" muted loop playsinline disablepictureinpicture src="data:video/mp4;base64,${base64Encode(bytes)}"></video>
<script>const v=document.getElementById('v');v.muted=true;v.volume=0;
function start(){v.play().catch(()=>window.flutter_inappwebview.callHandler('videoError'));}
v.onplaying=()=>window.flutter_inappwebview.callHandler('videoReady');
v.onerror=()=>window.flutter_inappwebview.callHandler('videoError');
document.addEventListener('visibilitychange',()=>document.hidden?v.pause():start());
if(window.flutter_inappwebview&&window.flutter_inappwebview.callHandler)start();else window.addEventListener('flutterInAppWebViewPlatformReady',start);
</script></body></html>''';
}
