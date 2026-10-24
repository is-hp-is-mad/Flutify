import 'package:flutter/material.dart';

import '../../widgets/cover_image.dart';
import 'library_sidebar_entry.dart';
import '../../../core/theme/flutify_tokens.dart';

/// 音乐库栏中的一行。
///
/// - 展开：48px 封面 + 标题 / 副标题，正在播放的条目标题变为品牌绿并在右侧显示喇叭；
/// - 收起（[compact]）：只显示 48px 封面，标题放进 Tooltip；
/// - 悬停时整行底色提亮，圆角 8。
class LibrarySidebarItem extends StatefulWidget {
  final LibrarySidebarEntry entry;
  final bool playing;
  final bool compact;

  const LibrarySidebarItem({super.key, required this.entry, required this.playing, this.compact = false});

  @override
  State<LibrarySidebarItem> createState() => _LibrarySidebarItemState();
}

class _LibrarySidebarItemState extends State<LibrarySidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final entry = widget.entry;

    final cover = _EntryCover(entry: entry);
    final Widget content;
    if (widget.compact) {
      content = Tooltip(
        message: entry.title,
        waitDuration: const Duration(milliseconds: 400),
        preferBelow: false,
        child: Padding(padding: const EdgeInsets.all(6), child: cover),
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            cover,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: widget.playing ? colorScheme.primary : colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (entry.pinned) ...[
                        Icon(Icons.push_pin_rounded, size: 13, color: colorScheme.primary),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          entry.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (widget.playing) ...[
              const SizedBox(width: 8),
              Icon(Icons.volume_up_rounded, size: 18, color: colorScheme.primary),
              const SizedBox(width: 6),
            ],
          ],
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: _hover ? colorScheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          mouseCursor: SystemMouseCursors.click,
          onTap: () => entry.open(context),
          child: content,
        ),
      ),
    );
  }
}

/// 48px 封面：艺人为圆形；「已点赞的歌曲」使用品牌渐变 + 爱心。
class _EntryCover extends StatelessWidget {
  final LibrarySidebarEntry entry;

  const _EntryCover({required this.entry});

  static const double size = 48;

  @override
  Widget build(BuildContext context) {
    if (entry.isLikedSongs) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          gradient: kLikedSongsGradient,
        ),
        child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 20),
      );
    }
    return CoverImage(
      url: entry.imageUrl,
      size: size,
      circular: entry.circular,
      borderRadius: BorderRadius.circular(6),
      placeholderIcon: switch (entry.kind) {
        LibraryKind.artist => Icons.person_rounded,
        LibraryKind.album => Icons.album_rounded,
        LibraryKind.playlist => Icons.queue_music_rounded,
      },
    );
  }
}
