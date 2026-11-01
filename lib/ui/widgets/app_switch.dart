import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show HySwitch, HyperTheme;
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3ESwitch;

import '../../core/theme/flutify_tokens.dart';

/// 开关：MD3E 时是 [M3ESwitch]，柔光玻璃时是 miuix 的滑动开关（颜色跟随强调色）。
class AppSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const AppSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    if (!tokens.hyperMaterial) {
      return M3ESwitch(value: value, onChanged: onChanged);
    }
    final changed = onChanged;
    return HyperTheme(
      primary: tokens.accent,
      child: IgnorePointer(
        ignoring: changed == null,
        child: Opacity(
          opacity: changed == null ? 0.4 : 1,
          child: HySwitch(value: value, onChanged: changed ?? (_) {}),
        ),
      ),
    );
  }
}
