import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/flutify_platform.dart';

/// 将 fMP4（`moof` -> `traf` -> `tfdt`）的首个 `baseMediaDecodeTime` 归零。
///
/// Apple Music 的 HLS fMP4 常从 10s 开始计时；归零后在 macOS AVPlayer、
/// Windows / Linux libmpv 以及 Android ExoPlayer 上都能从 0s 立即起播并无缝循环。
@visibleForTesting
Uint8List normalizeFmp4Tfdt(Uint8List bytes) {
  if (bytes.length < 16) return bytes;
  final view = ByteData.sublistView(bytes);
  int? baseTime;
  final patches = <({int offset, int version, int value})>[];

  void scanBoxes(int start, int end) {
    var pos = start;
    while (pos + 8 <= end) {
      var boxSize = view.getUint32(pos);
      final type = view.getUint32(pos + 4);
      var headerSize = 8;
      if (boxSize == 1) {
        if (pos + 16 > end) break;
        boxSize = view.getUint64(pos + 8);
        headerSize = 16;
      } else if (boxSize == 0) {
        boxSize = end - pos;
      }
      if (boxSize < headerSize || pos + boxSize > end) break;
      final boxEnd = pos + boxSize;

      // 'moof' = 0x6d6f6f66, 'traf' = 0x74726166, 'tfdt' = 0x74666474
      if (type == 0x6d6f6f66 || type == 0x74726166) {
        scanBoxes(pos + headerSize, boxEnd);
      } else if (type == 0x74666474 && pos + headerSize + 4 <= boxEnd) {
        final version = bytes[pos + headerSize];
        final timeOffset = pos + headerSize + 4;
        if (version == 0 && timeOffset + 4 <= boxEnd) {
          final t = view.getUint32(timeOffset);
          baseTime ??= t;
          if (baseTime! > 0 && t >= baseTime!) {
            patches.add((offset: timeOffset, version: 0, value: t - baseTime!));
          }
        } else if (version == 1 && timeOffset + 8 <= boxEnd) {
          final t = view.getUint64(timeOffset);
          baseTime ??= t;
          if (baseTime! > 0 && t >= baseTime!) {
            patches.add((offset: timeOffset, version: 1, value: t - baseTime!));
          }
        }
      }
      pos = boxEnd;
    }
  }

  scanBoxes(0, bytes.length);
  if (patches.isEmpty || (baseTime ?? 0) == 0) return bytes;

  final copy = Uint8List.fromList(bytes);
  final outView = ByteData.sublistView(copy);
  for (final p in patches) {
    if (p.version == 0) {
      outView.setUint32(p.offset, p.value);
    } else {
      outView.setUint64(p.offset, p.value);
    }
  }
  return copy;
}

/// 静音循环播放一段 MP4（铺满、居中裁切），四端均走原生纹理（`com.flutify/motion_video`）：
///
/// - Android：ExoPlayer 硬解到 Flutter `SurfaceProducer` 纹理；
/// - Windows：libmpv 解码到 Flutter PixelBuffer 纹理；
/// - Linux：libmpv 解码到 Flutter `FlPixelBufferTexture` 纹理；
/// - macOS：AVPlayer + `AVPlayerItemVideoOutput` 硬解到 Flutter `CVPixelBuffer` 纹理。
///
/// 第一帧出现前、失败或超时时显示 [placeholder]；[playing] 为 false 时保留播放器、停在当前帧；
/// [active] 为 false 时不创建原生播放器，直接显示 [placeholder]。
class MotionVideo extends StatelessWidget {
  final Uint8List? bytes;
  final String? url;
  final Widget placeholder;
  final bool active;
  final bool playing;

  const MotionVideo({
    super.key,
    this.bytes,
    this.url,
    required this.placeholder,
    this.active = true,
    this.playing = true,
  }) : assert(bytes != null || url != null, 'bytes 或 url 至少传一个');

  @override
  Widget build(BuildContext context) {
    if (FlutifyPlatform.isTest || !active) return placeholder;
    final hasBytes = bytes != null && bytes!.isNotEmpty;
    final hasUrl = url != null && url!.startsWith('https://');
    if (!hasBytes && !hasUrl) return placeholder;
    return _TextureMotionVideo(
      bytes: hasBytes ? bytes : null,
      url: hasBytes ? null : url,
      placeholder: placeholder,
      playing: playing,
    );
  }
}

/// 原生纹理实现：每个实例对应原生侧一个播放器，纹理 id 即实例 id。
class _TextureMotionVideo extends StatefulWidget {
  final Uint8List? bytes;
  final String? url;
  final Widget placeholder;
  final bool playing;

  const _TextureMotionVideo({
    required this.bytes,
    required this.url,
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
        state._timeout?.cancel();
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
  Timer? _timeout;

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
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.url != widget.url) {
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

  void _armTimeout(int revision) {
    _timeout?.cancel();
    if (!_shouldPlay || _ready) return;
    _timeout = Timer(const Duration(seconds: 10), () {
      if (mounted && revision == _revision && !_ready && _shouldPlay) {
        _fail();
      }
    });
  }

  Future<void> _create() async {
    final revision = _revision;
    final playing = _shouldPlay;
    _armTimeout(revision);
    try {
      final rawBytes = widget.bytes;
      final normalized = rawBytes != null ? normalizeFmp4Tfdt(rawBytes) : null;
      final id = await _channel.invokeMethod<int>('create', {
        'bytes': ?normalized,
        'url': ?widget.url,
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
    if (playing && !_ready) {
      _armTimeout(_revision);
    } else if (!playing) {
      _timeout?.cancel();
    }
    if (id == null || _sentPlaying == playing) return;
    _sentPlaying = playing;
    _channel
        .invokeMethod<void>('setPlaying', {'id': id, 'playing': playing})
        .catchError((Object _) {});
  }

  void _release() {
    _revision++;
    _timeout?.cancel();
    _timeout = null;
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
