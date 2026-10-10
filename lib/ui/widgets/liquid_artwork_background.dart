import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'liquid_artwork_painter.dart';

/// Apple Music 歌词页的"流动封面"背景。
///
/// 做法：同一张封面放大成三份，以不同周期缓慢旋转，叠压暗层后整体大半径模糊，
/// 得到颜色持续流动的液态渐变。配方与 Android 原生背景一致（绘制见 [LiquidArtworkPainter]），
/// 切歌时新封面在旧封面之上 1 秒淡入，与原生端相同。
///
/// 性能：
/// - 封面以 128px 解码，模糊半径很大，原图分辨率毫无意义；
/// - 模糊在 1/8 分辨率的离屏画布上完成再放大，不再每帧做全屏全分辨率的大模糊；
/// - 整个背景包在 RepaintBoundary 里，前景歌词滚动不会触发它重绘；
/// - [animate] 为 false（暂停播放）时停止旋转，与 Apple Music 行为一致；
/// - 旋转周期 70 秒以上、又叠了大模糊，30fps 与 60fps 肉眼无差别，
///   所以动画只按 30fps 推进：背景每变一帧，上面所有玻璃都要重新采样，帧率减半即 GPU 占用减半。
class LiquidArtworkBackground extends StatefulWidget {
  final String imageUrl;

  /// 封面尚未加载或加载失败时的底色；原生端此时是纯黑。
  final Color fallback;
  final bool animate;

  /// 压暗层强度：深色主题 50% 黑，浅色主题 30% 黑（与原生端一致）。
  final bool dark;

  const LiquidArtworkBackground({
    super.key,
    required this.imageUrl,
    this.fallback = Colors.black,
    this.animate = true,
    this.dark = true,
  });

  @override
  State<LiquidArtworkBackground> createState() =>
      _LiquidArtworkBackgroundState();
}

class _LiquidArtworkBackgroundState extends State<LiquidArtworkBackground>
    with SingleTickerProviderStateMixin {
  static const Duration _frameInterval = Duration(microseconds: 33333);
  static const Duration _fadeIn = Duration(milliseconds: 1000);

  /// 用定时器而不是 Ticker 推进相位：Ticker 每个 vsync 都会回调并预约下一帧，
  /// 即使回调里跳过更新，引擎仍会重新合成整个窗口（含所有玻璃），
  /// 165Hz 屏上就是每秒 165 次整窗重绘。定时器只在相位真正变化时才让引擎出帧。
  Timer? _timer;
  final Stopwatch _clock = Stopwatch();

  /// 所在路由被遮住等情况下 TickerMode 关闭，与 Ticker 一样停止流动。
  bool _tickerEnabled = true;

  /// 已流动的秒数，绘制器按各层周期换算角度。只有这个 notifier 变化才会重绘封面。
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);

  /// 本次启动前的相位：暂停后继续从原处转，不回到起点。
  double _resumeFrom = 0;

  /// 封面淡入：1 秒，曲线与原生端 PathInterpolator(0, 0, .3, 1) 相同；
  /// 首张封面且内存缓存命中时直接显示。
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: _fadeIn,
  )..addStatusListener(_onFadeStatus);
  late final CurvedAnimation _fadeCurve = CurvedAnimation(
    parent: _fade,
    curve: const Cubic(0, 0, 0.3, 1),
  );

  /// 切歌时垫在新封面下面的旧封面，冻结在换歌那一刻的相位，淡入结束后释放。
  ImageInfo? _previous;
  double _previousPhase = 0;

  ImageStream? _stream;
  ImageInfo? _artwork;
  late final ImageStreamListener _listener = ImageStreamListener(
    _onImage,
    onError: _onImageError,
  );

  /// 正在同步 addListener：此时回调的图片来自内存缓存，不做淡入。
  bool _resolvingSync = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncAnimation();
    _resolveImage();
  }

  @override
  void didUpdateWidget(LiquidArtworkBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageUrl != oldWidget.imageUrl) _resolveImage();
    _syncAnimation();
  }

  // ---- 封面加载 ----

  void _resolveImage() {
    if (widget.imageUrl.isEmpty) {
      _setStream(null);
      return;
    }
    final provider = ResizeImage(
      CachedNetworkImageProvider(widget.imageUrl),
      width: 128,
    );
    _setStream(provider.resolve(createLocalImageConfiguration(context)));
  }

  void _setStream(ImageStream? stream) {
    if (stream != null && stream.key == _stream?.key) return;
    _inLifecycle = true;
    _stream?.removeListener(_listener);
    // 换歌时旧封面留在屏幕上，等新封面到了再交叉淡入（与原生端一致）；
    // 没有新封面可等（地址为空）才清空。
    if (stream == null) {
      _clearPrevious();
      _replaceArtwork(null);
      _fade.value = 0;
    }
    _stream = stream;
    _resolvingSync = true;
    stream?.addListener(_listener);
    _resolvingSync = false;
    _inLifecycle = false;
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    final shown = _artwork;
    if (shown == null) {
      // 首张封面：同步命中缓存时直接显示，否则从黑底淡入
      _replaceArtwork(info);
      if (_resolvingSync || synchronousCall) {
        _fade.value = 1;
      } else {
        _fade.forward(from: 0);
      }
      return;
    }
    // 换封面：旧封面冻结在此刻的相位，作为底层保持不透明，新封面在其上淡入
    _clearPrevious();
    _previous = shown;
    _previousPhase = _phase.value;
    _artwork = info;
    if (!_inLifecycle) setState(() {});
    _fade.forward(from: 0);
  }

  /// 加载失败：只显示底色，与原生端 setArtwork(null) 一致。
  void _onImageError(Object error, StackTrace? stackTrace) {
    _clearPrevious();
    _replaceArtwork(null);
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _previous != null && mounted) {
      setState(_clearPrevious);
    }
  }

  void _clearPrevious() {
    _previous?.dispose();
    _previous = null;
  }

  /// 生命周期内（didChangeDependencies / didUpdateWidget / 同步命中）本就会重建，
  /// 只有异步回调才需要 setState。
  void _replaceArtwork(ImageInfo? info) {
    if (!mounted) {
      info?.dispose();
      return;
    }
    final old = _artwork;
    _artwork = info;
    if (!_inLifecycle) setState(() {});
    old?.dispose();
  }

  bool _inLifecycle = false;

  // ---- 旋转动画 ----

  void _syncAnimation() =>
      widget.animate && _tickerEnabled ? _start() : _stop();

  void _start() {
    if (_timer != null) return;
    _clock
      ..reset()
      ..start();
    _timer = Timer.periodic(_frameInterval, (_) => _tick());
  }

  void _stop() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _clock.stop();
    _resumeFrom = _phase.value;
  }

  void _tick() {
    _phase.value = _resumeFrom + _clock.elapsedMicroseconds / 1e6;
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _artwork?.dispose();
    _previous?.dispose();
    _timer?.cancel();
    _fadeCurve.dispose();
    _fade.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: widget.fallback),
          CustomPaint(
            painter: LiquidArtworkPainter(
              phase: _phase,
              fade: _fadeCurve,
              image: _artwork?.image,
              previous: _previous?.image,
              previousPhase: _previousPhase,
              dark: widget.dark,
            ),
          ),
        ],
      ),
    );
  }
}
