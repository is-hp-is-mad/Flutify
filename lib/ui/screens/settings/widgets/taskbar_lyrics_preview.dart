import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../../l10n/l10n.dart';

/// 任务栏歌词的实时预览：一段 Windows 11 任务栏（天气小组件 + 歌词 + 居中图标），
/// 示例歌词每隔几秒上滚一句，与真实任务栏的切句动画一致；颜色 / 不透明度改动即时反映。
///
/// [lightTaskbar] 决定模拟浅色还是深色任务栏（取应用主题，自动配色也按它取黑 / 白）。
class TaskbarLyricsPreview extends StatefulWidget {
  final Color color;
  final double opacity;
  final bool lightTaskbar;

  /// 字号倍率（1.0 = 默认），与原生任务栏歌词同步缩放。
  final double fontScale;

  const TaskbarLyricsPreview({
    super.key,
    required this.color,
    required this.opacity,
    required this.lightTaskbar,
    this.fontScale = 1.0,
  });

  @override
  State<TaskbarLyricsPreview> createState() => _TaskbarLyricsPreviewState();
}

class _TaskbarLyricsPreviewState extends State<TaskbarLyricsPreview> {
  static const Duration _interval = Duration(milliseconds: 2600);

  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) => setState(() => _index++));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final lines = [l10n.taskbarLyricsPreviewLine1, l10n.taskbarLyricsPreviewLine2, l10n.taskbarLyricsPreviewLine3];
    final current = lines[_index % lines.length];
    final next = lines[(_index + 1) % lines.length];
    final light = widget.lightTaskbar;
    final surface = light ? const Color(0xFFEEEEF0) : const Color(0xFF1F1F22);
    final chrome = light ? Colors.black : Colors.white;
    final ink = widget.color.withValues(alpha: widget.opacity);

    return ClipRRect(
      borderRadius: BorderRadius.circular(context.tokens.corner(16)),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: surface,
          border: Border(top: BorderSide(color: chrome.withValues(alpha: 0.08))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            // 天气小组件
            Icon(Icons.wb_cloudy_rounded, size: 20, color: chrome.withValues(alpha: 0.75)),
            const SizedBox(width: 6),
            Text(
              '23°',
              style: TextStyle(color: chrome.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 16),
            // 歌词：当前句（大 / 亮）+ 下一句（小 / 暗），整体上滚切换
            Expanded(
              child: AnimatedSwitcher(
                duration: context.motion(const Duration(milliseconds: 300)),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                transitionBuilder: (child, animation) {
                  final incoming = child.key == ValueKey(_index);
                  final offset = Tween<Offset>(
                    begin: incoming ? const Offset(0, 0.5) : const Offset(0, -0.5),
                    end: Offset.zero,
                  ).animate(animation);
                  return ClipRect(
                    child: SlideTransition(
                      position: offset,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                  );
                },
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                child: Column(
                  key: ValueKey(_index),
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: ink, fontSize: 14 * widget.fontScale, fontWeight: FontWeight.w600, height: 1.2),
                    ),
                    Text(
                      next,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ink.withValues(alpha: ink.a * 0.55),
                        fontSize: 10.5 * widget.fontScale,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            // 居中的任务栏图标（示意）
            for (var i = 0; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: chrome.withValues(alpha: i == 1 ? 0.22 : 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
