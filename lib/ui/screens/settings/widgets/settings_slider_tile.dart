import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';

/// 滑杆行（iOS 亮度 / 字号滑杆样式，两端带小图标）。
///
/// 性能：拖动过程中只更新本行的草稿值，并通过 [onPreview] 让所在分组做局部预览；
/// 松手时才调用 [onChanged] 提交——外观设置一提交就会重建整棵树，逐帧提交会卡顿。
///
/// 布局随行宽切换：
/// - 窄（手机）：标题 + 右侧数值，滑杆在下一行；
/// - 宽（桌面，≥ [wideBreakpoint]）：标题在左、滑杆居中、数值在右，单行完成。
class SettingsSliderTile extends StatefulWidget {
  final String title;

  /// 标题下方的灰色说明（可选）。
  final String? subtitle;

  /// 把数值格式化为右侧标签（如 `65%`）。
  final String Function(double value) labelOf;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final IconData? minIcon;
  final IconData? maxIcon;

  /// 拖动中的草稿值（null 表示拖动结束、回到已提交的值）。
  final ValueChanged<double?>? onPreview;

  /// 松手 / 点击后提交。
  final ValueChanged<double> onChanged;

  const SettingsSliderTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.labelOf,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.minIcon,
    this.maxIcon,
    this.onPreview,
    required this.onChanged,
  });

  static const double wideBreakpoint = 460;

  @override
  State<SettingsSliderTile> createState() => _SettingsSliderTileState();
}

class _SettingsSliderTileState extends State<SettingsSliderTile> {
  double? _draft;

  double get _current => (_draft ?? widget.value).clamp(widget.min, widget.max);

  void _onDrag(double value) {
    setState(() => _draft = value);
    widget.onPreview?.call(value);
  }

  void _onEnd(double value) {
    widget.onChanged(value);
    setState(() => _draft = null);
    widget.onPreview?.call(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    final title = Text(widget.title, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600));
    final Widget titleText = widget.subtitle == null
        ? title
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(height: 2),
              Text(widget.subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          );
    final valueText = Text(
      widget.labelOf(_current),
      textAlign: TextAlign.end,
      style: theme.textTheme.bodyMedium?.copyWith(color: muted, fontFeatures: const [FontFeature.tabularFigures()]),
    );
    final slider = context.tokens.hyperMaterial
        ? _HyperSeekBar(
            value: _current,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: _onDrag,
            onChangeEnd: _onEnd,
            // 拖动中的值在 _draft 里：这时构建的闭包可能还停在上一帧
            onDragEnd: () => _onEnd(_current),
          )
        : Row(
      children: [
        if (widget.minIcon != null) Icon(widget.minIcon, size: 16, color: muted),
        Expanded(
          // 分档只用于吸附，不画刻度点（iOS 滑杆观感更干净）
          child: SliderTheme(
            data: SliderTheme.of(
              context,
            ).copyWith(tickMarkShape: SliderTickMarkShape.noTickMark, showValueIndicator: ShowValueIndicator.never),
            child: Slider(
              value: _current,
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              onChanged: _onDrag,
              onChangeEnd: _onEnd,
            ),
          ),
        ),
        if (widget.maxIcon != null) Icon(widget.maxIcon, size: 22, color: muted),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= SettingsSliderTile.wideBreakpoint) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Row(
              children: [
                SizedBox(width: constraints.maxWidth * 0.32, child: titleText),
                Expanded(child: slider),
                const SizedBox(width: 8),
                SizedBox(width: 48, child: valueText),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: titleText),
                  valueText,
                ],
              ),
              slider,
            ],
          ),
        );
      },
    );
  }
}

/// miuix 的进度条：28 高的胶囊，从左侧填充，整条都能拖；按住时手指到哪填到哪，松手才提交。
class _HyperSeekBar extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final VoidCallback onDragEnd;

  const _HyperSeekBar({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onDragEnd,
  });

  double _at(double dx, double width) {
    final t = (dx / width).clamp(0.0, 1.0);
    final steps = divisions;
    final snapped = steps == null ? t : (t * steps).round() / steps;
    return min + (max - min) * snapped;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = max == min ? 0.0 : (value - min) / (max - min);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) =>
                  onChanged(_at(d.localPosition.dx, width)),
              onHorizontalDragUpdate: (d) =>
                  onChanged(_at(d.localPosition.dx, width)),
              onHorizontalDragEnd: (_) => onDragEnd(),
              onHorizontalDragCancel: onDragEnd,
              onTapUp: (d) => onChangeEnd(_at(d.localPosition.dx, width)),
              child: Container(
                height: 28,
                alignment: Alignment.centerLeft,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: FractionallySizedBox(
                  widthFactor: fraction.clamp(0.0, 1.0),
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
