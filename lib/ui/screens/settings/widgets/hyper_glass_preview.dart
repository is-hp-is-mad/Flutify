import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';
import 'package:hyper_glass/hyper_ui.dart'
    show ArcMenu, ArcMotion, Hy, HyperMenuItem, HyperTheme, Pressable, menuRectFor;

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';

/// 柔光玻璃（Beta）实时预览（对齐 `D:\miuiweather` 最新 `render_mode_card.dart` 样式）：
/// - 缓慢漂移的彩色光斑上，一块全宽可按压的 `HyperGlass` 卡片（展示当前渲染模式与折射高光）；
/// - 底部一排 `GlassTokens` 预设胶囊（通用大卡 / 着色紫 / 着色蓝 / 仿生玻璃）实时切换材质；
/// - 右上角保留 `HyperBlendBlur` + `ArcMenu` 弹出菜单，用于即时切换预览深浅色。
class HyperGlassPreview extends StatefulWidget {
  const HyperGlassPreview({super.key});

  static const double height = 246;

  /// 背景在可见区域外每边多画的宽度（logical px）。
  ///
  /// 玻璃的折射 / 反射会读卡片外约 37 logical px（reflectOffsetPx 110 物理像素 × dpr/3）的背景，
  /// 而场景只截取自己范围内的背景。卡片离可见边只有 14，没有这圈余量时四边会读到截图外，
  /// 被拉伸成一圈错位的折射。余量由外层 ClipRRect 裁掉，布局不变。
  static const double bleed = 48;

  @override
  State<HyperGlassPreview> createState() => _HyperGlassPreviewState();
}

class _HyperGlassPreviewState extends State<HyperGlassPreview>
    with TickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );
  late final ArcMotion _menu = ArcMotion(this);
  final _buttonKey = GlobalKey();
  final _stackKey = GlobalKey();
  int _selected = 0;
  int _presetIndex = 0;
  bool _pressed = false;

  static const double _menuWidth = 172;

  static final _presets = <(String Function(AppLocalizations), GlassFilter)>[
    ((l) => l.hyperGlassPresetLarge, GlassTokens.commonLargeRegular),
    ((l) => l.hyperGlassPresetPurple, GlassTokens.tintPurple),
    ((l) => l.hyperGlassPresetBlue, GlassTokens.tintBlue),
    ((l) => l.hyperGlassPresetBionic, GlassTokens.bionicMediumRegular),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = context.tokens.powerSaving || context.reduceMotion;
    if (still) {
      _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    _menu.dispose();
    super.dispose();
  }

  /// 按钮在预览坐标系里的位置（菜单的锚点）。
  Rect? _anchor() {
    final button = _buttonKey.currentContext?.findRenderObject();
    final stack = _stackKey.currentContext?.findRenderObject();
    if (button is! RenderBox || stack is! RenderBox) return null;
    return button.localToGlobal(Offset.zero, ancestor: stack) & button.size;
  }

  void _toggleMenu([bool? open]) =>
      setState(() => _menu.set(open ?? !_menu.open));

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l10n = context.l10n;
    final dark = switch (_selected) {
      1 => false,
      2 => true,
      _ => Theme.of(context).brightness == Brightness.dark,
    };
    final hsv = HSVColor.fromColor(tokens.accent);
    Color shifted(double deg) => hsv
        .withHue((hsv.hue + deg) % 360)
        .withSaturation(dark ? 0.75 : 0.62)
        .withValue(0.95)
        .toColor();
    final blobs = [
      (color: tokens.accent, size: 175.0, phase: 0.0),
      (color: shifted(60), size: 155.0, phase: 2.1),
      (color: shifted(-70), size: 145.0, phase: 4.2),
    ];
    final menuItems = [
      (Icons.brightness_auto_rounded, l10n.settingsThemeSystem),
      (Icons.light_mode_rounded, l10n.settingsThemeLight),
      (Icons.dark_mode_rounded, l10n.settingsThemeDark),
    ];
    final preset = _presets[_presetIndex];

    final background = AnimatedBuilder(
      animation: _drift,
      builder: (context, _) => CustomPaint(
        painter: _BlobPainter(
          base: dark ? const Color(0xFF14141A) : const Color(0xFFEDEFF4),
          blobs: blobs,
          t: _drift.value * 2 * math.pi,
          inset: HyperGlassPreview.bleed,
        ),
      ),
    );

    return ClipRRect(
      borderRadius: tokens.radius(16),
      child: SizedBox(
        height: HyperGlassPreview.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return AnimatedBuilder(
              animation: _menu.listenable,
              builder: (context, _) {
                final anchor = _anchor();
                return OverflowBox(
                  minWidth: size.width + 2 * HyperGlassPreview.bleed,
                  maxWidth: size.width + 2 * HyperGlassPreview.bleed,
                  minHeight: size.height + 2 * HyperGlassPreview.bleed,
                  maxHeight: size.height + 2 * HyperGlassPreview.bleed,
                  child: HyperGlassScene(
                  animate: _drift.isAnimating || _menu.active || _pressed,
                  background: background,
                  child: Padding(
                  padding: const EdgeInsets.all(HyperGlassPreview.bleed),
                  child: Stack(
                    key: _stackKey,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTapDown: (_) =>
                                    setState(() => _pressed = true),
                                onTapUp: (_) =>
                                    setState(() => _pressed = false),
                                onTapCancel: () =>
                                    setState(() => _pressed = false),
                                child: Pressable(
                                  scale: 0.97,
                                  onTap: () {},
                                  child: HyperGlass(
                                    filter: preset.$2,
                                    borderRadius: tokens.corner(22),
                                    bloom: dark
                                        ? BloomTokens.strokeMiddleDark
                                        : BloomTokens.strokeMiddleLight,
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        14,
                                        14,
                                        14,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 44,
                                            height: 44,
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.22,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            child: const Icon(
                                              Icons.auto_awesome_rounded,
                                              color: Colors.white,
                                              size: 24,
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  l10n.settingsHyperGlassPreview,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 15,
                                                    fontWeight:
                                                        FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  context.l10n.hyperGlassPreviewHint(preset.$1(context.l10n)),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          IgnorePointer(
                                            ignoring: _menu.open,
                                            child: _BlurButton(
                                              key: _buttonKey,
                                              dark: dark,
                                              label: menuItems[_selected].$2,
                                              onTap: () => _toggleMenu(true),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                for (final (idx, item) in _presets.indexed)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 3,
                                      ),
                                      child: GestureDetector(
                                        onTap: () => setState(
                                          () => _presetIndex = idx,
                                        ),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 7,
                                          ),
                                          decoration: BoxDecoration(
                                            color: idx == _presetIndex
                                                ? Colors.white.withValues(
                                                    alpha: 0.9,
                                                  )
                                                : Colors.black.withValues(
                                                    alpha: 0.34,
                                                  ),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          alignment: Alignment.center,
                                          child: Text(
                                            item.$1(context.l10n),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: idx == _presetIndex
                                                  ? Colors.black87
                                                  : Colors.white,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (anchor != null)
                        Positioned.fill(
                          child: Theme(
                            data: Theme.of(context).copyWith(
                              brightness: dark
                                  ? Brightness.dark
                                  : Brightness.light,
                            ),
                            child: HyperTheme(
                              primary: tokens.accent,
                              child: ArcMenu(
                                motion: _menu,
                                anchor: anchor,
                                menu: menuRectFor(
                                  anchor,
                                  size,
                                  _menuWidth,
                                  ArcMenu.heightFor(menuItems.length),
                                  growUp: false,
                                ),
                                onDismiss: () => _toggleMenu(false),
                                items: [
                                  for (final (i, (icon, label))
                                      in menuItems.indexed)
                                    HyperMenuItem(
                                      label,
                                      () {
                                        setState(() => _selected = i);
                                        _toggleMenu(false);
                                      },
                                      icon: icon,
                                      selected: i == _selected,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  ),
                ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// 浮动控件材质（thin glass）的胶囊按钮（HyperOS 弹出菜单的锚点）。
class _BlurButton extends StatelessWidget {
  final bool dark;
  final String label;
  final VoidCallback onTap;

  const _BlurButton({
    super.key,
    required this.dark,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = dark
        ? Colors.white.withValues(alpha: 0.92)
        : Colors.black.withValues(alpha: 0.88);
    return SizedBox(
      height: 36,
      child: ViewShadow(
        radius: 18,
        child: HyperBlendBlur(
          material: Hy.thinGlass(dark),
          borderRadius: 18,
          bloom: dark
              ? BloomTokens.strokeMiddleDark
              : BloomTokens.strokeMiddleLight,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.expand_more_rounded, color: fg, size: 17),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 三团沿椭圆轨迹缓慢漂移的柔边光斑。
///
/// 底色铺满整个画布；光斑按去掉四边 [inset] 后的可见区域定位，加了余量也不改变看到的样子。
class _BlobPainter extends CustomPainter {
  final Color base;
  final List<({Color color, double size, double phase})> blobs;
  final double t;
  final double inset;

  const _BlobPainter({
    required this.base,
    required this.blobs,
    required this.t,
    this.inset = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final visible = (Offset.zero & size).deflate(inset);
    for (final (i, b) in blobs.indexed) {
      final a = t + b.phase;
      final center = visible.topLeft +
          Offset(
            visible.width * (0.2 + 0.3 * i + 0.18 * math.cos(a)),
            visible.height * (0.5 + 0.32 * math.sin(a * (i.isEven ? 1 : -1))),
          );
      final radius = b.size * visible.height / HyperGlassPreview.height;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [b.color, b.color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(_BlobPainter old) =>
      old.t != t || old.base != base || old.blobs != blobs || old.inset != inset;
}
