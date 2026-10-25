import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';

import '../../core/debug_toggles.dart';
import '../../core/perf_flags.dart';
import '../../core/theme/flutify_tokens.dart';
import '../shell/desktop/desktop_window.dart';
import 'hyper_surface.dart';

/// iOS 风格的克制型玻璃容器。
///
/// 三层叠加：
/// 1. 背景模糊（纯 blur；曾经用 compose 叠加 1.15× 提饱和，但 Windows 引擎对
///    compose 后的 BackdropFilter 在路由弹出 / 窗口尺寸变化时会访问冲突崩溃，
///    WER dump 确认栈全在 flutter_windows.dll 内，故只用单层模糊）；
/// 2. 极淡的白色填充（玻璃体本身几乎不可见，靠模糊界定形状）；
/// 3. 一圈发丝级描边，上缘略亮于下缘，暗示光从上方来。
///
/// 设计原则：玻璃应该"退后"，让内容和背景说话；任何一层都不应被一眼注意到。
/// 性能：每个实例是一次 BackdropFilter，页面内应控制在少量几个。
/// BackdropFilter 每帧都要复制一次下方画面，即使模糊半径很小也有固定开销；
/// 背景在流动时（歌词页）这笔开销每帧都在发生，见 [backdrop]。
class LiquidGlass extends StatelessWidget {
  final Widget child;

  /// 为空时按 28px 基准随「圆角风格」缩放。
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry padding;

  /// 模糊半径；为空时取设置页「玻璃模糊」。
  final double? blur;

  /// 玻璃填充亮度（0~1）；为空时取设置页「玻璃不透明度」（默认约 0.05）。
  final double? tint;

  /// 是否真正模糊下方画面。为 false 时只画填充与描边，不做 BackdropFilter。
  ///
  /// 只用于下方永远只有歌词流动背景（`LiquidArtworkBackground`）的玻璃：
  /// 那层背景本身已做 σ=70 的大模糊，再模糊一次与原样肉眼无差别，
  /// 却能省掉每帧一次的背景复制。下方可能有歌词、封面等清晰内容时必须保持 true。
  final bool backdrop;

  /// 省电模式下磨砂底的不透明度：足以压住下方清晰内容，又保留一点通透感。
  static const double _powerSavingFill = 0.86;

  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding = EdgeInsets.zero,
    this.blur,
    this.tint,
    this.backdrop = true,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius = borderRadius ?? tokens.radius(28);
    final sigma = blur ?? tokens.glassSigma;
    if (tokens.hyperMaterial && !tokens.powerSaving) {
      final hyper = _hyper(context, radius);
      if (hyper != null) return hyper;
    }
    final body = CustomPaint(
      foregroundPainter: _HairlinePainter(radius),
      child: ColoredBox(
        color: Colors.white.withValues(alpha: tint ?? tokens.glassTint),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (tokens.powerSaving && backdrop) {
      // 省电：不复制、不模糊下方画面，垫一层较实的表面色代替，保证其上文字可读
      final surface = Theme.of(context).colorScheme.surfaceContainerHigh;
      return ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: surface.withValues(alpha: _powerSavingFill),
          child: body,
        ),
      );
    }
    if (!backdrop ||
        PerfFlags.noBackdrop ||
        DebugToggles.of(context).isOff(DebugToggle.glassBackdrop)) {
      return ClipRRect(borderRadius: radius, child: body);
    }
    return ClipRRect(
      borderRadius: radius,
      // 系统全屏切换期间引擎合成器对 BackdropFilter 会访问冲突（详见 DesktopWindow.fullscreenTransition），
      // 这约 300ms 内退化为无模糊玻璃，肉眼几乎不可辨
      child: ValueListenableBuilder<bool>(
        valueListenable: DesktopWindow.fullscreenTransition,
        builder: (context, transitioning, _) {
          if (transitioning) return body;
          // grouped：外层有 BackdropGroup 时共享同一份背景采样，没有时与普通 BackdropFilter 完全一致
          return BackdropFilter.grouped(
            filter: ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.mirror,
            ),
            child: body,
          );
        },
      ),
    );
  }
}

extension on LiquidGlass {
  /// 材质为「柔光玻璃」时：在 `HyperGlassScene` 里（播放页）画真正的柔光玻璃；
  /// 场景外改用浮动栏混色模糊。下方只有流动背景（[backdrop] 为 false）的场景外玻璃
  /// 保持原样，不为它多付一次背景复制。
  Widget? _hyper(BuildContext context, BorderRadius radius) {
    final content = Padding(padding: padding, child: child);
    if (HyperGlassScene.isIn(context)) {
      // 玻璃 shader 自己按 SDF 画圆角形状，不再套 ClipRRect：Skia 会把裁剪编进 GPU 程序，
      // 套了裁剪就和预热时的程序不同，首次打开歌词页要现编译（约 150~200 ms 掉帧），
      // 每帧也多一份裁剪开销。只裁上面的内容，保证文字图标不出圆角。
      return HyperGlass(
        borderRadius: radius.topLeft.x,
        child: ClipRRect(borderRadius: radius, child: content),
      );
    }
    if (!backdrop) return null;
    return HyperBlendSurface(
      material: HyperBlendSurface.bar(context),
      borderRadius: radius,
      child: content,
    );
  }
}

/// 发丝描边：上缘 14% 白、下缘 4% 白。
class _HairlinePainter extends CustomPainter {
  final BorderRadius borderRadius;

  _HairlinePainter(this.borderRadius);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.14),
          Colors.white.withValues(alpha: 0.04),
        ],
      ).createShader(rect);
    canvas.drawRRect(borderRadius.toRRect(rect).deflate(0.3), paint);
  }

  @override
  bool shouldRepaint(_HairlinePainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius;
}
