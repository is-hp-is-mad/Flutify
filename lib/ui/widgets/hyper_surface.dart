import 'dart:async';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';

import '../../core/debug_toggles.dart';
import '../../core/perf_flags.dart';
import '../../core/theme/flutify_tokens.dart';
import '../../l10n/l10n.dart';
import '../shell/desktop/desktop_window.dart';

bool _hyperWarm = false;

/// 选了柔光玻璃时把 Skia 的 GPU 资源缓存压到 32 MB：每次玻璃刷新都会分配离屏纹理，
/// 默认缓存会让进程多占几百 MB，回收时还会卡一下。可重复调用。
/// shader 的编译与预热交给 [HyperGlassWarmup]（带加载界面），这里不碰。
void warmUpHyperGlass() {
  if (_hyperWarm) return;
  _hyperWarm = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(limitSkiaResourceCache().catchError((Object _) {}));
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
        // 全屏切换约 300 ms 内引擎不能做背景模糊：保留材质的混合层、只去掉模糊，
        // 与 LiquidGlass 同样的退化方式（用不透明底色会闪出一块实色）
        if (transitioning) {
          return ClipRRect(borderRadius: borderRadius, child: layered);
        }
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

  /// 加载界面已挂上（下一帧起盖住整个窗口）。
  bool _covering = false;

  /// shader 已加载，底层预热场景开始真实绘制。
  bool _ready = false;
  int _frames = 0;
  final Stopwatch _clock = Stopwatch();

  static bool _logging = false;

  @override
  void initState() {
    super.initState();
    // 两种材质都记录，便于对比同一操作（如打开全屏歌词）在伪液态玻璃下是否也掉帧
    if (_logging) return;
    _logging = true;
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    Future<void>.delayed(
      const Duration(minutes: 2),
      () => WidgetsBinding.instance.removeTimingsCallback(_onTimings),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_done || _covering || !context.tokens.hyperMaterial) return;
    _covering = true;
    _clock.start();
    // 先让加载界面上屏，再开始编译：编译期间光栅线程被占满，窗口停在这一帧，
    // 用户看到的是「正在准备」而不是卡死的主界面
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      HyperGlassRenderer.shared().then(
        (_) async {
          if (!mounted) return;
          debugPrint(
            '[hyper_glass] shader 加载完成：${_clock.elapsedMilliseconds} ms',
          );
          await _warmBlurs();
          if (!mounted) return;
          setState(() => _ready = true);
          _countFrames();
        },
        onError: (Object e) {
          debugPrint('[hyper_glass] 预热失败：$e');
          if (mounted) setState(() => _done = true);
        },
      );
    });
  }

  /// Skia 的高斯模糊按模糊核宽度生成不同的 GPU 程序，每种强度第一次出现都要现编译
  /// （日志里单个约 200 ms）。柔光材质用到的几档（菜单 σ22、弹窗 σ32 / σ56、浮动栏 σ20）
  /// 在加载界面期间按当前像素密度各跑一次，之后打开菜单、弹窗、播放页就不会再卡。
  Future<void> _warmBlurs() async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final sigmas = {
      for (final m in const [
        BlendMaterial.popupMenuLight,
        BlendMaterial.dialogLight,
        BlendMaterial.dialogDark,
        BlendMaterial.appBarLight,
      ])
        m.sigma,
    };
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawCircle(
      const Offset(128, 128),
      90,
      Paint()..color = const Color(0xff3070c0),
    );
    final src = rec.endRecording().toImageSync(256, 256);
    for (final sigma in sigmas) {
      final clock = Stopwatch()..start();
      final r = ui.PictureRecorder();
      final c = ui.Canvas(r);
      c.saveLayer(
        null,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma * dpr,
            sigmaY: sigma * dpr,
            tileMode: TileMode.mirror,
          ),
      );
      c.drawImage(src, Offset.zero, Paint());
      c.restore();
      final img = r.endRecording().toImageSync(256, 256);
      await img.toByteData();
      img.dispose();
      debugPrint('[hyper_glass] 预热模糊 σ$sigma：${clock.elapsedMilliseconds} ms');
    }
    src.dispose();
  }

  /// 上屏预热期间每帧的光栅耗时：离屏预热之外，上屏绘制若再触发编译会在这里体现。
  /// 启动后 2 分钟内把光栅或构建超过 34 ms 的帧记进日志（两种材质都记），
  /// 用来定位首次打开歌词页、菜单、弹窗时还剩下的卡顿来自哪里。
  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final raster = t.rasterDuration.inMilliseconds;
      final build = t.buildDuration.inMilliseconds;
      if (raster < 34 && build < 34) continue;
      debugPrint('[hyper_glass] 慢帧：光栅 $raster ms，构建 $build ms');
    }
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
      debugPrint('[hyper_glass] 上屏预热完成：${_clock.elapsedMilliseconds} ms');
      setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hyper = context.tokens.hyperMaterial;
    final warming = !_done && _ready && hyper;
    final covering = !_done && _covering && hyper;
    // 结构始终是同一个 Stack（预热层 / 界面 / 加载界面），前后两层出现、消失时
    // 中间的界面不会被重新挂载
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
        if (!covering)
          const SizedBox.shrink()
        else
          const Positioned.fill(child: _PreparingScreen()),
      ],
    );
  }
}

/// 编译期间盖住整个窗口的加载界面。光栅线程被编译占满时画面不会刷新，
/// 所以这里只放静态内容，不放转圈动画。
class _PreparingScreen extends StatelessWidget {
  const _PreparingScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return AbsorbPointer(
      child: ColoredBox(
        color: scheme.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.blur_on_rounded,
                  size: 48,
                  color: context.tokens.accent,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.hyperGlassPreparingTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.hyperGlassPreparingBody,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
