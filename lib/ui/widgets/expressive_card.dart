import 'package:flutter/material.dart';
import 'package:hyper_glass/hyper_ui.dart' show Pressable;

import '../../core/theme/flutify_tokens.dart';
import '../../core/theme/md3e_shapes.dart';
import '../shell/shell_breakpoints.dart';
import 'cover_image.dart';
import 'hover_builder.dart';
import 'text_metrics.dart';

/// 专辑 / 歌单 / 艺人卡片（横向卡架与网格共用）。
///
/// 桌面端交互（Spotify 新版桌面端 + MD3E 形变 / 小米 HyperOS 物理弹性触感）：
/// - 悬停：卡片底色提亮，播放键从封面右下角上浮淡入；
/// - 按下卡片 / 播放键：小米 HyperOS Folme 物理弹性回弹；
/// 触屏没有悬停，播放键常驻显示。
class ExpressiveCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String imageUrl;
  final bool isCircular;
  final VoidCallback onTap;
  final VoidCallback? onPlayTap;
  final double width;

  /// 卡片外边距：横向卡架默认右侧留 14，网格中由网格间距负责（传 zero）。
  final EdgeInsetsGeometry margin;

  const ExpressiveCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.imageUrl,
    this.isCircular = false,
    required this.onTap,
    this.onPlayTap,
    this.width = 148,
    this.margin = const EdgeInsets.only(right: 14.0),
  });

  /// 内边距与封面下方间距（与 [build] 中的布局一致）。
  static const double _padding = 6;
  static const double _coverGap = 10;
  static const double _subtitleGap = 2;

  /// 宽为 [width] 的卡片完整显示所需高度（标题 1 行 + 副标题 2 行，按当前字号实测行高）。
  ///
  /// 卡架 / 网格据此给定高度，字号放大时不会溢出。
  static double heightFor(BuildContext context, double width) {
    final textTheme = Theme.of(context).textTheme;
    final title = TextMetrics.lineHeight(context, textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600));
    final subtitle = TextMetrics.lineHeight(context, textTheme.bodySmall);
    // 末尾 4px 余量：吸收不同字体的基线取整误差
    return _padding * 2 + (width - _padding * 2) + _coverGap + title + _subtitleGap + subtitle * 2 + 4;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hoverCapable = ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
    final tokens = context.tokens;
    final cardRadius = tokens.radius(MD3EShapes.radiusLarge);

    return Container(
      width: width,
      margin: margin,
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) {
          final content = Padding(
            padding: const EdgeInsets.all(_padding),
            child: Column(
              crossAxisAlignment: isCircular ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    AspectRatio(
                      aspectRatio: 1.0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                          shape: isCircular ? BoxShape.circle : BoxShape.rectangle,
                          borderRadius: isCircular ? null : tokens.radius(MD3EShapes.radiusMedium),
                          boxShadow: tokens.hyperMaterial
                              ? null
                              : [
                                  BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 10, offset: const Offset(0, 4)),
                                ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: CoverImage(
                          url: imageUrl,
                          size: width - 12,
                          placeholderIcon: isCircular ? Icons.person_rounded : Icons.music_note_rounded,
                        ),
                      ),
                    ),
                    if (onPlayTap != null)
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: _HoverPlayButton(visible: hovered || !hoverCapable, onPressed: onPlayTap!),
                      ),
                  ],
                ),
                const SizedBox(height: _coverGap),
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: isCircular ? TextAlign.center : TextAlign.start,
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: _subtitleGap),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: isCircular ? TextAlign.center : TextAlign.start,
                  ),
                ],
              ],
            ),
          );

          if (tokens.hyperMaterial) {
            return Pressable(
              onTap: onTap,
              child: AnimatedContainer(
                duration: context.motion(const Duration(milliseconds: 200)),
                decoration: BoxDecoration(
                  color: hovered ? colorScheme.surfaceContainerHigh : Colors.transparent,
                  borderRadius: cardRadius,
                ),
                child: content,
              ),
            );
          }

          return Material(
            color: hovered ? colorScheme.surfaceContainerHigh : Colors.transparent,
            borderRadius: cardRadius,
            child: InkWell(
              mouseCursor: SystemMouseCursors.click,
              onTap: onTap,
              borderRadius: cardRadius,
              // 悬停底色由 Material 负责（带动画的 InkWell 悬停色会与之叠加变脏）
              hoverColor: Colors.transparent,
              child: content,
            ),
          );
        },
      ),
    );
  }
}

/// 封面右下角的播放键：出现时上浮 8px + 淡入 + 放大；按下时圆形 → 圆角方形 / Folme 弹性回弹。
class _HoverPlayButton extends StatefulWidget {
  final bool visible;
  final VoidCallback onPressed;

  const _HoverPlayButton({required this.visible, required this.onPressed});

  @override
  State<_HoverPlayButton> createState() => _HoverPlayButtonState();
}

class _HoverPlayButtonState extends State<_HoverPlayButton> {
  static const double _size = 46;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    const curve = Curves.easeOutBack;
    final duration = context.motion(const Duration(milliseconds: 220));
    final tokens = context.tokens;
    final hyper = tokens.hyperMaterial;
    // 柔光玻璃：小一号的白色圆钮，不变形、没有投影
    final size = hyper ? 36.0 : _size;

    final buttonCore = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: context.motion(const Duration(milliseconds: 180)),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: hyper ? const Color(0xe6ffffff) : tokens.accent,
          borderRadius: hyper
              ? BorderRadius.circular(size / 2)
              : BorderRadius.circular(_pressed ? 14 : (tokens.squareCorners ? 12 : _size / 2)),
          boxShadow: hyper
              ? null
              : [
                  BoxShadow(color: Colors.black.withAlpha(110), blurRadius: 10, offset: const Offset(0, 4)),
                ],
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          color: hyper ? Colors.black : tokens.onAccent,
          size: hyper ? 22 : 28,
        ),
      ),
    );

    final interactiveButton = hyper
        ? Pressable(
            onTap: widget.onPressed,
            child: buttonCore,
          )
        : GestureDetector(
            onTapDown: (_) => setState(() => _pressed = true),
            onTapCancel: () => setState(() => _pressed = false),
            onTapUp: (_) => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: buttonCore,
          );

    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedSlide(
        offset: widget.visible ? Offset.zero : const Offset(0, 0.2),
        duration: duration,
        curve: curve,
        child: AnimatedOpacity(
          opacity: widget.visible ? 1 : 0,
          duration: context.motion(const Duration(milliseconds: 160)),
          child: AnimatedScale(
            scale: widget.visible ? (_pressed ? 0.92 : 1) : 0.8,
            duration: duration,
            curve: curve,
            child: interactiveButton,
          ),
        ),
      ),
    );
  }
}
