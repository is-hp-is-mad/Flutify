import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/material.dart';

/// 统一的空状态占位：圆形图标底 + 标题 + 说明 + 可选操作按钮。
///
/// 任何"本该有内容但没有"的区域都用它填充，避免出现空白或布局塌陷。
/// [onDark] 用于歌词页、全屏播放器等深色沉浸式背景（强制白色系文字）。
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;
  final bool onDark;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final primary = onDark ? Colors.white : colorScheme.onSurface;
    final secondary = onDark ? Colors.white70 : colorScheme.onSurfaceVariant;
    final badgeSize = compact ? 48.0 : 72.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32, vertical: compact ? 20 : 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: badgeSize,
            height: badgeSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: onDark ? Colors.white.withValues(alpha: 0.12) : colorScheme.surfaceContainerHigh,
            ),
            child: Icon(icon, size: badgeSize * 0.46, color: secondary),
          ),
          SizedBox(height: compact ? 10 : 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: primary,
              fontWeight: FontWeight.w800,
              fontSize: compact ? 15 : 18,
              letterSpacing: -0.2,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(color: secondary, fontSize: compact ? 12.5 : 14, height: 1.35),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            SizedBox(height: compact ? 12 : 18),
            M3EButton.outlined(
              decoration: onDark
                  ? const M3EButtonDecoration(
                      foregroundColor: WidgetStatePropertyAll(Colors.white),
                      side: WidgetStatePropertyAll(
                        BorderSide(color: Colors.white38),
                      ),
                    )
                  : null,
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
