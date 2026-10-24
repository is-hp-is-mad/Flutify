import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/l10n.dart';
import 'gradient_track_slider.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;
import '../../../widgets/flutify_dialog.dart';

/// 自定义强调色对话框：色相 / 饱和度 / 亮度三条渐变滑杆 + 十六进制输入 + 大色块预览。
///
/// 三条滑杆的轨道实时显示「拖到这里会是什么颜色」，比色轮更易精确控制。
class CustomColorDialog extends StatefulWidget {
  final Color initial;

  const CustomColorDialog({super.key, required this.initial});

  /// 返回用户确认的颜色；取消返回 null。
  static Future<Color?> show(BuildContext context, {required Color initial}) {
    return showDialog<Color>(context: context, builder: (_) => CustomColorDialog(initial: initial));
  }

  @override
  State<CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<CustomColorDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hex;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hex = TextEditingController(text: _hexOf(widget.initial));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) => (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  void _setHsv(HSVColor hsv) {
    setState(() => _hsv = hsv);
    _hex.text = _hexOf(hsv.toColor());
  }

  /// 输入满 6 位十六进制时立即应用；不完整时保持当前颜色。
  void _onHexChanged(String text) {
    if (text.length != 6) return;
    final value = int.tryParse(text, radix: 16);
    if (value == null) return;
    setState(() => _hsv = HSVColor.fromColor(Color(0xFF000000 | value)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final color = _hsv.toColor();

    return FlutifyDialog(
      title: l10n.settingsCustomColorTitle,
      content: Material(type: MaterialType.transparency, child: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    maxLength: 6,
                    onChanged: _onHexChanged,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]'))],
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: const InputDecoration(prefixText: '#  ', counterText: ''),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _Labeled(
              label: l10n.settingsHue,
              child: GradientTrackSlider(
                value: _hsv.hue / 360,
                colors: [
                  for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
                ],
                thumbColor: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                onChanged: (v) => _setHsv(_hsv.withHue(v * 360)),
              ),
            ),
            _Labeled(
              label: l10n.settingsSaturation,
              child: GradientTrackSlider(
                value: _hsv.saturation,
                colors: [_hsv.withSaturation(0).toColor(), _hsv.withSaturation(1).toColor()],
                thumbColor: color,
                onChanged: (v) => _setHsv(_hsv.withSaturation(v)),
              ),
            ),
            _Labeled(
              label: l10n.settingsBrightness,
              child: GradientTrackSlider(
                value: _hsv.value,
                colors: [Colors.black, _hsv.withValue(1).toColor()],
                thumbColor: color,
                onChanged: (v) => _setHsv(_hsv.withValue(v)),
              ),
            ),
          ],
        ),
      )),
      actions: [
        M3EButton.text(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        M3EButton.filled(onPressed: () => Navigator.pop(context, color), child: Text(l10n.commonDone)),
      ]);
  }
}

class _Labeled extends StatelessWidget {
  final String label;
  final Widget child;

  const _Labeled({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
