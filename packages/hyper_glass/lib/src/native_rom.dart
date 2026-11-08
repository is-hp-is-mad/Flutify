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

/// Direct bridge to Xiaomi HyperOS 3/4's system-level `android.view.View` material APIs
/// (`MiuiBlurUtils`, `HyperMaterialUtils`, `HyperBloomStrokeUtils`, `MiShadowUtils`) from the unpacked ROM
/// (`rom/design/miuix`), with zero reverse engineering required on Xiaomi devices and an Android 13+
/// `RuntimeShader` (`ActionBarContainer.GRADIENT_AGSL_SHADER`) fallback on generic Android.
class HyperNativeRom {
  HyperNativeRom._();

  static const _channel = MethodChannel('hyper_glass/native_rom');

  static ({bool supported, bool supportGlass, int hyperOsVersion})? _caps;

  /// Queries the Android host for Xiaomi HyperOS native material capabilities (`persist.sys.background_blur_supported`,
  /// `ro.mi.os.version.code`, and `View.setMiGlass` reflection from `HyperMaterialUtils.java`).
  static Future<({bool supported, bool supportGlass, int hyperOsVersion})> queryCapabilities() async {
    if (_caps != null) return _caps!;
    if (defaultTargetPlatform != TargetPlatform.android) {
      return _caps = (supported: false, supportGlass: false, hyperOsVersion: 0);
    }
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('getCapabilities');
      return _caps = (
        supported: map?['supported'] == true,
        supportGlass: map?['supportGlass'] == true,
        hyperOsVersion: (map?['hyperOsVersion'] as int?) ?? 0,
      );
    } on Object {
      return _caps = (supported: false, supportGlass: false, hyperOsVersion: 0);
    }
  }

  /// Packs [g] and [press] into the exact `float[42]` array expected by `GlassToken.toShaderParams()`
  /// and `View.setMiGlass(float[])` in `miuix.theme.token.GlassToken`.
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

  /// Packs [b] into the exact `float[21]` array expected by `View.setMiBloomStroke(float[])`
  /// in `miuix.core.util.HyperBloomStrokeUtils`.
  static Float32List packBloomStroke(BloomStroke b) {
    final a = Float32List(21);
    a[0] = b.width;
    a[1] = b.strokeFade ? 180.0 : 0.0;
    a[2] = b.color.r;
    a[3] = b.color.g;
    a[4] = b.color.b;
    a[5] = b.color.a;
    a[6] = b.innerBlur;
    for (var i = 0; i < 3 && i < b.lightDir1.length; i++) {
      a[7 + i] = b.lightDir1[i];
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

  /// Maps [BlendLayerMode] to `miuix.theme.token.BlendModeToken` (`android.graphics.PorterDuff.Mode` ordinal).
  static int toMiBlendMode(BlendLayerMode mode) => switch (mode) {
    BlendLayerMode.srcOver => 3,
    BlendLayerMode.darken => 16,
    BlendLayerMode.plusLighter => 12, // ADD
    BlendLayerMode.overlay => 15,
    BlendLayerMode.hardLight => 102,
    BlendLayerMode.softLight => 103,
    BlendLayerMode.colorBurn => 105,
    BlendLayerMode.colorDodge => 104,
    BlendLayerMode.luminosity => 109,
    BlendLayerMode.plusDarker => 110,
    BlendLayerMode.color => 108,
  };
}

/// Renders a surface using the Xiaomi ROM's native `android.view.View` pipeline (`setMiGlass`,
/// `setMiBackgroundBlendColors`, `setBackgroundGradientBlurParams`, `setMiBloomStroke`, `setMiShadow`)
/// via an Android `PlatformView` (`hyper_glass/native_view`).
class HyperNativeRomSurface extends StatelessWidget {
  const HyperNativeRomSurface({
    super.key,
    this.glass,
    this.blend,
    this.gradientBlur = false,
    this.overlayMask,
    this.borderRadius = 24,
    this.bloom,
    this.shadow,
    this.child,
  });

  final GlassFilter? glass;
  final BlendMaterial? blend;
  final bool gradientBlur;
  final ui.Color? overlayMask;
  final double borderRadius;
  final BloomStroke? bloom;
  final ShadowToken? shadow;
  final Widget? child;

  Map<String, Object?> _params() => {
    'borderRadius': borderRadius,
    if (glass != null) ...{
      'mode': 'glass',
      'glassParams': HyperNativeRom.packGlassToken(glass!),
      'smallBlur': glass!.baseBlur.round(),
      'bigBlur': glass!.refractBlur.round(),
    } else if (blend != null) ...{
      'mode': gradientBlur ? 'gradientBlur' : 'blend',
      'blurRadius': blend!.sigma.round(),
      'blendColors': Int32List.fromList([for (final l in blend!.layers) l.color.toARGB32()]),
      'blendModes': Int32List.fromList([for (final l in blend!.layers) HyperNativeRom.toMiBlendMode(l.mode)]),
      if (overlayMask != null) 'overlayMask': overlayMask!.toARGB32(),
    },
    if (bloom != null) 'bloomParams': HyperNativeRom.packBloomStroke(bloom!),
    if (shadow != null) ...{
      'shadowColor': ShadowToken.color.toARGB32(),
      'shadowOffsetY': shadow!.offsetY,
      'shadowRadius': shadow!.radius,
      'shadowDispersion': ShadowToken.dispersion,
    },
  };

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return child ?? const SizedBox.shrink();
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
          onCreatePlatformView: (params) => PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 'hyper_glass/native_view',
            layoutDirection: TextDirection.ltr,
            creationParams: _params(),
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create(),
        ),
        ?child,
      ],
    );
  }
}
