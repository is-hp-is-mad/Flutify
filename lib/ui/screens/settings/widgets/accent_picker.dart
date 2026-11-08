import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/appearance.dart';
import 'custom_color_dialog.dart';

/// 强调色色板：7 个预设 + 1 个「自定义」彩虹色块。
///
/// - 选中项外圈带一道与背景隔开的描边环（iOS 壁纸 / 图标颜色选择样式）；
/// - 自定义色被选中时，彩虹块中心显示该颜色；
/// - [dimmed] 为 true（已开启跟随封面取色）时整体半透明，仍可点选作为回退色。
class AccentPicker extends StatelessWidget {
  final Color selected;
  final bool dimmed;
  final ValueChanged<Color> onChanged;

  const AccentPicker({super.key, required this.selected, required this.onChanged, this.dimmed = false});

  static const double _size = 34;

  bool get _isCustom => AccentPreset.values.every((p) => p.color != selected);

  Future<void> _pickCustom(BuildContext context) async {
    final color = await CustomColorDialog.show(context, initial: selected);
    if (color != null) onChanged(color);
  }

  /// 色块之间的最小间距：判断一行放几个与单行排布用同一个值，否则临界宽度会溢出。
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    final swatches = <Widget>[
      for (final preset in AccentPreset.values)
        _Swatch(
          selected: preset.color == selected,
          onTap: () => onChanged(preset.color),
          child: _Fill(color: preset.color),
        ),
      _Swatch(
        selected: _isCustom,
        tooltip: context.l10n.settingsAccentCustom,
        onTap: () => _pickCustom(context),
        child: _RainbowFill(center: _isCustom ? selected : null),
      ),
    ];

    return AnimatedOpacity(
      opacity: dimmed ? 0.45 : 1,
      duration: context.motion(const Duration(milliseconds: 200)),
      child: LayoutBuilder(
        builder: (context, box) {
          // 一行放得下就一行；放不下时均分成若干行（手机上 4 + 4），避免 6 + 2 的残行
          final fit = ((box.maxWidth + _gap) / (_Swatch.outer + _gap)).floor().clamp(1, swatches.length);
          final rows = (swatches.length / fit).ceil();
          final perRow = (swatches.length / rows).ceil();
          return Column(
            children: [
              for (var r = 0; r < rows; r++)
                Padding(
                  padding: EdgeInsets.only(top: r == 0 ? 0 : 12),
                  child: Row(
                    mainAxisAlignment: rows == 1 ? MainAxisAlignment.start : MainAxisAlignment.spaceBetween,
                    children: [
                      for (final (i, s) in swatches.skip(r * perRow).take(perRow).indexed) ...[
                        if (rows == 1 && i > 0) const SizedBox(width: _gap),
                        s,
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 色块外框：选中时绘制外圈描边环。
class _Swatch extends StatelessWidget {
  final bool selected;
  final String? tooltip;
  final VoidCallback onTap;
  final Widget child;

  const _Swatch({required this.selected, this.tooltip, required this.onTap, required this.child});

  /// 含选中环在内的外径。
  static const double outer = AccentPicker._size + 8;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget swatch = Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: context.motion(const Duration(milliseconds: 180)),
          width: outer,
          height: outer,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selected ? colorScheme.onSurface : Colors.transparent, width: 2),
          ),
          child: ClipOval(child: child),
        ),
      ),
    );
    if (tooltip != null) swatch = Tooltip(message: tooltip!, child: swatch);
    return MouseRegion(cursor: SystemMouseCursors.click, child: swatch);
  }
}

class _Fill extends StatelessWidget {
  final Color color;

  const _Fill({required this.color});

  @override
  Widget build(BuildContext context) => ColoredBox(color: color, child: const SizedBox.expand());
}

/// 彩虹扫描渐变；选中自定义色时中心叠一个该颜色的小圆点。
class _RainbowFill extends StatelessWidget {
  final Color? center;

  const _RainbowFill({required this.center});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: SweepGradient(
          colors: [
            Color(0xFFFF4D4D),
            Color(0xFFFFC23D),
            Color(0xFF4DE34D),
            Color(0xFF2EE6D6),
            Color(0xFF3D8BFF),
            Color(0xFFA06BFF),
            Color(0xFFFF4D9A),
            Color(0xFFFF4D4D),
          ],
        ),
      ),
      child: Center(
        child: center == null
            ? const Icon(Icons.add_rounded, size: 18, color: Colors.white)
            : Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: center,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
      ),
    );
  }
}
