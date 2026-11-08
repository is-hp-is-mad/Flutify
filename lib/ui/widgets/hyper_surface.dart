import 'dart:async';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';
import 'package:hyper_glass/hyper_ui.dart' show Hy;

import '../../core/debug_toggles.dart';
import '../../core/perf_flags.dart';
import '../../core/theme/flutify_tokens.dart';
import '../shell/desktop/desktop_window.dart';
import 'hyper_icons.dart';

bool _hyperWarm = false;

/// 选了柔光玻璃时把 Skia 的 GPU 资源缓存压到 32 MB（每次玻璃刷新都会分配离屏纹理，
/// 默认缓存会让进程多占几百 MB，回收时还会卡一下），并载入 `ViewShadow` 的 shader。可重复调用。
/// 玻璃 shader 的编译与预热交给 [HyperGlassWarmup]，这里不碰。
void warmUpHyperGlass() {
  if (_hyperWarm) return;
  _hyperWarm = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(HyperGlass.init().catchError((Object _) {}));
    unawaited(HyperIcons.ensure());
  });
}

/// HyperOS 混色模糊（blendBlur）表面：菜单、弹窗、浮层用。
///
/// 与 `HyperBlendBlur` 同一套材质参数（[BlendMaterial]：模糊半径 + 最多三层混合色）和
/// Bloom 描边，但不需要 `HyperGlassScene`：模糊交给单层 `BackdropFilter.grouped`
/// （与 LiquidGlass 一样只用纯 blur，规避 Windows 引擎 compose 滤镜崩溃），混合层直接按
/// [BlendMode] 画在模糊后的画面上，所以能浮在整个应用任意位置。
///
/// 省电模式、关闭背景模糊、全屏切换过渡期间退回材质自带的 [BlendMaterial.fallback] 纯色。
class HyperBlendSurface extends StatelessWidget {
  final BlendMaterial material;
  final BorderRadius borderRadius;
  final Widget child;

  /// Bloom 描边，画在混合层之上、[child] 之下。
  final BloomStroke? bloom;

  /// 系统阴影（`ShadowToken.Regular`），浮动控件和菜单用，弹窗没有。
  final bool shadow;

  const HyperBlendSurface({
    super.key,
    required this.material,
    required this.borderRadius,
    required this.child,
    this.bloom,
    this.shadow = false,
  });

  // 与 miuix 的 maskBlur 同一单位：是 LM 半径（dp），不是高斯 sigma，见 [blurSigma]
  static const double _menuBlur = 60; // popupview-glass
  static const double _dialogBlur = 100; // dialog-default
  static const double _barBlur = 20; // internal-pured-thin-glass

  /// 材质用到的全部模糊半径（启动预热用）。
  static const List<double> blurRadii = [
    _barBlur,
    _menuBlur,
    _dialogBlur,
    ...HyperAppBarBackground.bandRadii,
  ];

  static bool _dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static BlendMaterial _popup(BuildContext context) => _dark(context)
      ? BlendMaterial.popupMenuDark
      : BlendMaterial.popupMenuLight;

  /// LM 半径换算成高斯 sigma（libhwui generateLMGaussianBlur：半径 × 0.25 × 0.45）。
  static double blurSigma(double radius) => radius * 0.25 * 0.45;

  /// 弹出菜单材质：`Pured_Thin_Glass` + maskBlur 60。
  static BlendMaterial menu(BuildContext context) {
    final base = _popup(context);
    return BlendMaterial(
      sigma: _menuBlur,
      layers: base.layers,
      fallback: base.fallback,
    );
  }

  static BloomStroke menuBloom(BuildContext context) => _dark(context)
      ? BloomTokens.strokeSmallDark
      : BloomTokens.strokeSmallLight;

  /// 弹窗材质：`Pured_Thin` / `Pured_Regular` + maskBlur 100。
  static BlendMaterial dialog(BuildContext context) => BlendMaterial(
    sigma: _dialogBlur,
    layers: _popup(context).layers,
    fallback: Hy.card(_dark(context)),
  );

  static BloomStroke dialogBloom(BuildContext context) => _dark(context)
      ? BloomTokens.strokeSmallLight
      : BloomTokens.strokeBigLight;

  /// 浮动控件材质（thin glass：名字叫玻璃，实际是混色模糊），场景外的玻璃表面用它。
  static BlendMaterial bar(BuildContext context) => Hy.thinGlass(_dark(context));

  static BloomStroke barBloom(BuildContext context) => _dark(context)
      ? BloomTokens.strokeMiddleDark
      : BloomTokens.strokeMiddleLight;

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
    final radius = borderRadius.topLeft.x;
    final layered = CustomPaint(
      painter: _BlendLayersPainter(
        material.layers,
        bloom,
        radius,
        MediaQuery.devicePixelRatioOf(context),
      ),
      child: child,
    );
    final sigma = blurSigma(material.sigma);
    final surface = ValueListenableBuilder<bool>(
      valueListenable: DesktopWindow.fullscreenTransition,
      builder: (context, transitioning, _) {
        // 全屏切换期间（约 1 s）引擎不能做背景模糊：垫一层磨砂表面色再叠混合层，
        // 与 LiquidGlass 同样的退化方式（不垫底会透出下面的内容）
        if (transitioning) {
          return ClipRRect(
            borderRadius: borderRadius,
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHigh.withValues(alpha: 0.86),
              child: layered,
            ),
          );
        }
        return ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter.grouped(
            filter: ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.mirror,
            ),
            child: layered,
          ),
        );
      },
    );
    if (!shadow) return surface;
    return ViewShadow(radius: radius, hollow: true, child: surface);
  }
}

/// 顶栏背景（miuix ActionBarContainer 的渐变模糊）：上面模糊，往下逐渐清晰，放进 AppBar 的
/// `flexibleSpace`，AppBar 自身要透明。
///
/// `BackdropFilter` 不能加渐变遮罩（遮罩的离屏层里没有背景可采样），所以切成几条，模糊半径逐条
/// 减小到接近 0，再叠一层同样渐隐的窗口色盖住接缝。
class HyperAppBarBackground extends StatelessWidget {
  final Color? tintColor;
  final bool showBottomLine;
  final bool isDesktop;

  const HyperAppBarBackground({
    super.key,
    this.tintColor,
    this.showBottomLine = true,
    this.isDesktop = false,
  });

  /// 移动端：从上到下每一条的 LM 半径，平滑羽化归零。
  static const List<double> bandRadii = [60, 52, 44, 36, 28, 20, 12, 4];

  /// 桌面端：从上到下每一条的 LM 半径，与表头下半段 [28, 20, 12, 4] 顺畅衔接。
  static const List<double> desktopBandRadii = [60, 52, 44, 36];

  // 遮罩的位置取自 miuix 的 gradientBlur
  static const List<double> _tintAlpha = [0.82, 0.70, 0.48, 0.24, 0.0];
  static const List<double> _tintStops = [0, 0.48, 0.70, 0.88, 1.0];

  // 移动端着色玻璃（Tint Glass）：色彩高饱和晶莹透亮，下沿平滑羽化归零
  static const List<double> _translucentTintAlpha = [0.90, 0.78, 0.55, 0.25, 0.0];

  // 桌面端着色玻璃（Tint Glass）：保留通透渐变，下沿 0.65 保底与表头完美无缝咬合
  static const List<double> _desktopTintAlpha = [0.92, 0.85, 0.76, 0.65];
  static const List<double> _desktopTintStops = [0.0, 0.35, 0.70, 1.0];

  @override
  Widget build(BuildContext context) {
    final window = Theme.of(context).colorScheme.surface;
    final effectiveColor = tintColor ?? window;
    final alphas = isDesktop
        ? _desktopTintAlpha
        : (tintColor != null ? _translucentTintAlpha : _tintAlpha);
    final stops = isDesktop ? _desktopTintStops : _tintStops;
    final activeBandRadii = isDesktop ? desktopBandRadii : bandRadii;
    final solid = ColoredBox(color: effectiveColor);
    if (context.tokens.powerSaving ||
        PerfFlags.noBackdrop ||
        DebugToggles.of(context).isOff(DebugToggle.glassBackdrop)) {
      return solid;
    }
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopWindow.fullscreenTransition,
      builder: (context, transitioning, _) {
        if (transitioning) return solid;
        return Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                for (final radius in activeBandRadii)
                  Expanded(
                    child: ClipRect(
                      child: BackdropFilter.grouped(
                        filter: ImageFilter.blur(
                          sigmaX: HyperBlendSurface.blurSigma(radius),
                          sigmaY: HyperBlendSurface.blurSigma(radius),
                          tileMode: TileMode.mirror,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
              ],
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    for (final a in alphas) effectiveColor.withValues(alpha: a),
                  ],
                  stops: stops,
                ),
              ),
            ),
            if (tintColor != null && showBottomLine)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 0.6,
                child: ColoredBox(
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 页面左上角的圆形玻璃按钮（miuix 的 FloatingBar 返回键：40dp、浮动控件材质）。
class HyperCircleIcon extends StatelessWidget {
  final IconData icon;

  const HyperCircleIcon(this.icon, {super.key});

  static const double size = 40;

  /// AppBar 的图标槽：未发生滚动时不画实体底盘，采用 HyperOS 原生纤细图标避免遮挡正文。
  static Widget inIconSlot(IconData icon) => Center(
    child: Icon(
      icon,
      size: 19,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: HyperBlendSurface(
        material: HyperBlendSurface.bar(context),
        borderRadius: BorderRadius.circular(size / 2),
        bloom: HyperBlendSurface.barBloom(context),
        shadow: true,
        child: Center(
          child: Icon(
            icon,
            size: 22,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}


/// HyperOS 规范的返回按钮：未发生滚动时为纯净纤细箭头（19dp），一旦向下滑动列表触发顶栏模糊，
/// 背后平滑淡入并弹性缩放浮现出一个细节性的柔光玻璃圆形突出底座（HyperBlendSurface）。
class HyperBackButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool floating;
  final Color? color;

  const HyperBackButton({
    super.key,
    this.onPressed,
    this.floating = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return Center(
      child: SizedBox.square(
        dimension: 40,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed ?? () => Navigator.maybePop(context),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: floating ? 1 : 0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            builder: (context, v, child) => Stack(
              fit: StackFit.expand,
              children: [
                if (v > 0.001)
                  Transform.scale(
                    scale: 0.8 + 0.2 * v,
                    child: Opacity(
                      opacity: v,
                      child: HyperBlendSurface(
                        material: HyperBlendSurface.bar(context),
                        borderRadius: BorderRadius.circular(20),
                        bloom: HyperBlendSurface.barBloom(context),
                        shadow: true,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                child!,
              ],
            ),
            child: Center(
              child: Icon(Icons.arrow_back_rounded, color: fg, size: 19),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把材质的混合层依次叠在模糊后的画面上（与 mi_blend_blur.frag 的合成顺序一致），
/// 最后加上 Bloom 描边。
class _BlendLayersPainter extends CustomPainter {
  final List<BlendLayer> layers;
  final BloomStroke? bloom;
  final double radius;
  final double dpr;

  const _BlendLayersPainter(this.layers, this.bloom, this.radius, this.dpr);

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
    final b = bloom;
    if (b != null) {
      HyperGlassRenderer.ready?.paintBloom(canvas, size, b, radius, dpr);
    }
  }

  @override
  bool shouldRepaint(_BlendLayersPainter old) =>
      old.layers != layers ||
      old.bloom != bloom ||
      old.radius != radius ||
      old.dpr != dpr;
}

/// 柔光玻璃首帧预热：选了柔光玻璃后，在界面最底层（被所有内容盖住的左上角一小块）
/// 真实画一次柔光玻璃和各种混色模糊表面，然后移除。全程在后台，界面照常显示。
///
/// [warmUpHyperGlass] 只在离屏纹理上跑过一遍；上屏绘制的目标格式和混合状态不同，
/// Skia 会在第一次上屏时重新编译这几段大 shader，歌词页 / 设置预览首次出现时整窗卡死数秒。
/// 这里把那次编译提前到第一帧之后，并记录耗时，便于在日志里核对。
class HyperGlassWarmup extends StatefulWidget {
  final Widget child;

  const HyperGlassWarmup({super.key, required this.child});

  @override
  State<HyperGlassWarmup> createState() => _HyperGlassWarmupState();
}

class _HyperGlassWarmupState extends State<HyperGlassWarmup> {
  static bool _done = false;

  bool _started = false;

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
    _since.start();
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_done || _started || !context.tokens.hyperMaterial) return;
    _started = true;
    _clock.start();
    // 先让界面上屏，再开始编译：窗口不用等 shader
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      HyperGlassRenderer.shared().then(
        (_) async {
          if (!mounted) return;
          debugPrint(
            '[hyper_glass] shader 加载完成：${_clock.elapsedMilliseconds} ms',
          );
          await ViewShadow.load();
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
  /// （日志里单个约 200 ms）。柔光材质用到的几档（[HyperBlendSurface.blurRadii]）
  /// 在启动时按当前像素密度各跑一次，之后打开菜单、弹窗、播放页就不会再卡。
  Future<void> _warmBlurs() async {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawCircle(
      const Offset(128, 128),
      90,
      Paint()..color = const Color(0xff3070c0),
    );
    final src = rec.endRecording().toImageSync(256, 256);
    for (final radius in HyperBlendSurface.blurRadii.toSet()) {
      final sigma = HyperBlendSurface.blurSigma(radius);
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
  static final Stopwatch _since = Stopwatch();

  static void _onTimings(List<FrameTiming> timings) {
    // 不用定时器（测试结束时会留下未触发的计时器），满 2 分钟后在回调里自行注销
    if (_since.elapsed > const Duration(minutes: 2)) {
      WidgetsBinding.instance.removeTimingsCallback(_onTimings);
      return;
    }
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
    // 结构始终是同一个 Stack（预热层 / 界面），预热层出现、消失时界面不会被重新挂载
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
            width: 24,
            height: 24,
            child: IgnorePointer(
              child: HyperGlassScene(
                animate: false,
                background: const ColoredBox(color: Color(0xff3070c0)),
                child: Row(
                  children: [
                    Expanded(
                      child: HyperGlass(
                        borderRadius: 1,
                        bloom: HyperBlendSurface.barBloom(context),
                      ),
                    ),
                    Expanded(
                      child: HyperBlendBlur(
                        material: HyperBlendSurface.menu(context),
                        borderRadius: 1,
                      ),
                    ),
                    // 场景外的表面：混合层和 Bloom 画在 BackdropFilter 里，是另一批 GPU 程序
                    Expanded(
                      child: HyperBlendSurface(
                        material: HyperBlendSurface.menu(context),
                        borderRadius: BorderRadius.circular(1),
                        bloom: HyperBlendSurface.menuBloom(context),
                        shadow: true,
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Expanded(
                      child: HyperBlendSurface(
                        material: HyperBlendSurface.dialog(context),
                        borderRadius: BorderRadius.circular(1),
                        bloom: HyperBlendSurface.dialogBloom(context),
                        child: const SizedBox.expand(),
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
