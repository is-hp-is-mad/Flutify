import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';

import '../../core/debug_toggles.dart';
import '../../core/perf_flags.dart';
import '../../core/theme/flutify_tokens.dart';
import '../shell/desktop/desktop_window.dart';

bool _hyperWarm = false;

/// 柔光玻璃 shader 全进程只加载、预热一次（[HyperGlassRenderer.shared]），并把 Skia 的
/// GPU 资源缓存压到 32 MB：每次玻璃刷新都会分配离屏纹理，默认缓存会让进程多占几百 MB，
/// 回收时还会卡一下。选了柔光玻璃、或设置页准备显示它的预览时调用，可重复调用。
void warmUpHyperGlass() {
  if (_hyperWarm) return;
  _hyperWarm = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(limitSkiaResourceCache().catchError((Object _) {}));
    unawaited(
      HyperGlassRenderer.shared().then<void>(
        (_) {},
        onError: (Object e) => debugPrint('[hyper_glass] 预热失败：$e'),
      ),
    );
  });
}

/// HyperOS 混色模糊（blendBlur）表面：菜单、弹窗、浮层用。
///
/// 与 `HyperBlendBlur` 同一套材质参数（[BlendMaterial]：模糊 sigma + 最多三层混合色），
/// 但不需要 `HyperGlassScene`：模糊交给单层 `BackdropFilter.grouped`（与 LiquidGlass
/// 一样只用纯 blur，规避 Windows 引擎 compose 滤镜崩溃），混合层直接按 [BlendMode]
/// 画在模糊后的画面上，所以能浮在整个应用任意位置。
///
/// 省电模式、关闭背景模糊、全屏切换过渡期间退回材质自带的 [BlendMaterial.fallback] 纯色。
class HyperBlendSurface extends StatelessWidget {
  final BlendMaterial material;
  final BorderRadius borderRadius;
  final Widget child;

  const HyperBlendSurface({
    super.key,
    required this.material,
    required this.borderRadius,
    required this.child,
  });

  /// 弹出菜单材质（σ22），按深浅色挑选。
  static BlendMaterial menu(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? BlendMaterial.popupMenuDark
      : BlendMaterial.popupMenuLight;

  /// 弹窗材质（浅色 σ32 / 深色 σ56）。
  static BlendMaterial dialog(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? BlendMaterial.dialogDark
      : BlendMaterial.dialogLight;

  /// 浮动栏材质（σ20），场景外的玻璃表面用它代替柔光玻璃。
  static BlendMaterial bar(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? BlendMaterial.appBarDark
      : BlendMaterial.appBarLight;

  @override
  Widget build(BuildContext context) {
    final solid = ClipRRect(
      borderRadius: borderRadius,
      child: ColoredBox(color: material.fallback, child: child),
    );
    if (context.tokens.powerSaving ||
        PerfFlags.noBackdrop ||
        DebugToggles.of(context).isOff(DebugToggle.glassBackdrop)) {
      return solid;
    }
    final layered = CustomPaint(
      painter: _BlendLayersPainter(material.layers),
      child: child,
    );
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopWindow.fullscreenTransition,
      builder: (context, transitioning, _) {
        if (transitioning) return solid;
        return ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter.grouped(
            filter: ImageFilter.blur(
              sigmaX: material.sigma,
              sigmaY: material.sigma,
              tileMode: TileMode.mirror,
            ),
            child: layered,
          ),
        );
      },
    );
  }
}

/// 把材质的混合层依次叠在模糊后的画面上（与 mi_blend_blur.frag 的合成顺序一致）。
class _BlendLayersPainter extends CustomPainter {
  final List<BlendLayer> layers;

  const _BlendLayersPainter(this.layers);

  static BlendMode _mode(BlendLayerMode m) => switch (m) {
    BlendLayerMode.srcOver => BlendMode.srcOver,
    BlendLayerMode.overlay => BlendMode.overlay,
    BlendLayerMode.hardLight => BlendMode.hardLight,
    BlendLayerMode.softLight => BlendMode.softLight,
    BlendLayerMode.colorBurn => BlendMode.colorBurn,
    BlendLayerMode.colorDodge => BlendMode.colorDodge,
    BlendLayerMode.luminosity => BlendMode.luminosity,
    // Flutter 没有 plusDarker；这些层都是低透明度黑色，正片叠底肉眼一致
    BlendLayerMode.plusDarker => BlendMode.multiply,
    BlendLayerMode.plusLighter => BlendMode.plus,
    BlendLayerMode.darken => BlendMode.darken,
    BlendLayerMode.color => BlendMode.color,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    for (final l in layers) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = l.color
          ..blendMode = _mode(l.mode),
      );
    }
  }

  @override
  bool shouldRepaint(_BlendLayersPainter old) => old.layers != layers;
}

/// 柔光玻璃首帧预热：选了柔光玻璃后，在界面最底层（被所有内容盖住的左上角 4×4 区域）
/// 真实画一次柔光玻璃和混色模糊，然后移除。
///
/// [warmUpHyperGlass] 只在离屏纹理上跑过一遍；上屏绘制的目标格式和混合状态不同，
/// Skia 会在第一次上屏时重新编译这几段大 shader，歌词页 / 设置预览首次出现时整窗卡死数秒。
/// 这里把那次编译提前到启动后的空闲时刻，并记录耗时，便于在日志里核对。
class HyperGlassWarmup extends StatefulWidget {
  final Widget child;

  const HyperGlassWarmup({super.key, required this.child});

  @override
  State<HyperGlassWarmup> createState() => _HyperGlassWarmupState();
}

class _HyperGlassWarmupState extends State<HyperGlassWarmup> {
  static bool _done = false;
  bool _ready = false;
  int _frames = 0;
  Stopwatch? _clock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_done || _ready || !context.tokens.hyperMaterial) return;
    _clock = Stopwatch()..start();
    HyperGlassRenderer.shared().then((_) {
      if (!mounted) return;
      debugPrint('[hyper_glass] shader 加载完成：${_clock!.elapsedMilliseconds} ms');
      setState(() => _ready = true);
      _countFrames();
    }, onError: (Object _) => _done = true);
  }

  // 场景要先截一次背景、表面才会真正绘制；多留几帧确保两种材质都上屏画过
  void _countFrames() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (++_frames < 6) {
        WidgetsBinding.instance.ensureVisualUpdate();
        _countFrames();
        return;
      }
      debugPrint('[hyper_glass] 上屏预热完成：${_clock!.elapsedMilliseconds} ms');
      setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final warming = !_done && _ready && context.tokens.hyperMaterial;
    // 结构始终是同一个 Stack，预热层只在第一格里出现 / 消失，界面本身不会被重新挂载
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        if (!warming)
          const SizedBox.shrink()
        else
          Positioned(
            left: 0,
            top: 0,
            width: 4,
            height: 4,
            child: IgnorePointer(
              child: HyperGlassScene(
                animate: false,
                background: const ColoredBox(color: Color(0xff3070c0)),
                child: Row(
                  children: [
                    const Expanded(child: HyperGlass(borderRadius: 1)),
                    Expanded(
                      child: HyperBlendBlur(
                        material: HyperBlendSurface.menu(context),
                        borderRadius: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned.fill(child: widget.child),
      ],
    );
  }
}
