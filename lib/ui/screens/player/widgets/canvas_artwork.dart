import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../../../core/platform/flutify_platform.dart';
import '../../../../core/theme/md3e_shapes.dart';
import '../../../../models/track.dart';
import '../../../../providers/connect_provider.dart';
import '../../../../providers/playback_provider.dart';
import '../../../../providers/preferences_provider.dart';
import '../../../../services/canvas/canvas_service.dart';
import '../../../../services/eme/eme_player.dart';
import '../../../../services/spotify_api_service.dart';
import '../../../widgets/cover_image.dart';

/// Shares the existing artwork bounds and swipe gestures. The muted WebView
/// is only mounted while playback and application visibility permit motion.
class CanvasArtwork extends StatefulWidget {
  final SpotifyTrack track;
  final double size;
  final bool remote;
  final BorderRadius borderRadius;
  const CanvasArtwork({
    super.key,
    required this.track,
    required this.size,
    this.remote = false,
    this.borderRadius = MD3EShapes.roundedExtraLarge,
  });
  @override
  State<CanvasArtwork> createState() => _CanvasArtworkState();
}

class _CanvasArtworkState extends State<CanvasArtwork>
    with WidgetsBindingObserver {
  CanvasMedia? _media;
  String? _requested;
  bool _foreground = true;
  bool _ready = false;
  bool _failed = false;
  int _revision = 0;
  int _viewRevision = 0;
  bool _videoMounted = false;
  bool _envReady = !Platform.isWindows || EmePlayer.cachedEnvironment != null;
  String? _videoHtml;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!_envReady) {
      EmePlayer.ensureEnvironment().then((_) {
        if (mounted) setState(() => _envReady = true);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted)
      setState(() => _foreground = state == AppLifecycleState.resumed);
  }

  @override
  void didUpdateWidget(covariant CanvasArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.track.uri != oldWidget.track.uri) {
      _revision++;
      _requested = null;
      _media = null;
      _videoHtml = null;
      _viewRevision++;
      _videoMounted = false;
      _ready = _failed = false;
      _timeout?.cancel();
    }
  }

  void _request(SpotifyApiService api) {
    final uri = widget.track.uri;
    _requested = uri;
    final revision = ++_revision;
    api.canvas.get(uri).then((media) {
      if (mounted && revision == _revision) {
        setState(() {
          _media = media;
          _videoHtml = media != null && media.canvas.isVideo
              ? _html(media)
              : null;
        });
      }
    });
  }

  void _fail(int revision) {
    if (!mounted || revision != _viewRevision) return;
    _timeout?.cancel();
    setState(() => _failed = true);
  }

  @override
  void dispose() {
    _revision++;
    _viewRevision++;
    _timeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<PreferencesProvider?, bool>(
      (p) => p?.prefs.canvasEnabled ?? true,
    );
    final playing = widget.remote
        ? context.select<ConnectProvider?, bool>(
            (p) => p?.player.isAudible ?? false,
          )
        : context.select<PlaybackProvider?, bool>((p) => p?.isPlaying ?? false);
    final active =
        enabled &&
        playing &&
        _foreground &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    final api = context.read<SpotifyApiService?>();
    if (active && api != null && api.isConfigured && _requested == null)
      _request(api);
    final media = _media;
    final cover = CoverImage(
      url: widget.track.coverUrl,
      size: widget.size,
      borderRadius: widget.borderRadius,
    );
    // Linux 桌面没有内嵌 WebView，Canvas 视频无法播放；Windows 需等共享 WebView2 环境就绪再挂载。
    final videoPlayable = _envReady && !FlutifyPlatform.isLinuxDesktop;
    if (!active ||
        media == null ||
        _failed ||
        (media.canvas.isVideo && !videoPlayable)) {
      if (_videoMounted) {
        _viewRevision++;
        _videoMounted = false;
      }
      _ready = false;
      _timeout?.cancel();
      return cover;
    }
    if (media.canvas.isVideo && !_videoMounted) {
      _videoMounted = true;
      _viewRevision++;
    }
    final viewRevision = _viewRevision;
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: SizedBox.square(
        dimension: widget.size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            cover,
            if (!media.canvas.isVideo)
              Image.memory(
                media.bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => cover,
              )
            else ...[
              IgnorePointer(
                child: InAppWebView(
                  key: ValueKey('${widget.track.uri}:$viewRevision'),
                  webViewEnvironment: EmePlayer.cachedEnvironment,
                  initialSettings: InAppWebViewSettings(
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    transparentBackground: true,
                    disableContextMenu: true,
                  ),
                  initialData: InAppWebViewInitialData(data: _videoHtml!),
                  onWebViewCreated: (controller) {
                    if (!mounted || viewRevision != _viewRevision) return;
                    _timeout?.cancel();
                    _timeout = Timer(
                      const Duration(seconds: 10),
                      () => _fail(viewRevision),
                    );
                    controller.addJavaScriptHandler(
                      handlerName: 'canvasReady',
                      callback: (_) {
                        if (!mounted || viewRevision != _viewRevision) return;
                        _timeout?.cancel();
                        setState(() => _ready = true);
                      },
                    );
                    controller.addJavaScriptHandler(
                      handlerName: 'canvasError',
                      callback: (_) => _fail(viewRevision),
                    );
                  },
                  onReceivedError: (_, _, _) => _fail(viewRevision),
                ),
              ),
              if (!_ready) IgnorePointer(child: cover),
            ],
          ],
        ),
      ),
    );
  }

  String _html(CanvasMedia media) =>
      '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}video{width:100%;height:100%;object-fit:cover}</style>
</head><body><video id="v" muted loop playsinline disablepictureinpicture src="data:video/mp4;base64,${base64Encode(media.bytes)}"></video>
<script>const v=document.getElementById('v');v.muted=true;v.volume=0;
function start(){v.play().catch(()=>window.flutter_inappwebview.callHandler('canvasError'));}
v.onplaying=()=>window.flutter_inappwebview.callHandler('canvasReady');
v.onerror=()=>window.flutter_inappwebview.callHandler('canvasError');
document.addEventListener('visibilitychange',()=>document.hidden?v.pause():start());
if(window.flutter_inappwebview&&window.flutter_inappwebview.callHandler)start();else window.addEventListener('flutterInAppWebViewPlatformReady',start);
</script></body></html>''';
}
