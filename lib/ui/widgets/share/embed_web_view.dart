import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/l10n.dart';
import '../../../models/share_target.dart';
import '../../../services/eme/eme_player.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;
import '../flutify_progress.dart';

/// 系统 WebView 中加载官方嵌入页。不可用时明确提示，iframe 代码仍可复制。
class EmbedWebView extends StatefulWidget {
  final ShareTarget target;
  final EmbedSize size;
  final bool dark;

  const EmbedWebView({
    super.key,
    required this.target,
    required this.size,
    required this.dark,
  });

  static bool enabled =
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS) &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  State<EmbedWebView> createState() => _EmbedWebViewState();
}

class _EmbedWebViewState extends State<EmbedWebView> {
  bool _ready = false;
  bool _loaded = false;
  bool _failed = false;
  bool _unavailable = false;
  int _attempt = 0;
  Timer? _timeout;

  String get _url => widget.target.embedUrl(dark: widget.dark);

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final attempt = ++_attempt;
    try {
      if (!EmbedWebView.enabled ||
          (Platform.isWindows &&
              await WebViewEnvironment.getAvailableVersion() == null)) {
        if (mounted) setState(() => _unavailable = true);
        return;
      }
      // 分享可以先于播放器打开：等待共享环境，避免与默认环境争用数据目录。
      await EmePlayer.ensureEnvironment();
      if (!mounted || attempt != _attempt) return;
      setState(() => _ready = true);
      _timeout = Timer(const Duration(seconds: 25), () => _fail(attempt));
    } catch (_) {
      _fail(attempt);
    }
  }

  void _fail(int attempt) {
    if (!mounted || attempt != _attempt) return;
    _timeout?.cancel();
    setState(() => _failed = true);
  }

  void _retry() {
    _timeout?.cancel();
    setState(() {
      _ready = false;
      _loaded = false;
      _failed = false;
      _unavailable = false;
    });
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  bool _isEmbedPage(WebUri? uri) =>
      uri == null ||
      uri.scheme == 'about' ||
      (uri.host == 'open.spotify.com' && uri.path.startsWith('/embed/'));

  void _openExternally(WebUri? uri) {
    if (uri == null || !['https', 'http', 'spotify'].contains(uri.scheme))
      return;
    unawaited(
      launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      ).catchError((_) => false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final attempt = _attempt;
    return SizedBox(
      height: widget.size.height.toDouble(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _failed || _unavailable
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            _unavailable
                                ? l10n.shareEmbedUnavailable
                                : l10n.shareEmbedFailed,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        M3EButton.text(
                          onPressed: _retry,
                          child: Text(l10n.commonRetry),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (_ready)
                    InAppWebView(
                      key: ValueKey(attempt),
                      webViewEnvironment: EmePlayer.cachedEnvironment,
                      initialUrlRequest: URLRequest(url: WebUri(_url)),
                      initialSettings: InAppWebViewSettings(
                        transparentBackground: true,
                        disableContextMenu: true,
                        supportZoom: false,
                        useShouldOverrideUrlLoading: true,
                        mediaPlaybackRequiresUserGesture: true,
                      ),
                      onLoadStop: (_, _) {
                        if (!mounted || attempt != _attempt) return;
                        _timeout?.cancel();
                        setState(() => _loaded = true);
                      },
                      onReceivedError: (_, request, _) {
                        if (request.isForMainFrame ?? true) _fail(attempt);
                      },
                      onReceivedHttpError: (_, request, response) {
                        if ((request.isForMainFrame ?? true) &&
                            (response.statusCode ?? 0) >= 400)
                          _fail(attempt);
                      },
                      shouldOverrideUrlLoading: (_, action) async {
                        if (action.isForMainFrame == false ||
                            _isEmbedPage(action.request.url)) {
                          return NavigationActionPolicy.ALLOW;
                        }
                        _openExternally(action.request.url);
                        return NavigationActionPolicy.CANCEL;
                      },
                      onCreateWindow: (_, action) async {
                        _openExternally(action.request.url);
                        return false;
                      },
                    ),
                  // 保持 WebView 绘制，加载条仅覆盖顶部。
                  if (!_loaded)
                    const Align(
                      alignment: Alignment.topCenter,
                      child: FlutifyLinearProgress(),
                    ),
                ],
              ),
      ),
    );
  }
}
