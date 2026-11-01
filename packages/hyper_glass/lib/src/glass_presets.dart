import 'dart:ui';

import 'blend_material.dart';
import 'glass_filter.dart';
import 'glass_tokens.g.dart';

/// Every glass material found in the OS4.0.4.0 ROM.
///
/// The `n(...)` arrays are the `View.setMiGlass` arguments, copied verbatim from MiuiSystemUI (Java effects
/// and res/values/arrays.xml; the trailing zeros are left out). Their blur pair is
/// notification_glass_{small,big}_blur_max_radius: 14.55dp / 181.82dp, 40 / 500 px at the ROM's density.
abstract final class GlassPresets {
  static GlassFilter n(List<double> a, {double small = 40}) => GlassFilter.native(a, small: small);

  /// MIUIWeather `_Rhb` -> `ImageFilter.glass` (reverse engineered call, exact).
  static const weather = GlassFilter();

  // notification_glass_params_normal; also MiBackgroundStyle, FlipRow, GroupCollapseButton, MediaDeleteMenu
  static final notification = n(const [
    0.67, 0.16, 0.09, 0, 0.24, 1.4, -0.02, 0.3, 0.6, 1, 0.03, 1, 1, 1, 0.1, 0.2, 0.3, 1, 1, 72, 3.8, 80, 800, 1.2, 1,
    -0.4, 0.6, -0.8, 1.4, 0.7, 0.8, 1.15, 4, 2,
  ]);
  // notification_glass_params_on_keyguard
  static final notificationKeyguard = n(const [
    0, 2, 0.3, 0.4, 0.15, 1.4, 0.08, 0.2, 0.6, 1, 0.03, 1, 1, 1, 0.15, 0.15, 0.4, 1.2, 1, 72, 3.8, 80, 1000, 1, 0.8,
    -0.4, 0.6, -0.8, 1.3, 0.6, 0.8, 1.15, 3, 2.4,
  ]);
  // notification_glass_params_full_aod
  static final notificationAod = n(const [
    0.9, 0.7, 0.4, 0.2, 0.34, 1.2, 0, 0.4, 0.6, 1, 0.02, 1, 1, 1, 0.1, 0.26, 0.3, 1.8, 1, 72, 3.8, 80, 1000, 1, 0.8,
    -0.4, 0.6, -0.8, 1.1, 0.6, 0.8, 1.15, 3, 0,
  ]);
  // focus_notification_glass_params_normal
  static final focus = n(const [
    0.6, 0.22, 0.24, 0, 0.2, 1.8, 0.1, 0.3, 0.6, 1, 0.02, 0.06, 0.06, 0.06, 0.7, 0.2, 0.3, 1, 1, 72, 3.8, 80, 1200, 1.4,
    1.2, -0.4, 0.6, -0.8, 1.3, 0.9, 1.4, 1.15, 3, 4,
  ]);
  // focus_notification_glass_params_on_keyguard
  static final focusKeyguard = n(const [
    0, 2, 0.5, 0.8, 0.15, 1.4, 0.3, 0.2, 0.6, 1, 0.02, 0.06, 0.06, 0.06, 0.5, 0.15, 0.4, 1.36, 1, 72, 3.8, 80, 1000,
    1.4, 0.8, -0.4, 0.6, -0.8, 1.6, 1.2, 0.8, 1.15, 3, 3,
  ]);
  // focus_notification_glass_params_full_aod
  static final focusAod = n(const [
    2, 2, 0.4, 0.2, 0.4, 1.6, 0.15, 0.4, 0.6, 1, 0.02, 0.06, 0.06, 0.06, 0.5, 0.26, 0.3, 1.8, 1, 72, 3.8, 80, 1000, 1,
    0.8, -0.4, 0.6, -0.8, 1.6, 1.2, 0.8, 1.15, 3, 0,
  ]);
  // HeadsUpNotificationGlassEffect
  static final headsUp = n(const [
    0.5, 1, 0, 0.8, 0.5, 1.2, 0, 0.2, -0.001, 0, 0.03, 1, 1, 1, 1.5, 0, 0.6, 0.6, 1, 62, 3.8, 80, 600, 1, 0.8, -0.4, 0.6,
    -0.8, 1.2, 0.6, 0.8, 1.15, 3, 0,
  ], small: 50);
  // HeadsUpNotificationGlassDarkEffect
  static final headsUpDark = n(const [
    0.8, 1, 0, 1, 0.2, 2, 0.14, 0.1, -0.001, 0, 0.02, 0.27, 0.27, 0.27, 0.6, 0, 0.2, 1.2, 1, 72, 3.8, 80, 600, 1, 0.8,
    -0.4, 0.6, -0.8, 1.5, 1, 0.8, 1.15, 3, 0,
  ], small: 50);
  // MediaDeleteMenuGlassOnKeyguardLightWallPaperEffect
  static final keyguardLightWallpaper = n(const [
    0, 2, 0.5, 0.8, 0.15, 1.4, 0.08, 0.2, 0.6, 1, 0.05, 1, 1, 1, 0.15, 0.15, 0.4, 1.2, 1, 60, 4, 60, 1000, 1, 0.8, -0.4,
    0.6, -0.8, 1.4, 0.8, 1.4, 1, 3, 2.4,
  ]);
  // NotificationDismissViewGlassEffect
  static final dismiss = n(const [
    0.42, 0.22, 0.24, 0, 0.45, 1.4, 0.28, 0.4, 0.6, 1, 0.03, 1, 1, 1, 0.1, 0.2, 0.3, 1, 1, 62, 4, 80, 1200, 1.2, 1, -0.4,
    0.6, -0.8, 1.3, 0.8, 0.8, 1.15, 4, 2.6,
  ]);
  // lockscreen TimeView: the clock digits' glass
  static final clock = n(const [
    0.05, 0.35, 0.5, 0.55, 1, 2, 0.3, 0, 0, 1, 0.05, 1, 1, 1, 0.4, 0.8, 0, 1.1, 1, 30, 2, 200, 400, 0.3, 2, -2, 2, -1, 6,
    3, 0.3, 1.1764705, 1.33, 1,
  ]);

  /// Which token MiuiHome passes for these is inferred from the token names and sizes.
  static final launcherFolder = GlassTokens.commonLargeRegular;
  static final launcherDock = GlassTokens.commonMediumThinHigh;

  static Map<String, GlassFilter> get all => {
    '天气卡片 · 逆向': weather,
    '通知 · 普通': notification,
    '通知 · 锁屏': notificationKeyguard,
    '通知 · 息屏': notificationAod,
    '焦点通知 · 普通': focus,
    '焦点通知 · 锁屏': focusKeyguard,
    '焦点通知 · 息屏': focusAod,
    '悬浮通知 · 浅': headsUp,
    '悬浮通知 · 深': headsUpDark,
    '锁屏浅色壁纸': keyguardLightWallpaper,
    '清除按钮': dismiss,
    '锁屏时钟': clock,
    for (final e in GlassTokens.all.entries) e.key: e.value,
  };
}

/// Blend-blur materials of the ROM. Every entry comes from [BlendMaterial] or MIUIWeather's object pool.
abstract final class BlendPresets {
  static const menuAltLight = BlendMaterial(
    sigma: 22,
    fallback: Color(0xffffffff),
    layers: [
      BlendLayer(Color(0x05000000), BlendLayerMode.plusDarker),
      BlendLayer(Color(0x99ffffff), BlendLayerMode.softLight),
      BlendLayer(Color(0x99ffffff), BlendLayerMode.hardLight),
    ],
  );
  static const menuAltDark = BlendMaterial(
    sigma: 22,
    fallback: Color(0xff242424),
    layers: [
      BlendLayer(Color(0x1a000000), BlendLayerMode.plusDarker),
      BlendLayer(Color(0x996c6c6c), BlendLayerMode.luminosity),
      BlendLayer(Color(0x99060606), BlendLayerMode.softLight),
    ],
  );
  // MiuiHome: the accent pair, sigma 60
  static const primaryLight = BlendMaterial(
    sigma: 60,
    fallback: Color(0xff3482ff),
    layers: [
      BlendLayer(Color(0xccffffff), BlendLayerMode.plusDarker),
      BlendLayer(Color(0xe63482ff), BlendLayerMode.srcOver),
    ],
  );
  static const primaryDark = BlendMaterial(
    sigma: 60,
    fallback: Color(0xff277af7),
    layers: [
      BlendLayer(Color(0xccffffff), BlendLayerMode.plusDarker),
      BlendLayer(Color(0xe64788ff), BlendLayerMode.srcOver),
    ],
  );

  static Map<String, (BlendMaterial, BlendMaterial)> get all => {
    '弹出菜单': (BlendMaterial.popupMenuLight, BlendMaterial.popupMenuDark),
    '弹出菜单 · 高亮': (menuAltLight, menuAltDark),
    '系统弹窗': (BlendMaterial.dialogLight, BlendMaterial.dialogDark),
    '悬浮顶栏': (BlendMaterial.appBarLight, BlendMaterial.appBarDark),
    '强调色': (primaryLight, primaryDark),
  };
}
