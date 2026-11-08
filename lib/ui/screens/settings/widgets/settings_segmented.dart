import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show HySegmented;

import '../../../../core/theme/flutify_tokens.dart';

/// iOS 风格分段控件：凹槽轨道 + 一块滑动的浮起滑块。
///
/// 选项等宽；切换时滑块平滑滑到目标位置（减弱动效时直接跳到位）。
class SettingsSegmented<T> extends StatelessWidget {
  final List<T> values;
  final String Function(T value) labelOf;
  final T selected;
  final ValueChanged<T> onChanged;

  const SettingsSegmented({
    super.key,
    required this.values,
    required this.labelOf,
    required this.selected,
    required this.onChanged,
  });

  static const double _height = 36;
  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tokens = context.tokens;
    final isDark = theme.brightness == Brightness.dark;
    final index = values.indexOf(selected).clamp(0, values.length - 1);
    if (tokens.hyperMaterial) {
      return HySegmented(
        items: [for (final value in values) labelOf(value)],
        index: index,
        onChanged: (i) => onChanged(values[i]),
      );
    }
    // 滑块圆角比轨道小一圈 inset，两者保持同心
    final trackRadius = tokens.corner(10);
    final thumbRadius = (trackRadius - _inset).clamp(2.0, 100.0);
    final trackColor = colorScheme.surfaceContainerHighest;
    // 深色下滑块比轨道亮一档（iOS 深色分段控件），浅色下为纯白
    final thumbColor = isDark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.16), trackColor) : Colors.white;

    return Container(
      height: _height,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: BorderRadius.circular(trackRadius),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: context.motion(const Duration(milliseconds: 240)),
            curve: Curves.easeOutCubic,
            alignment: Alignment(values.length == 1 ? 0 : -1 + 2 * index / (values.length - 1), 0),
            child: FractionallySizedBox(
              widthFactor: 1 / values.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: thumbColor,
                  borderRadius: BorderRadius.circular(thumbRadius),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.1), blurRadius: 6, offset: const Offset(0, 2)),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final value in values)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: value == selected,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(value),
                        child: Center(
                          child: Text(
                            labelOf(value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: value == selected ? FontWeight.w600 : FontWeight.w500,
                              color: value == selected ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
                            ),
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
    );
  }
}
