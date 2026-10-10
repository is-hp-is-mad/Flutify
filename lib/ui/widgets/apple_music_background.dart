import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/flutify_tokens.dart';

/// A tiny native Canvas texture, enlarged by Flutter rather than blurred at
/// screen resolution. One instance owns artwork transitions across player tabs.
class AppleMusicBackground extends StatefulWidget {
  const AppleMusicBackground({
    super.key,
    required this.imageUrl,
    this.reducedEffects = false,
  });

  final String imageUrl;
  final bool reducedEffects;

  @override
  State<AppleMusicBackground> createState() => _AppleMusicBackgroundState();
}

class _AppleMusicBackgroundState extends State<AppleMusicBackground>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.flutify/apple_music_background');
  int? _texture;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  String? _loadedUrl;
  int _revision = 0;
  Uint8List? _bytes;
  bool _imageReady = false;
  bool _foreground = true;
  bool _configurationScheduled = false;
  Map<String, Object>? _configuration;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    unawaited(_create());
  }

  Future<void> _send(String method, Map<String, Object?> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      // A lost native surface must not take down playback or the lyrics UI.
    } on MissingPluginException {
      // Headless widget tests and unsupported runtimes keep the black fallback.
    }
  }

  Future<void> _create() async {
    try {
      final id = await _channel.invokeMethod<int>('create');
      if (id == null) return;
      if (!mounted) {
        await _send('dispose', {'id': id});
        return;
      }
      setState(() => _texture = id);
      if (_imageReady) unawaited(_send('artwork', {'id': id, 'bytes': _bytes}));
      if (_configuration != null) {
        unawaited(_send('configure', {'id': id, ..._configuration!}));
      }
    } on PlatformException {
      // No native texture available: retain a readable, static background.
    } on MissingPluginException {
      // See _send.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadArtwork();
  }

  @override
  void didUpdateWidget(AppleMusicBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadArtwork();
  }

  void _loadArtwork() {
    if (_loadedUrl == widget.imageUrl) return;
    _loadedUrl = widget.imageUrl;
    final revision = ++_revision;
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    _imageReady = false;
    if (widget.imageUrl.isEmpty) {
      _acceptArtwork(null, revision);
      return;
    }
    final provider = ResizeImage(
      CachedNetworkImageProvider(widget.imageUrl),
      width: 128,
      height: 128,
      policy: ResizeImagePolicy.fit,
    );
    _stream = provider.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) async {
        try {
          final data = await info.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          _acceptArtwork(data?.buffer.asUint8List(), revision);
        } catch (_) {
          _acceptArtwork(null, revision);
        } finally {
          info.dispose();
        }
      },
      onError: (Object error, StackTrace? stack) =>
          _acceptArtwork(null, revision),
    );
    _stream!.addListener(_listener!);
  }

  void _acceptArtwork(Uint8List? bytes, int revision) {
    if (!mounted || revision != _revision) return;
    _bytes = bytes;
    _imageReady = true;
    if (_texture != null) {
      unawaited(_send('artwork', {'id': _texture, 'bytes': bytes}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => _foreground = state == AppLifecycleState.resumed);
      // Hidden/paused applications may never receive another frame. Stop the
      // worker now, and prevent a pending create() from replaying active=true.
      final configuration = _configuration;
      if (!_foreground &&
          configuration != null &&
          configuration['active'] != false) {
        _configuration = {...configuration, 'active': false};
        if (_texture != null) {
          unawaited(_send('configure', {'id': _texture, ..._configuration!}));
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_listener != null) _stream?.removeListener(_listener!);
    if (_texture != null) unawaited(_send('dispose', {'id': _texture}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final density = MediaQuery.devicePixelRatioOf(context);
    final reducedMotion = context.reduceMotion;
    final active =
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !reducedMotion &&
        !context.tokens.powerSaving;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, box) {
            final configuration = <String, Object>{
              'width': (box.maxWidth * density).round().clamp(1, 8192),
              'height': (box.maxHeight * density).round().clamp(1, 8192),
              'density': density,
              'active': active,
              'reducedEffects': widget.reducedEffects,
              'reduceMotion': reducedMotion,
              'dark': dark,
            };
            if (!mapEquals(configuration, _configuration)) {
              _configuration = configuration;
              if (!_configurationScheduled) {
                _configurationScheduled = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _configurationScheduled = false;
                  if (mounted && _texture != null) {
                    unawaited(
                      _send('configure', {'id': _texture, ..._configuration!}),
                    );
                  }
                });
              }
            }
            return ColoredBox(
              color: Colors.black,
              child: _texture == null
                  ? const SizedBox.expand()
                  : Texture(
                      textureId: _texture!,
                      filterQuality: FilterQuality.low,
                    ),
            );
          },
        ),
      ),
    );
  }
}
