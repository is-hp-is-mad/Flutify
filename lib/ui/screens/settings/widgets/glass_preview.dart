import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/liquid_glass.dart';

/// 液态玻璃实时预览：几团彩色光斑上叠一块玻璃胶囊，拖动滑杆时即时可见效果。
///
/// 光斑颜色取当前强调色及其两个邻近色相，预览与真实歌词界面的观感接近。
///
/// [blur] / [opacity] 为拖动中的草稿值（0~1）：滑杆松手前只重绘预览本身，
/// 不触发全局主题重建；为 null 时使用已生效的主题值。
class GlassPreview extends StatelessWidget {
  final double? blur;
  final double? opacity;

  const GlassPreview({super.key, this.blur, this.opacity});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final hsv = HSVColor.fromColor(tokens.accent);
    Color shifted(double deg) => hsv.withHue((hsv.hue + deg) % 360).withSaturation(0.75).withValue(0.95).toColor();

    return ClipRRect(
      borderRadius: tokens.radius(14),
      child: SizedBox(
        height: 132,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF14141A)),
            _Blob(alignment: const Alignment(-0.85, -0.6), size: 120, color: tokens.accent),
            _Blob(alignment: const Alignment(0.15, 0.9), size: 110, color: shifted(60)),
            _Blob(alignment: const Alignment(0.9, -0.4), size: 100, color: shifted(-70)),
            Center(
              child: LiquidGlass(
                blur: blur == null ? null : FlutifyTokens.sigmaFor(blur!),
                tint: opacity == null ? null : FlutifyTokens.tintFor(opacity!),
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lyrics_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      context.l10n.settingsGlassPreview,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 柔边光斑：径向渐变从实色淡到透明。
class _Blob extends StatelessWidget {
  final Alignment alignment;
  final double size;
  final Color color;

  const _Blob({required this.alignment, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}
