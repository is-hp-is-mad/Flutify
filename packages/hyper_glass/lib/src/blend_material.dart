import 'dart:ui';

/// Blend modes used by HyperOS blendBlur materials (ids match shaders/mi_blend_blur.frag).
enum BlendLayerMode {
  srcOver,
  overlay,
  hardLight,
  softLight,
  colorBurn,
  colorDodge,
  luminosity,
  plusDarker,
  plusLighter,
  darken,
  color,
}

class BlendLayer {
  const BlendLayer(this.color, this.mode);
  final Color color;
  final BlendLayerMode mode;
}

/// HyperOS "blendBlur" material: Gaussian blur of the backdrop, then [layers] composited in order.
///
/// [sigma] is the blur sigma in logical pixels, as the `hyperos` package passes it to the engine.
class BlendMaterial {
  const BlendMaterial({required this.sigma, required this.layers, required this.fallback});

  final double sigma;
  final List<BlendLayer> layers;

  /// Solid colour used when blur is unavailable (also the colour text contrast is designed for).
  final Color fallback;

  // MIUIWeather libapp.so 0x56aa6c (called from the `hyperos.popup_menu` builder 0x94d63c):
  // sigma pp+0x2dc38 = 22, light layers pp+0x2dc28, dark layers pp+0x2dc30, fallbacks #ffffff / #242424.
  static const popupMenuLight = BlendMaterial(
    sigma: 22,
    fallback: Color(0xffffffff),
    layers: [
      BlendLayer(Color(0x05000000), BlendLayerMode.plusDarker),
      BlendLayer(Color(0x99ffffff), BlendLayerMode.softLight),
      BlendLayer(Color(0x66ffffff), BlendLayerMode.hardLight),
    ],
  );
  static const popupMenuDark = BlendMaterial(
    sigma: 22,
    fallback: Color(0xff242424),
    layers: [
      BlendLayer(Color(0x1a000000), BlendLayerMode.plusDarker),
      BlendLayer(Color(0x66565656), BlendLayerMode.luminosity),
      BlendLayer(Color(0x993f3f3f), BlendLayerMode.overlay),
    ],
  );

  // MiuiHome libapp.so: uninstall drop target / dialog (PKB::hIb closure 0x14bb4a8),
  // light Obj!hic@e485d1 (32, overlay + hardLight), dark Obj!hic@e485a1 (56, colorBurn + srcOver).
  static const dialogLight = BlendMaterial(
    sigma: 32,
    fallback: Color(0xfff7f7f7),
    layers: [
      BlendLayer(Color(0x33f9f9f9), BlendLayerMode.overlay),
      BlendLayer(Color(0xb3ffffff), BlendLayerMode.hardLight),
    ],
  );
  static const dialogDark = BlendMaterial(
    sigma: 56,
    fallback: Color(0xff1f1f1f),
    layers: [
      BlendLayer(Color(0x75000000), BlendLayerMode.colorBurn),
      BlendLayer(Color(0x52000000), BlendLayerMode.srcOver),
    ],
  );

  // MIUIWeather Obj!Tza@55b8d1 / @55b8f1 (pp+0x331a0 / pp+0x33198, used by closure 0x7b6bd8): the only
  // sigma-20 light/dark pair in the app. Used here for the floating bar behind the gradientBlur mask;
  // that it is the bar's material is inferred.
  static const appBarLight = BlendMaterial(
    sigma: 20,
    fallback: Color(0xfff7f7f7),
    layers: [
      BlendLayer(Color(0x1cffffff), BlendLayerMode.plusLighter),
      BlendLayer(Color(0x85a6a6a6), BlendLayerMode.overlay),
    ],
  );
  static const appBarDark = BlendMaterial(
    sigma: 20,
    fallback: Color(0xff1f1f1f),
    layers: [
      BlendLayer(Color(0x33585858), BlendLayerMode.plusDarker),
      BlendLayer(Color(0x1a666666), BlendLayerMode.colorBurn),
    ],
  );
}
