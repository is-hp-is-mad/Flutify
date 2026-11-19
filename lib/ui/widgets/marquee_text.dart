import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;
  final Duration startDelay;
  final double gap;
  final double pixelsPerSecond;
  final double edgeFadeInset;
  final bool enabled;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.textAlign = TextAlign.start,
    this.startDelay = const Duration(seconds: 4),
    this.gap = 40,
    this.pixelsPerSecond = 30,
    this.edgeFadeInset = 0,
    this.enabled = true,
  }) : assert(gap >= 0),
       assert(pixelsPerSecond > 0),
       assert(edgeFadeInset >= 0);

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with TickerProviderStateMixin {
  static const _edgeFadeWidth = 24.0 * 0.7;

  /// 起步时左侧渐隐带相对文字位移的展开倍速：16.8px 的柔边在文字移动约 4px 内铺满。
  static const _leadingFadeGrowth = 4.0;

  late final AnimationController _controller = AnimationController(vsync: this);
  late final ScrollController _scrollController = ScrollController();

  double _contentWidth = 0;
  double _viewportWidth = 0;
  double _scrollDistance = 0;
  Duration _scrollDuration = Duration.zero;
  bool _shouldAnimate = false;
  bool _configurationScheduled = false;
  _MarqueeConfiguration? _pendingConfiguration;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleAnimationTick);
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        widget.style != oldWidget.style ||
        widget.textAlign != oldWidget.textAlign ||
        widget.gap != oldWidget.gap ||
        widget.pixelsPerSecond != oldWidget.pixelsPerSecond ||
        widget.startDelay != oldWidget.startDelay ||
        widget.enabled != oldWidget.enabled) {
      _resetAnimation();
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _ticker.dispose();
    _controller.removeListener(_handleAnimationTick);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final textDirection = Directionality.of(context);
    final textStyle = DefaultTextStyle.of(context).style.merge(widget.style);
    final contentWidth = _measureText(
      textDirection,
      mediaQuery.textScaler,
      textStyle,
    );

    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final overflows =
            widget.enabled &&
            !mediaQuery.disableAnimations &&
            viewportWidth.isFinite &&
            contentWidth > viewportWidth + 0.5;
        final shouldAnimate = overflows && tickerEnabled;
        _scheduleConfiguration(
          viewportWidth: viewportWidth,
          contentWidth: contentWidth,
          shouldAnimate: shouldAnimate,
        );

        // 只要超宽就从首帧直接画静止在 0 处的右缘柔化布局，避免第 1 帧先画省略号 `…`、
        // 第 2 帧 postFrameCallback 再切成 ShaderMask 造成迷你条歌名跳变。
        if (!overflows) return _buildStaticText();

        return Semantics(
          container: true,
          label: widget.text,
          child: ExcludeSemantics(
            child: ClipRect(
              child: SizedBox(
                width: double.infinity,
                child: AnimatedBuilder(
                  animation: _controller,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    primary: false,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildUnboundedText(
                          textDirection,
                          mediaQuery.textScaler,
                          textStyle,
                        ),
                        SizedBox(width: widget.gap),
                        _buildUnboundedText(
                          textDirection,
                          mediaQuery.textScaler,
                          textStyle,
                        ),
                      ],
                    ),
                  ),
                  builder: (context, child) => _MarqueeShaderMask(
                    maskPadding: 2 / mediaQuery.devicePixelRatio,
                    blendMode: BlendMode.dstIn,
                    shaderCallback: _buildEdgeFadeShader,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Shader _buildEdgeFadeShader(Rect bounds) {
    if (bounds.width <= 0) {
      return const LinearGradient(
        colors: [Colors.black, Colors.black],
      ).createShader(bounds);
    }

    final fadeWidth = math.min(_edgeFadeWidth, bounds.width / 2);
    final inset = math.min(widget.edgeFadeInset, fadeWidth / 2);
    final insetFraction = inset / bounds.width;
    final rightFadeStart = 1 - fadeWidth / bounds.width;
    final rightFadeEnd = 1 - insetFraction;
    final offset = _scrollOffset;
    // 左侧渐隐带只在「没有字形压在带内」时伸缩，否则带子被压窄后渐变近乎硬边，
    // 文字会在左缘露出一截：
    // - 起步：静止时标题首字完整显示（无左渐隐），开始滚动后渐隐带以文字位移的
    //   [_leadingFadeGrowth] 倍速度展开，几像素内就恢复完整柔边；
    // - 收尾：不再跟着上一份标题的尾巴收缩（旧逻辑会让尾字以不透明状态贴边移出），
    //   而是在两份标题之间的空白经过左缘时、紧贴下一份标题的开头收起，
    //   让下一份标题以完全不透明的状态回到起点，与循环开头无缝衔接。
    final leftFadeWidth = math.max(
      0.0,
      math.min(
        fadeWidth,
        math.min(offset * _leadingFadeGrowth, _scrollDistance - offset),
      ),
    );
    final leftFadeFraction = leftFadeWidth / bounds.width;
    if (leftFadeFraction <= 0) {
      return LinearGradient(
        colors: const [
          Colors.black,
          Colors.black,
          Colors.transparent,
          Colors.transparent,
        ],
        stops: [0, rightFadeStart, rightFadeEnd, 1],
      ).createShader(bounds);
    }

    // 最外侧全透明区不随渐隐带按比例缩小，带子刚展开时也先盖住最外一像素。
    final leftInsetFraction = math.min(inset, leftFadeWidth / 2) / bounds.width;
    return LinearGradient(
      colors: const [
        Colors.transparent,
        Colors.transparent,
        Colors.black,
        Colors.black,
        Colors.transparent,
        Colors.transparent,
      ],
      stops: [
        0,
        leftInsetFraction,
        leftFadeFraction,
        rightFadeStart,
        rightFadeEnd,
        1,
      ],
    ).createShader(bounds);
  }

  /// [_controller] 的值只表示滚动段进度（0~1 对应 0~滚动距离），不再自己计时。
  double get _scrollOffset {
    if (_scrollDistance == 0 || _scrollDuration == Duration.zero) return 0;
    return _scrollDistance * _controller.value;
  }

  /// 每轮「静止 startDelay → 滚动 _scrollDuration」，与原先 repeat 整段时长的语义一致：
  /// 进度一律由帧时间戳相对 [_origin] 推算。区别只在静止段停掉逐帧回调、由 [_delay]
  /// 定时器在静止结束时唤醒——静止期间画面不变，不该逐帧带动整窗重绘。
  late final Ticker _ticker = createTicker((_) => _syncLap());
  Duration _origin = Duration.zero;
  Timer? _delay;

  Duration get _frameTime =>
      SchedulerBinding.instance.currentSystemFrameTimeStamp;

  void _syncLap() {
    if (!_shouldAnimate) return;
    final cycle = (widget.startDelay + _scrollDuration).inMicroseconds;
    final pos = Duration(
      microseconds: (_frameTime - _origin).inMicroseconds % cycle,
    );
    if (pos < widget.startDelay) {
      _controller.value = 0;
      _ticker.stop();
      _delay?.cancel();
      _delay = Timer(widget.startDelay - pos, () {
        if (mounted && _shouldAnimate && !_ticker.isActive) _ticker.start();
      });
    } else {
      _controller.value =
          (pos - widget.startDelay).inMicroseconds /
          _scrollDuration.inMicroseconds;
      if (!_ticker.isActive) _ticker.start();
    }
  }

  double _measureText(
    TextDirection textDirection,
    TextScaler textScaler,
    TextStyle textStyle,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: textStyle),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  Widget _buildStaticText() {
    return Text(
      widget.text,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );
  }

  Widget _buildUnboundedText(
    TextDirection textDirection,
    TextScaler textScaler,
    TextStyle textStyle,
  ) {
    return Text(
      widget.text,
      style: textStyle,
      textAlign: widget.textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
      overflow: TextOverflow.visible,
      softWrap: false,
    );
  }

  void _scheduleConfiguration({
    required double viewportWidth,
    required double contentWidth,
    required bool shouldAnimate,
  }) {
    final configuration = _MarqueeConfiguration(
      viewportWidth: viewportWidth,
      contentWidth: contentWidth,
      shouldAnimate: shouldAnimate,
    );
    final current = _MarqueeConfiguration(
      viewportWidth: _viewportWidth,
      contentWidth: _contentWidth,
      shouldAnimate: _shouldAnimate,
    );
    if (configuration == current || configuration == _pendingConfiguration) {
      return;
    }

    _pendingConfiguration = configuration;
    _configurationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_configurationScheduled ||
          _pendingConfiguration != configuration) {
        return;
      }
      _configurationScheduled = false;
      _pendingConfiguration = null;
      _applyConfiguration(configuration);
    });
  }

  void _applyConfiguration(_MarqueeConfiguration configuration) {
    _delay?.cancel();
    _ticker.stop();
    _controller.stop();
    _controller.value = 0;
    _viewportWidth = configuration.viewportWidth;
    _contentWidth = configuration.contentWidth;
    _shouldAnimate = configuration.shouldAnimate;

    if (_shouldAnimate) {
      _scrollDistance = _contentWidth + widget.gap;
      _scrollDuration = Duration(
        milliseconds: math.max(
          2200,
          (_scrollDistance / widget.pixelsPerSecond * 1000).round(),
        ),
      );
      _controller.duration = _scrollDuration;
      _origin = _frameTime;
      _syncLap();
    } else {
      _scrollDistance = 0;
      _scrollDuration = Duration.zero;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
    setState(() {});
  }

  void _resetAnimation() {
    _delay?.cancel();
    _ticker.stop();
    _controller.stop();
    _controller.value = 0;
    _viewportWidth = 0;
    _contentWidth = 0;
    _scrollDistance = 0;
    _scrollDuration = Duration.zero;
    _shouldAnimate = false;
    _pendingConfiguration = null;
    _configurationScheduled = false;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _handleAnimationTick() {
    if (!_scrollController.hasClients) return;
    final target = _scrollOffset
        .clamp(0.0, _scrollController.position.maxScrollExtent)
        .toDouble();
    if ((_scrollController.offset - target).abs() > 0.1) {
      _scrollController.jumpTo(target);
    }
  }
}

/// Keep the mask's rasterized boundary outside the visible text viewport.
/// A transparent gradient stop cannot hide pixels missed by the mask rectangle
/// itself (e.g. at fractional device coordinates with Android Impeller).
class _MarqueeShaderMask extends ShaderMask {
  const _MarqueeShaderMask({
    required this.maskPadding,
    required super.shaderCallback,
    required super.blendMode,
    super.child,
  });

  final double maskPadding;

  @override
  RenderShaderMask createRenderObject(BuildContext context) =>
      _RenderMarqueeShaderMask(
        maskPadding,
        shaderCallback: shaderCallback,
        blendMode: blendMode,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMarqueeShaderMask renderObject,
  ) {
    super.updateRenderObject(context, renderObject);
    renderObject.maskPadding = maskPadding;
  }
}

class _RenderMarqueeShaderMask extends RenderShaderMask {
  _RenderMarqueeShaderMask(
    this._maskPadding, {
    required super.shaderCallback,
    required super.blendMode,
  });

  double _maskPadding;

  set maskPadding(double value) {
    if (_maskPadding == value) return;
    _maskPadding = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }

    // The layer's origin moves with the inflated mask. Compensate in shader
    // coordinates so the fades still line up with the unchanged viewport.
    layer ??= ShaderMaskLayer();
    layer!
      ..shader = shaderCallback(
        Rect.fromLTWH(_maskPadding, _maskPadding, size.width, size.height),
      )
      ..maskRect = (offset & size).inflate(_maskPadding)
      ..blendMode = blendMode;
    context.pushLayer(layer!, (context, offset) {
      context.paintChild(child!, offset);
    }, offset);
  }
}

class _MarqueeConfiguration {
  final double viewportWidth;
  final double contentWidth;
  final bool shouldAnimate;

  const _MarqueeConfiguration({
    required this.viewportWidth,
    required this.contentWidth,
    required this.shouldAnimate,
  });

  @override
  bool operator ==(Object other) {
    return other is _MarqueeConfiguration &&
        other.viewportWidth == viewportWidth &&
        (other.contentWidth - contentWidth).abs() < 0.5 &&
        other.shouldAnimate == shouldAnimate;
  }

  @override
  int get hashCode =>
      Object.hash(viewportWidth, contentWidth.round(), shouldAnimate);
}
