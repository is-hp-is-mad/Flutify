import 'package:flutter/material.dart';

/// 圆角风格：影响卡片、封面、面板、按钮等所有圆角。
enum CornerStyle {
  /// 更圆润：圆角放大约 1.35 倍。
  rounded(1.35),

  /// 标准（默认）：MD3E 原始圆角。
  standard(1.0),

  /// 方正：圆角缩小到约 0.4 倍，胶囊按钮也变为小圆角矩形。
  square(0.4);

  final double scale;
  const CornerStyle(this.scale);
}

/// 玻璃材质（设置页「材质」）。
enum GlassMaterial {
  /// 伪液态玻璃：BackdropFilter 模糊 + 淡填充 + 发丝描边（默认）。
  liquid,

  /// 柔光玻璃（Beta）：HyperOS 4 的折射玻璃与混色模糊（packages/hyper_glass）。
  hyper,
}

/// 预设强调色。第一项为默认的 Spotify 绿。
enum AccentPreset {
  spotify(Color(0xFF1ED760)),
  ocean(Color(0xFF3D8BFF)),
  violet(Color(0xFFA06BFF)),
  rose(Color(0xFFFF5C8A)),
  sunset(Color(0xFFFF7A45)),
  amber(Color(0xFFFFC23D)),
  aqua(Color(0xFF2EE6D6));

  final Color color;
  const AccentPreset(this.color);
}

/// 用户的外观偏好（不可变，持久化为 JSON）。
///
/// 数值型偏好都归一化到 0~1，由主题层换算为具体的模糊半径 / 透明度，
/// 这样以后调整视觉参数不需要迁移已保存的设置。
@immutable
class AppearanceSettings {
  final ThemeMode themeMode;

  /// 强调色（预设色或自定义色）。
  final Color accent;

  /// 为 true 时，强调色跟随当前播放曲目的封面主色（无播放时回退到 [accent]）。
  final bool dynamicAccent;

  final GlassMaterial glassMaterial;

  /// 液态玻璃模糊强度 0~1。
  final double glassBlur;

  /// 液态玻璃不透明度 0~1（越大玻璃越「实」）。
  final double glassOpacity;

  /// 深色模式下使用纯黑背景（OLED 省电）。
  final bool pureBlack;

  /// 字号缩放（与系统字号相乘）。
  final double fontScale;

  final CornerStyle cornerStyle;

  /// 减弱动效：关闭流动背景、滑动 / 悬停等装饰性动画（系统「减少动态效果」同样生效）。
  final bool reduceMotion;

  /// 省电模式：玻璃不再实时模糊下方画面（改为半透明磨砂底），歌词页流动背景静止。
  /// 歌词滚动、模糊、当前句动效全部保留。
  final bool powerSaving;

  /// 整窗帧率上限（fps）；0 = 跟随屏幕刷新率。动画仍按真实时间推进，只是出帧更少。
  final int frameRateLimit;

  static const int minFrameRateLimit = 30;
  static const int maxFrameRateLimit = 240;

  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.3;

  const AppearanceSettings({
    this.themeMode = ThemeMode.system,
    this.accent = const Color(0xFF1ED760),
    this.dynamicAccent = false,
    this.glassMaterial = GlassMaterial.liquid,
    this.glassBlur = 0.6,
    this.glassOpacity = 0.3,
    this.pureBlack = false,
    this.fontScale = 1.0,
    this.cornerStyle = CornerStyle.standard,
    this.reduceMotion = false,
    this.powerSaving = false,
    this.frameRateLimit = 0,
  });

  static const AppearanceSettings defaults = AppearanceSettings();

  AppearanceSettings copyWith({
    ThemeMode? themeMode,
    Color? accent,
    bool? dynamicAccent,
    GlassMaterial? glassMaterial,
    double? glassBlur,
    double? glassOpacity,
    bool? pureBlack,
    double? fontScale,
    CornerStyle? cornerStyle,
    bool? reduceMotion,
    bool? powerSaving,
    int? frameRateLimit,
  }) {
    return AppearanceSettings(
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
      dynamicAccent: dynamicAccent ?? this.dynamicAccent,
      glassMaterial: glassMaterial ?? this.glassMaterial,
      glassBlur: glassBlur ?? this.glassBlur,
      glassOpacity: glassOpacity ?? this.glassOpacity,
      pureBlack: pureBlack ?? this.pureBlack,
      fontScale: fontScale ?? this.fontScale,
      cornerStyle: cornerStyle ?? this.cornerStyle,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      powerSaving: powerSaving ?? this.powerSaving,
      frameRateLimit: frameRateLimit ?? this.frameRateLimit,
    );
  }

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'accent': accent.toARGB32(),
        'dynamicAccent': dynamicAccent,
        'glassMaterial': glassMaterial.name,
        'glassBlur': glassBlur,
        'glassOpacity': glassOpacity,
        'pureBlack': pureBlack,
        'fontScale': fontScale,
        'cornerStyle': cornerStyle.name,
        'reduceMotion': reduceMotion,
        'powerSaving': powerSaving,
        'frameRateLimit': frameRateLimit,
      };

  /// 宽松解析：缺失或非法的字段回退到默认值，旧版本保存的设置也能读。
  factory AppearanceSettings.fromJson(Map<String, dynamic> json) {
    const d = defaults;
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    double unit(Object? v, double fallback) => v is num ? v.toDouble().clamp(0.0, 1.0) : fallback;

    return AppearanceSettings(
      themeMode: pick(ThemeMode.values, json['themeMode'], d.themeMode),
      accent: json['accent'] is int ? Color(json['accent'] as int) : d.accent,
      dynamicAccent: json['dynamicAccent'] is bool ? json['dynamicAccent'] as bool : d.dynamicAccent,
      glassMaterial: pick(GlassMaterial.values, json['glassMaterial'], d.glassMaterial),
      glassBlur: unit(json['glassBlur'], d.glassBlur),
      glassOpacity: unit(json['glassOpacity'], d.glassOpacity),
      pureBlack: json['pureBlack'] is bool ? json['pureBlack'] as bool : d.pureBlack,
      fontScale: json['fontScale'] is num
          ? (json['fontScale'] as num).toDouble().clamp(minFontScale, maxFontScale)
          : d.fontScale,
      cornerStyle: pick(CornerStyle.values, json['cornerStyle'], d.cornerStyle),
      reduceMotion: json['reduceMotion'] is bool ? json['reduceMotion'] as bool : d.reduceMotion,
      powerSaving: json['powerSaving'] is bool ? json['powerSaving'] as bool : d.powerSaving,
      // 0 = 跟随屏幕；其余夹到合法区间
      frameRateLimit: json['frameRateLimit'] is int && json['frameRateLimit'] != 0
          ? (json['frameRateLimit'] as int).clamp(minFrameRateLimit, maxFrameRateLimit)
          : d.frameRateLimit,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppearanceSettings &&
      other.themeMode == themeMode &&
      other.accent == accent &&
      other.dynamicAccent == dynamicAccent &&
      other.glassMaterial == glassMaterial &&
      other.glassBlur == glassBlur &&
      other.glassOpacity == glassOpacity &&
      other.pureBlack == pureBlack &&
      other.fontScale == fontScale &&
      other.cornerStyle == cornerStyle &&
      other.reduceMotion == reduceMotion &&
      other.powerSaving == powerSaving &&
      other.frameRateLimit == frameRateLimit;

  @override
  int get hashCode => Object.hash(
        themeMode,
        accent,
        dynamicAccent,
        glassMaterial,
        glassBlur,
        glassOpacity,
        pureBlack,
        fontScale,
        cornerStyle,
        reduceMotion,
        powerSaving,
        frameRateLimit,
      );
}
