import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/platform/flutify_platform.dart';
import '../../services/eme/eme_player.dart';
import 'cover_image.dart';

/// 静音循环的竖版短视频（官方 Canvas / 发现流卡片）：直接流式播放 CDN 地址。
///
/// 与播放页 CanvasArtwork 同为内嵌 WebView `<video muted loop playsinline>`，但不整段下载转
/// base64，而是让 WebView 直接拉 https 地址（canvaz.scdn.co 公开可读）。
///
/// 性能约定（WebView 是平台视图，同屏越少越流畅）：
/// - 只有 [active] 为 true 时才创建 WebView，否则只画 [posterUrl]（视频首帧，切换无跳变）；
/// - [playing] 只控制已创建的视频暂停 / 继续（轻点暂停时不销毁，避免画面闪回首帧）；
/// - 封面始终叠在视频上方，首帧出来后淡出，不对平台视图本身做透明度动画；
/// - Android 用纹理合成（不开 hybrid composition），避免平台线程合并拖慢整页渲染；
/// - 加载失败 / 10 秒超时 / Linux 桌面（无内嵌 WebView）一律只显示封面。
class LoopingVideo extends StatefulWidget {
  const LoopingVideo({
    super.key,
    required this.videoUrl,
    this.posterUrl = '',
    this.active = true,
    this.playing = true,
  });

  final String videoUrl;

  /// 视频首帧 / 封面；视频未就绪或未激活时显示。
  final String posterUrl;

  /// 是否创建视频（不在屏幕焦点上的卡片传 false）。
  final bool active;

  /// 已创建的视频是否播放。
  final bool playing;

  @override
  State<LoopingVideo> createState() => _LoopingVideoState();
}

class _LoopingVideoState extends State<LoopingVideo> {
  InAppWebViewController? _controller;
  Timer? _timeout;
  bool _ready = false;
  bool _failed = false;

  /// 地址变化或 WebView 重建时递增，作废旧 WebView 的回调。
  int _revision = 0;

  @override
  void didUpdateWidget(covariant LoopingVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        (oldWidget.active && !widget.active)) {
      // 换片或取消激活：旧 WebView 随之移除，状态复位（重新激活时重新加载，CDN 有缓存）。
      _reset(clearFailure: oldWidget.videoUrl != widget.videoUrl);
    } else if (oldWidget.playing != widget.playing) {
      if (widget.playing && !_ready) _armTimeout(_revision);
      _run(
        widget.playing
            ? "var v=document.getElementById('v'); if(v){v.play().catch(function(){});}"
            : "var v=document.getElementById('v'); if(v){v.pause();}",
      );
    }
  }

  void _reset({required bool clearFailure}) {
    _revision++;
    _timeout?.cancel();
    _controller = null;
    _ready = false;
    if (clearFailure) _failed = false;
  }

  @override
  void dispose() {
    _revision++;
    _timeout?.cancel();
    _controller = null;
    super.dispose();
  }

  /// 只在应当播放时计时：暂停创建的视频不会触发 playing，不能算失败。
  void _armTimeout(int revision) {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 10), () {
      if (!_ready && widget.playing) _fail(revision);
    });
  }

  void _fail(int revision) {
    if (!mounted || revision != _revision) return;
    _timeout?.cancel();
    // 失败后 WebView 会被移除，控制器随之失效，不能再用。
    _controller = null;
    setState(() => _failed = true);
  }

  /// 在视频页里执行脚本；WebView 可能已被平台回收（页面压栈、列表回收），失败一律忽略。
  void _run(String source) {
    final controller = _controller;
    if (controller == null) return;
    void forget(Object _) {
      if (identical(_controller, controller)) _controller = null;
    }

    try {
      controller.evaluateJavascript(source: source).catchError((Object e) {
        forget(e);
        return null;
      });
    } catch (e) {
      forget(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final poster = CoverImage(url: widget.posterUrl);
    final canPlay =
        widget.active &&
        widget.videoUrl.startsWith('https://') &&
        !FlutifyPlatform.isLinuxDesktop &&
        !_failed;
    if (!canPlay) return poster;
    final revision = _revision;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: InAppWebView(
            key: ValueKey('${widget.videoUrl}:$revision'),
            webViewEnvironment: EmePlayer.cachedEnvironment,
            initialSettings: InAppWebViewSettings(
              mediaPlaybackRequiresUserGesture: false,
              allowsInlineMediaPlayback: true,
              transparentBackground: true,
              disableContextMenu: true,
              disableVerticalScroll: true,
              disableHorizontalScroll: true,
              useHybridComposition: false,
            ),
            initialData: InAppWebViewInitialData(
              data: _html(widget.videoUrl, widget.playing),
            ),
            onWebViewCreated: (controller) {
              if (!mounted || revision != _revision) return;
              _controller = controller;
              if (widget.playing) _armTimeout(revision);
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
        // 封面盖在视频上，首帧出来后淡出（透明度动画只作用于普通图片层）。
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _ready ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: poster,
          ),
        ),
      ],
    );
  }

  /// 视频页：只允许加载 https 媒体；首次 playing 事件通知就绪；初始是否播放由 [playing] 决定。
  static String _html(String url, bool playing) {
    final src = const HtmlEscape(HtmlEscapeMode.attribute).convert(url);
    return '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src https:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}video{width:100%;height:100%;object-fit:cover}</style>
</head><body><video id="v" muted loop playsinline disablepictureinpicture preload="auto" src="$src"></video>
<script>const v=document.getElementById('v');v.muted=true;v.volume=0;
let told=false;
function send(n){if(window.flutter_inappwebview&&window.flutter_inappwebview.callHandler){window.flutter_inappwebview.callHandler(n);}}
v.onplaying=()=>{if(!told){told=true;send('videoReady');}};
v.onerror=()=>send('videoError');
function start(){${playing ? "v.play().catch(()=>{});" : "v.load();"}}
if(window.flutter_inappwebview&&window.flutter_inappwebview.callHandler)start();else window.addEventListener('flutterInAppWebViewPlatformReady',start);
</script></body></html>''';
  }
}
