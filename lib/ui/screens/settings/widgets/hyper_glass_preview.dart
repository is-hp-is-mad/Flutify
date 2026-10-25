import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_glass.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';

/// 柔光玻璃（Beta）实时预览：缓慢漂移的彩色光斑上，左边一块柔光玻璃卡片，
/// 右边一枚混色模糊按钮；点按钮会像 HyperOS 那样从按钮本身变形展开菜单。
///
/// 光斑颜色取当前强调色及其邻近色相，底色和菜单材质跟随深浅色；
/// 省电模式 / 减弱动效时光斑静止，玻璃也不再逐帧刷新。
class HyperGlassPreview extends StatefulWidget {
  const HyperGlassPreview({super.key});

  static const double height = 240;

  @override
  State<HyperGlassPreview> createState() => _HyperGlassPreviewState();
}

class _HyperGlassPreviewState extends State<HyperGlassPreview>
    with TickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );
  late final PopupMotion _menu = PopupMotion(this);
  final _buttonKey = GlobalKey();
  final _stackKey = GlobalKey();
  int _selected = 0;

  static const double _menuWidth = 180;
  static const double _itemHeight = 48;

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

  /// 按钮在预览坐标系里的位置（菜单从这里变形出来）。
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
    // 预览菜单里的「跟随系统 / 浅色 / 深色」直接切换预览自身的深浅，方便对比两套材质
    final dark = switch (_selected) {
      1 => false,
      2 => true,
      _ => Theme.of(context).brightness == Brightness.dark,
    };
    final hsv = HSVColor.fromColor(tokens.accent);
    Color shifted(double deg) => hsv
        .withHue((hsv.hue + deg) % 360)
        .withSaturation(dark ? 0.75 : 0.6)
        .withValue(0.95)
        .toColor();
    final blobs = [
      (color: tokens.accent, size: 170.0, phase: 0.0),
      (color: shifted(60), size: 150.0, phase: 2.1),
      (color: shifted(-70), size: 140.0, phase: 4.2),
    ];
    final menuItems = [
      (Icons.brightness_auto_rounded, l10n.settingsThemeSystem),
      (Icons.light_mode_rounded, l10n.settingsThemeLight),
      (Icons.dark_mode_rounded, l10n.settingsThemeDark),
    ];

    final background = AnimatedBuilder(
      animation: _drift,
      builder: (context, _) => CustomPaint(
        painter: _BlobPainter(
          base: dark ? const Color(0xFF14141A) : const Color(0xFFEDEFF4),
          blobs: blobs,
          t: _drift.value * 2 * math.pi,
        ),
      ),
    );

    return ClipRRect(
      borderRadius: tokens.radius(14),
      child: SizedBox(
        height: HyperGlassPreview.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return AnimatedBuilder(
              animation: _menu.listenable,
              builder: (context, _) {
                final anchor = _anchor();
                final swap = menuSwap(_menu.geometry.value);
                return HyperGlassScene(
                  animate: _drift.isAnimating || _menu.active,
                  background: background,
                  child: Stack(
                    key: _stackKey,
                    children: [
                      Positioned(
                        left: 20,
                        top: 24,
                        width: math.min(200, size.width * 0.42),
                        height: 120,
                        child: HyperGlass(
                          borderRadius: tokens.corner(24),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.lyrics_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                                const Spacer(),
                                Text(
                                  l10n.settingsHyperGlassPreview,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 20,
                        top: 24,
                        child: IgnorePointer(
                          ignoring: _menu.open,
                          child: Opacity(
                            opacity: 1 - swap,
                            child: _BlurButton(
                              key: _buttonKey,
                              dark: dark,
                              label: l10n.settingsHyperBlurPreview,
                              onTap: () => _toggleMenu(true),
                            ),
                          ),
                        ),
                      ),
                      if (anchor != null)
                        Positioned.fill(
                          child: MorphMenu(
                            motion: _menu,
                            anchor: anchor,
                            menu: menuRectFor(
                              anchor,
                              size,
                              _menuWidth,
                              _itemHeight * menuItems.length + 16,
                              growUp: false,
                            ),
                            dark: dark,
                            anchorRadius: anchor.height / 2,
                            itemHeight: _itemHeight,
                            onDismiss: () => _toggleMenu(false),
                            items: [
                              for (final (i, (icon, label))
                                  in menuItems.indexed)
                                MorphMenuItem(
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
                    ],
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

/// 混色模糊材质的胶囊按钮（HyperOS 弹出菜单的锚点）。
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
        ? Colors.white.withValues(alpha: 0.9)
        : Colors.black.withValues(alpha: 0.9);
    return SizedBox(
      height: 44,
      child: HyperBlendBlur(
        material: dark
            ? BlendMaterial.popupMenuDark
            : BlendMaterial.popupMenuLight,
        borderRadius: 22,
        // HyperBlendBlur 内部是 Stack，非定位子项只拿到宽松约束、贴左上；
        // 这里再给一次 44 高，文字才会垂直居中，悬停水波纹也才铺满整颗按钮
        child: SizedBox(
          height: 44,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.blur_on_rounded, color: fg, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: TextStyle(
                        color: fg,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.expand_more_rounded, color: fg, size: 20),
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
class _BlobPainter extends CustomPainter {
  final Color base;
  final List<({Color color, double size, double phase})> blobs;
  final double t;

  const _BlobPainter({
    required this.base,
    required this.blobs,
    required this.t,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    for (final (i, b) in blobs.indexed) {
      final a = t + b.phase;
      final center = Offset(
        size.width * (0.2 + 0.3 * i + 0.18 * math.cos(a)),
        size.height * (0.5 + 0.32 * math.sin(a * (i.isEven ? 1 : -1))),
      );
      final radius = b.size * size.height / HyperGlassPreview.height;
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
      old.t != t || old.base != base || old.blobs != blobs;
}
