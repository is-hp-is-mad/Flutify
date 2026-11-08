import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'blend_material.dart';
import 'glass_filter.dart';
import 'hyper_glass_renderer.dart';
import 'view_shadow.dart';

/// 手动切换的三种柔光玻璃与混色模糊渲染方式：
/// 1. [xiaomiNative] — **小米原生**：直接调用小米 HyperOS ROM `android.view.View.setMiGlass` / `setMiBackgroundBlendColors` / `setMiBloomStroke` 原生系统扩展（非小米设备自动启用防崩溃保护）。
/// 2. [xiaomiPort] — **小米移植**：调用完全解耦的通用 Android AAR 库 (`com.hyperos.glass.widget.HyperGlassView`)，在 Android 13+ 使用标准 AGSL `RuntimeShader` + `RenderEffect`，在 Android 12 及以下使用 OpenGL ES 3.0 离屏 FBO (`HyperGlES30Pipeline`)，支持所有品牌 Android 机型。
/// 3. [flutterPort] — **纯移植**：纯 Flutter `FragmentShader` 跨平台多通道渲染管线 (`HyperGlassRenderer`)，不依赖 Android `PlatformView` 或高版本系统 API，兼容低版本 Android (API 21+) 与全平台。
enum HyperRenderMode {
  xiaomiNative('xiaomi_native', '小米原生', '小米 ROM View.setMiGlass 系统底层硬解'),
  xiaomiPort('xiaomi_port', '小米移植', '通用 Android SDK (AGSL RuntimeShader / GLES 3.0 FBO)'),
  flutterPort('flutter_port', '纯移植', '安卓低版本 / 跨平台 Flutter FragmentShader 管线');

  const HyperRenderMode(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;
}

/// 全局渲染方式与底层硬件能力状态控制器。
class HyperRenderController extends ChangeNotifier {
  HyperRenderController._();
  static final HyperRenderController instance = HyperRenderController._();

  HyperRenderMode _mode = HyperRenderMode.flutterPort;
  HyperRenderMode get mode => _mode;

  bool _queried = false;
  bool xiaomiNativeSupported = false;
  int hyperOsVersion = 0;
  String portBackend = 'AGSL_RUNTIME_SHADER';
  String forcedPortBackend = 'AUTO';
  bool agslSupported = true;
  bool gles30Supported = true;
  String deviceModel = '';

  void setMode(HyperRenderMode newMode) {
    if (_mode == newMode) return;
    _mode = newMode;
    notifyListeners();
  }

  Future<void> ensureCapabilitiesLoaded() async {
    if (_queried) return;
    _queried = true;
    await refreshCapabilities();
  }

  Future<void> refreshCapabilities() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      deviceModel = '${defaultTargetPlatform.name} (非 Android 平台)';
      notifyListeners();
      return;
    }
    try {
      final map = await HyperNativeRom._channel.invokeMapMethod<String, Object?>('getCapabilities');
      if (map != null) {
        xiaomiNativeSupported = map['xiaomiNativeSupported'] == true;
        hyperOsVersion = (map['hyperOsVersion'] as int?) ?? 0;
        portBackend = (map['portBackend'] as String?) ?? 'AGSL_RUNTIME_SHADER';
        forcedPortBackend = (map['forcedPortBackend'] as String?) ?? 'AUTO';
        agslSupported = map['agslSupported'] == true;
        gles30Supported = map['gles30Supported'] == true;
        deviceModel = (map['deviceModel'] as String?) ?? 'Android Device';
        notifyListeners();
      }
    } on Object {
      // Safe no-op on desktop or test harness
    }
  }

  Future<void> setPortBackend(String backendName) async {
    forcedPortBackend = backendName;
    notifyListeners();
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final map = await HyperNativeRom._channel.invokeMapMethod<String, Object?>(
        'setPortBackend',
        {'backend': backendName},
      );
      if (map != null) {
        forcedPortBackend = (map['forcedPortBackend'] as String?) ?? backendName;
        portBackend = (map['portBackend'] as String?) ?? portBackend;
        notifyListeners();
      }
    } on Object {
      // Ignore if channel unavailable
    }
  }
}

/// 便捷全局实例引用。
final HyperRenderController hyperRenderController = HyperRenderController.instance;

/// Bridge to the Android host supporting both **小米原生 (`xiaomi_native`)** and **小米移植 (`xiaomi_port`)**.
class HyperNativeRom {
  HyperNativeRom._();

  static const _channel = MethodChannel('hyper_glass/native_rom');

  static ({bool supported, bool supportGlass, int hyperOsVersion})? _caps;

  static Future<({bool supported, bool supportGlass, int hyperOsVersion})> queryCapabilities() async {
    if (_caps != null) return _caps!;
    if (defaultTargetPlatform != TargetPlatform.android) {
      return _caps = (supported: false, supportGlass: false, hyperOsVersion: 0);
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('getCapabilities');
      await hyperRenderController.ensureCapabilitiesLoaded();
      return _caps = (
        supported: map?['supported'] == true,
        supportGlass: map?['supportGlass'] == true,
        hyperOsVersion: (map?['hyperOsVersion'] as int?) ?? 0,
      );
    } on Object {
      return _caps = (supported: false, supportGlass: false, hyperOsVersion: 0);
    }
  }

  /// Packs [g] and [press] into the canonical `float[42]` array defined by `GlassToken.toShaderParams()`.
  static Float32List packGlassToken(GlassFilter g, {PressLight press = const PressLight()}) {
    final a = Float32List(42);
    for (var i = 0; i < 4 && i < g.luminanceBezier.length; i++) {
      a[i] = g.luminanceBezier[i];
    }
    a[4] = g.luminanceAmount;
    a[5] = g.saturation;
    a[6] = g.brightness;
    a[7] = g.darker;
    if (g.darkerRange.length >= 2) {
      a[8] = g.darkerRange[0];
      a[9] = g.darkerRange[1];
    }
    a[10] = g.innerBottom;
    for (var i = 0; i < 4 && i < g.glassColor.length; i++) {
      a[11 + i] = g.glassColor[i];
    }
    a[15] = g.innerColorWhite;
    a[16] = g.innerColorMix;
    a[17] = g.colorPow;
    a[18] = g.alpha;
    a[19] = g.edgePx;
    a[20] = g.edgePow;
    a[21] = g.thicknessPx;
    a[22] = g.reflectOffsetPx;
    a[23] = g.reflectionLighten;
    a[24] = g.reflectionStrength;
    for (var i = 0; i < 3 && i < g.lightDir.length; i++) {
      a[25 + i] = g.lightDir[i];
    }
    a[28] = g.lightIntensity;
    a[29] = g.lightOpposite;
    a[30] = g.lightAngleRange;
    a[31] = g.lightEdgePow;
    a[32] = g.refractIOR;
    a[33] = g.bgColorSaturation;
    a[34] = g.bgColorBrightness;
    a[35] = g.burn;
    a[36] = g.unshade;
    a[37] = press.fall;
    a[38] = press.strength;
    a[39] = press.peak;
    a[40] = press.ring1;
    a[41] = press.ring2;
    return a;
  }

  /// Packs [b] into the canonical `float[21]` array defined by `BloomStrokeConfig.toFloatArray()`.
  static Float32List packBloomStroke(BloomStroke b) {
    final a = Float32List(21);
    a[0] = b.width;
    a[1] = b.innerBlur;
    a[2] = b.color.r;
    a[3] = b.color.g;
    a[4] = b.color.b;
    a[5] = b.color.a;
    a[6] = 1.2;
    a[7] = 0.2;
    for (var i = 0; i < 2 && i < b.lightDir1.length; i++) {
      a[8 + i] = b.lightDir1[i];
    }
    a[10] = b.lightColor1.r;
    a[11] = b.lightColor1.g;
    a[12] = b.lightColor1.b;
    a[13] = b.lightColor1.a;
    for (var i = 0; i < 3 && i < b.lightDir2.length; i++) {
      a[14 + i] = b.lightDir2[i];
    }
    a[17] = b.lightColor2.r;
    a[18] = b.lightColor2.g;
    a[19] = b.lightColor2.b;
    a[20] = b.lightColor2.a;
    return a;
  }

  /// Maps [BlendLayerMode] to `com.hyperos.glass.token.BlendModeToken` values.
  static int toMiBlendMode(BlendLayerMode mode) => switch (mode) {
    BlendLayerMode.srcOver => 3,
    BlendLayerMode.darken => 16,
    BlendLayerMode.plusLighter => 121,
    BlendLayerMode.overlay => 15,
    BlendLayerMode.hardLight => 20,
    BlendLayerMode.softLight => 21,
    BlendLayerMode.colorBurn => 19,
    BlendLayerMode.colorDodge => 18,
    BlendLayerMode.luminosity => 28,
    BlendLayerMode.plusDarker => 120,
    BlendLayerMode.color => 27,
  };
}

/// Renders a surface using the Android `PlatformView` (`hyper_glass/native_view`) in either
/// **小米原生 (`xiaomi_native`)** or **小米移植 (`xiaomi_port`)** mode.
class HyperNativeRomSurface extends StatefulWidget {
  const HyperNativeRomSurface({
    super.key,
    this.renderBackend = 'xiaomi_port',
    this.glass,
    this.blend,
    this.gradientBlur = false,
    this.overlayMask,
    this.borderRadius = 24,
    this.bloom,
    this.shadow,
    this.wallpaperIndex = 1,
    this.dark = false,
    this.child,
  });

  final String renderBackend;
  final GlassFilter? glass;
  final BlendMaterial? blend;
  final bool gradientBlur;
  final ui.Color? overlayMask;
  final double borderRadius;
  final BloomStroke? bloom;
  final ShadowToken? shadow;
  final int wallpaperIndex;
  final bool dark;
  final Widget? child;

  @override
  State<HyperNativeRomSurface> createState() => _HyperNativeRomSurfaceState();
}

class _HyperNativeRomSurfaceState extends State<HyperNativeRomSurface> {
  static int _nextSurfaceKey = 1;
  late final int _surfaceKey = _nextSurfaceKey++;

  Map<String, Object?> _buildParams() => {
    'surfaceKey': _surfaceKey,
    'renderBackend': widget.renderBackend,
    'borderRadius': widget.borderRadius,
    'wallpaperIndex': widget.wallpaperIndex,
    'dark': widget.dark,
    if (widget.glass != null) ...{
      'mode': 'glass',
      'glassParams': HyperNativeRom.packGlassToken(widget.glass!),
      'smallBlur': widget.glass!.baseBlur.round(),
      'bigBlur': widget.glass!.refractBlur.round(),
    } else if (widget.blend != null) ...{
      'mode': widget.gradientBlur ? 'gradientBlur' : 'blend',
      'blurRadius': widget.blend!.sigma.round(),
      'blendColors': Int32List.fromList([for (final l in widget.blend!.layers) l.color.toARGB32()]),
      'blendModes': Int32List.fromList([for (final l in widget.blend!.layers) HyperNativeRom.toMiBlendMode(l.mode)]),
      if (widget.overlayMask != null) 'overlayMask': widget.overlayMask!.toARGB32(),
    },
    if (widget.bloom != null) 'bloomParams': HyperNativeRom.packBloomStroke(widget.bloom!),
    if (widget.shadow != null) ...{
      'shadowColor': ShadowToken.color.toARGB32(),
      'shadowOffsetY': widget.shadow!.offsetY,
      'shadowRadius': widget.shadow!.radius,
      'shadowDispersion': ShadowToken.dispersion,
    },
  };

  @override
  void didUpdateWidget(HyperNativeRomSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (defaultTargetPlatform == TargetPlatform.android) {
      HyperNativeRom._channel.invokeMethod<void>('updateSurface', _buildParams());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return widget.child ?? const SizedBox.shrink();
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        PlatformViewLink(
          viewType: 'hyper_glass/native_view',
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          ),
          onCreatePlatformView: (params) => PlatformViewsService.initSurfaceAndroidView(
            id: params.id,
            viewType: 'hyper_glass/native_view',
            layoutDirection: TextDirection.ltr,
            creationParams: _buildParams(),
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create(),
        ),
        if (widget.child != null) widget.child!,
      ],
    );
  }
}
