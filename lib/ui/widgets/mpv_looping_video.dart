import 'dart:async';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:path_provider/path_provider.dart';

/// 桌面三平台是否可用 media_kit 原生视频纹理。
bool get mpvVideoSupported =>
    !kIsWeb &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 静音循环播放一段视频到 Flutter 纹理（media_kit / libmpv），桌面全平台通用。
///
/// 两种输入源二选一：
/// - [url]：HTTPS CDN 地址（发现流短视频、Canvas 动画封面），media_kit 直接流式播放；
/// - [bytes]：内存中的 fMP4（艺人动态视频，Apple Music HLS 下载后），写临时文件播放。
///
/// [playing] 控制暂停 / 继续；[active] 控制是否创建播放器（false 时释放资源只显示占位）。
/// 第一帧渲染前始终显示 [placeholder]，失败或超时也退回占位。
class MpvLoopingVideo extends StatefulWidget {
  final String? url;
  final Uint8List? bytes;
  final Widget placeholder;
  final bool active;
  final bool playing;

  const MpvLoopingVideo({
    super.key,
    this.url,
    this.bytes,
    required this.placeholder,
    this.active = true,
    this.playing = true,
  }) : assert(url != null || bytes != null, 'url 或 bytes 至少传一个');

  @override
  State<MpvLoopingVideo> createState() => _MpvLoopingVideoState();
}

class _MpvLoopingVideoState extends State<MpvLoopingVideo>
    with WidgetsBindingObserver {
  mk.Player? _player;
  mkv.VideoController? _controller;
  File? _tmpFile;
  bool _ready = false;
  bool _failed = false;
  bool _foreground = true;
  bool _visible = true;
  int _revision = 0;
  Timer? _timeout;
  StreamSubscription<bool>? _playingSub;

  bool get _shouldPlay => widget.playing && _foreground && _visible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (widget.active) _create();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _syncPlaying();
  }

  @override
  void didUpdateWidget(covariant MpvLoopingVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = oldWidget.url != widget.url ||
        !identical(oldWidget.bytes, widget.bytes);

    if (sourceChanged || (oldWidget.active && !widget.active)) {
      _release();
      _ready = _failed = false;
      if (widget.active) _create();
    } else if (!oldWidget.active && widget.active) {
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
    final revision = ++_revision;
    try {
      String mediaUri;
      if (widget.url != null && widget.url!.isNotEmpty) {
        // HTTPS CDN 地址——media_kit 直接流式播放
        mediaUri = widget.url!;
      } else if (widget.bytes != null) {
        // 内存 bytes → 临时文件
        final dir = await getTemporaryDirectory();
        final cacheDir = Directory('${dir.path}/mpv_looping_video');
        if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
        final file = File('${cacheDir.path}/$revision.mp4');
        await file.writeAsBytes(widget.bytes!, flush: true);
        if (!mounted || revision != _revision) {
          file.deleteSync();
          return;
        }
        _tmpFile = file;
        mediaUri = file.uri.toString();
      } else {
        return;
      }

      final player = mk.Player(
        configuration: const mk.PlayerConfiguration(
          // 装饰性视频：不参与音频焦点，不干扰正在播的音乐
          title: 'Looping Video',
        ),
      );
      await player.setVolume(0);
      await player.setPlaylistMode(mk.PlaylistMode.loop);

      if (!mounted || revision != _revision) {
        await player.dispose();
        _tmpFile?.deleteSync();
        _tmpFile = null;
        return;
      }

      final controller = mkv.VideoController(player);
      _player = player;
      _controller = controller;

      // 10 秒超时
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 10), () {
        if (mounted && revision == _revision && !_ready) {
          setState(() => _failed = true);
        }
      });

      // 监听 playing 状态探测第一帧
      _playingSub = player.stream.playing.listen((playing) {
        if (playing && mounted && revision == _revision && !_ready) {
          _timeout?.cancel();
          setState(() => _ready = true);
        }
      });

      await player.open(mk.Media(mediaUri));
      if (!mounted || revision != _revision) {
        _release();
        return;
      }
      _syncPlaying();
      setState(() {}); // 触发 build 以显示纹理
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _failed = true);
      }
    }
  }

  void _syncPlaying() {
    final player = _player;
    if (player == null) return;
    final playing = _shouldPlay;
    if (playing) {
      player.play();
    } else {
      player.pause();
    }
  }

  void _release() {
    _revision++;
    _timeout?.cancel();
    _timeout = null;
    _playingSub?.cancel();
    _playingSub = null;
    _player?.dispose();
    _player = null;
    _controller = null;
    final file = _tmpFile;
    _tmpFile = null;
    if (file != null && file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || !widget.active) return widget.placeholder;
    final controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (controller != null)
          mkv.Video(
            controller: controller,
            fit: BoxFit.cover,
            controls: mkv.NoVideoControls,
          ),
        // 照片 / 封面盖在视频上，第一帧出来后淡出，不会有黑帧
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _ready ? 0 : 1,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            child: widget.placeholder,
          ),
        ),
      ],
    );
  }
}
