import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import 'apple_music_motion.dart';

/// 单行歌词（Apple Music iOS 风格）。
///
/// 视觉规则由 [distance]（与当前行的行距，负数为已唱过）决定：
/// - 当前行：纯白、不模糊、原始大小；
/// - 其余行：透明度逐行降低，模糊半径逐行增大（上限 [_maxBlur]），略微缩小；
/// - [focusAll] 为 true（用户正在手动浏览 / 非同步歌词）时全部清晰，方便阅读。
///
/// 所有参数通过 TweenAnimationBuilder 平滑过渡，行切换时呈现"对焦"动画。
class LyricLineView extends StatelessWidget {
  final String text;

  /// 译文（双语歌词）：非空时以小字显示在原文下方。
  final String? translation;
  final double translationProgress;
  final int distance;
  final bool focusAll;
  final VoidCallback? onTap;

  /// 可跳转时显示的鼠标指针；沉浸式歌词传 [MouseCursor.defer]，交给外层控制隐藏光标。
  final MouseCursor cursor;

  /// 字号；行距随字号等比放大。
  final double fontSize;

  /// 居中对齐时文字居中、缩放以中心为基准；默认左对齐（Apple Music）。
  final bool centered;

  /// 模糊强度倍率（设置页「其他行模糊」）：0 不模糊，1 默认。
  final double blurScale;
  final bool appleMusicStyle;

  const LyricLineView({
    super.key,
    required this.text,
    this.translation,
    this.translationProgress = 1,
    required this.distance,
    this.focusAll = false,
    this.onTap,
    this.cursor = MouseCursor.defer,
    this.fontSize = 30,
    this.centered = false,
    this.blurScale = 1,
    this.appleMusicStyle = false,
  });

  static const double _maxBlur = 3.5;
  static const Duration _duration = Duration(milliseconds: 520);

  @override
  Widget build(BuildContext context) {
    final d = distance.abs();
    final isActive = distance == 0;

    // 相邻句 1.0、隔一句 2.0 …… 上限 3.5：近处可辨认，远处退为氛围；再乘用户设置的强度
    final blur = appleMusicStyle || focusAll || isActive
        ? 0.0
        : (d * 1.0).clamp(0.0, _maxBlur) * blurScale;
    final opacity = appleMusicStyle
        ? (focusAll || isActive ? .94 : .18)
        : focusAll
        ? (isActive ? 1.0 : 0.62)
        : isActive
        ? 1.0
        : (0.52 - d * 0.06).clamp(0.2, 0.46);
    final scale = isActive || (appleMusicStyle && focusAll)
        ? 1.0
        : appleMusicStyle
        ? .98
        : .965;
    final duration = appleMusicStyle
        ? Duration(milliseconds: isActive ? 500 : 600)
        : _duration;

    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: appleMusicStyle
              ? const EdgeInsets.only(top: 2, bottom: 30)
              : EdgeInsets.symmetric(vertical: fontSize * 0.4),
          child: TweenAnimationBuilder<_LineVisual>(
            tween: _LineVisualTween(end: _LineVisual(blur, opacity, scale)),
            duration: context.motion(duration),
            curve: appleMusicStyle
                ? Interval(
                    250 / duration.inMilliseconds,
                    1,
                    curve: AppleMusicMotion.focusCurve,
                  )
                : const Cubic(0.22, 1.0, 0.36, 1.0),
            builder: (context, v, _) {
              // 透明度直接写进文字颜色，省去 Opacity 的离屏图层
              Widget result = _LineText(
                text: text,
                translation: translation,
                translationProgress: translationProgress,
                opacity: v.opacity,
                fontSize: fontSize,
                centered: centered,
              );
              // ImageFiltered 始终留在树里，sigma 过小时只关掉 enabled（同样不产生离屏层）。
              // 之前按阈值增删这一层，每次对焦动画收尾都会让整行文字卸载重建、
              // 并在「离屏渲染 ↔ 直接绘制」之间跳变一帧，肉眼就是歌词闪一下。
              if (!appleMusicStyle) {
                result = ImageFiltered(
                  enabled: v.blur > 0.05,
                  imageFilter: ImageFilter.blur(sigmaX: v.blur, sigmaY: v.blur),
                  child: result,
                );
              }
              return RepaintBoundary(
                child: Transform.scale(
                  scale: v.scale,
                  alignment: centered
                      ? Alignment.center
                      : appleMusicStyle
                      ? (Directionality.of(context) == TextDirection.rtl
                            ? Alignment.bottomRight
                            : Alignment.bottomLeft)
                      : Alignment.centerLeft,
                  child: result,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 歌词文字；空行（间奏）显示三个圆点。译文（[translation] 非空且不是间奏时）
/// 以约六成字号附在原文下方，随原文一起模糊 / 淡出。
class _LineText extends StatelessWidget {
  final String text;
  final String? translation;
  final double translationProgress;
  final double opacity;
  final double fontSize;
  final bool centered;

  const _LineText({
    required this.text,
    this.translation,
    required this.translationProgress,
    required this.opacity,
    required this.fontSize,
    required this.centered,
  });

  static const Color _translationGray = Color(0xFFC4CAD4);

  @override
  Widget build(BuildContext context) {
    final isInterlude = text.trim().isEmpty || text.trim() == '♪';
    final trans = isInterlude ? null : translation?.trim();
    final progress = trans == null || trans.isEmpty
        ? 0.0
        : translationProgress.clamp(0.0, 1.0);
    return Transform.translate(
      offset: Offset(0, -fontSize * 0.3 * progress),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: centered
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isInterlude ? '•  •  •' : text,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                color: Colors.white.withValues(alpha: opacity),
                // 中文歌词：字距只轻微收紧，行高放宽并上下均分，多行时汉字不挤、不裁切
                letterSpacing: -0.2,
                height: 1.3,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            if (progress > 0)
              Align(
                alignment: centered ? Alignment.topCenter : Alignment.topLeft,
                heightFactor: progress,
                child: Padding(
                  padding: EdgeInsets.only(top: fontSize * 0.18),
                  child: Transform.translate(
                    offset: Offset(0, fontSize * 0.18 * (1 - progress)),
                    child: Text(
                      trans!,
                      textAlign: centered ? TextAlign.center : TextAlign.start,
                      style: TextStyle(
                        fontSize: fontSize * 0.56,
                        fontWeight: FontWeight.w600,
                        // 译文偏灰：冷灰色 + 更低透明度，与纯白原文拉开层次
                        color: _translationGray.withValues(
                          alpha: opacity * 0.62 * progress,
                        ),
                        letterSpacing: -0.1,
                        height: 1.25,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 动画插值所需的三元组。
@immutable
class _LineVisual {
  final double blur;
  final double opacity;
  final double scale;

  const _LineVisual(this.blur, this.opacity, this.scale);

  // 已经到达模糊/透明度上限的远处歌词无需每次切行重启动画。
  @override
  bool operator ==(Object other) =>
      other is _LineVisual &&
      other.blur == blur &&
      other.opacity == opacity &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(blur, opacity, scale);
}

class _LineVisualTween extends Tween<_LineVisual> {
  _LineVisualTween({required _LineVisual end}) : super(begin: end, end: end);

  @override
  _LineVisual lerp(double t) {
    final a = begin!, b = end!;
    return _LineVisual(
      lerpDouble(a.blur, b.blur, t)!,
      lerpDouble(a.opacity, b.opacity, t)!,
      lerpDouble(a.scale, b.scale, t)!,
    );
  }
}
