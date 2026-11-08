import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/md3e_typography.dart';

/// 发布说明（GitHub Release 正文）的 Markdown 渲染。
///
/// 只实现发布说明里实际用到的子集，不引入第三方 Markdown 依赖：
/// - 块：`#`~`######` 标题、`-` / `*` / `+` 列表（按缩进分级）、`>` 引用、空行分段；
/// - 行内：`**粗体**`、`` `代码` ``、`[文字](链接)`、裸 http(s) 链接。
/// 其余语法原样显示。与 GitHub 一样，段落内的换行保留为换行。链接只打开 http(s)。
class ReleaseNotesView extends StatefulWidget {
  const ReleaseNotesView(this.markdown, {super.key});

  final String markdown;

  @override
  State<ReleaseNotesView> createState() => _ReleaseNotesViewState();
}

class _ReleaseNotesViewState extends State<ReleaseNotesView> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final blocks = parseReleaseNotes(widget.markdown);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (i > 0) {
        children.add(SizedBox(height: _gapBefore(block, blocks[i - 1])));
      }
      children.add(_buildBlock(context, block));
    }
    return SelectionArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  double _gapBefore(ReleaseNotesBlock block, ReleaseNotesBlock previous) {
    if (block.kind == ReleaseNotesBlockKind.heading) return 16;
    if (block.kind == ReleaseNotesBlockKind.bullet &&
        previous.kind == ReleaseNotesBlockKind.bullet) {
      return 4;
    }
    return previous.kind == ReleaseNotesBlockKind.heading ? 6 : 10;
  }

  Widget _buildBlock(BuildContext context, ReleaseNotesBlock block) {
    final theme = Theme.of(context);
    final base = DefaultTextStyle.of(context).style;
    switch (block.kind) {
      case ReleaseNotesBlockKind.heading:
        final style = (block.level <= 2
                ? theme.textTheme.titleMedium
                : theme.textTheme.titleSmall)
            ?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            );
        return Text.rich(_inline(context, block.text, style ?? base));
      case ReleaseNotesBlockKind.bullet:
        return Padding(
          padding: EdgeInsets.only(left: 16.0 * block.level),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 16,
                child: Text(block.level == 0 ? '•' : '◦', style: base),
              ),
              Expanded(child: Text.rich(_inline(context, block.text, base))),
            ],
          ),
        );
      case ReleaseNotesBlockKind.quote:
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.colorScheme.outlineVariant, width: 3),
            ),
          ),
          child: Text.rich(_inline(context, block.text, base)),
        );
      case ReleaseNotesBlockKind.paragraph:
        return Text.rich(_inline(context, block.text, base));
    }
  }

  static final RegExp _inlinePattern = RegExp(
    r'\*\*(.+?)\*\*'
    r'|`([^`]+)`'
    r'|\[([^\]]+)\]\((https?://[^\s)]+)\)'
    r'|(https?://[^\s<>()]+[^\s<>().,;:!?，。；：！？）])',
  );

  TextSpan _inline(BuildContext context, String text, TextStyle style) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _inlinePattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      if (m[1] != null) {
        spans.add(
          TextSpan(
            text: m[1],
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      } else if (m[2] != null) {
        spans.add(
          TextSpan(
            text: m[2],
            style: TextStyle(
              // 与 embed_code_panel 一致的等宽字体；中文仍回退到 App 字族 MiSans
              fontFamily: 'Consolas',
              fontFamilyFallback: const [
                'Menlo',
                'Roboto Mono',
                'monospace',
                MD3ETypography.fontFamily,
              ],
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        );
      } else {
        final label = m[3] ?? m[5]!;
        final url = m[4] ?? m[5]!;
        final recognizer = TapGestureRecognizer()..onTap = () => _open(url);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: label,
            style: TextStyle(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary,
            ),
            recognizer: recognizer,
            mouseCursor: SystemMouseCursors.click,
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: style, children: spans);
  }

  static Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

enum ReleaseNotesBlockKind { heading, bullet, quote, paragraph }

/// 解析后的一个块。[level]：标题为 1~6，列表为缩进层级（从 0 起），其余为 0。
class ReleaseNotesBlock {
  const ReleaseNotesBlock(this.kind, this.text, {this.level = 0});

  final ReleaseNotesBlockKind kind;
  final String text;
  final int level;

  @override
  bool operator ==(Object other) =>
      other is ReleaseNotesBlock &&
      other.kind == kind &&
      other.text == text &&
      other.level == level;

  @override
  int get hashCode => Object.hash(kind, text, level);

  @override
  String toString() => '$kind($level, $text)';
}

/// 把发布说明拆成块；行内语法留给渲染时处理。
@visibleForTesting
List<ReleaseNotesBlock> parseReleaseNotes(String markdown) {
  final blocks = <ReleaseNotesBlock>[];
  final paragraph = <String>[];
  final quote = <String>[];

  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(
        ReleaseNotesBlock(ReleaseNotesBlockKind.paragraph, paragraph.join('\n')),
      );
      paragraph.clear();
    }
    if (quote.isNotEmpty) {
      blocks.add(ReleaseNotesBlock(ReleaseNotesBlockKind.quote, quote.join('\n')));
      quote.clear();
    }
  }

  final heading = RegExp(r'^(#{1,6})\s+(.*?)\s*#*\s*$');
  final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  for (final raw in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    final h = heading.firstMatch(line);
    if (h != null) {
      flush();
      blocks.add(
        ReleaseNotesBlock(
          ReleaseNotesBlockKind.heading,
          h[2]!,
          level: h[1]!.length,
        ),
      );
      continue;
    }
    final b = bullet.firstMatch(line);
    if (b != null) {
      flush();
      final indent = b[1]!.replaceAll('\t', '    ').length;
      blocks.add(
        ReleaseNotesBlock(
          ReleaseNotesBlockKind.bullet,
          b[2]!,
          level: (indent / 2).floor().clamp(0, 3),
        ),
      );
      continue;
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('>')) {
      if (paragraph.isNotEmpty) flush();
      quote.add(trimmed.substring(1).trimLeft());
      continue;
    }
    if (quote.isNotEmpty) flush();
    // 列表项的续行（缩进的普通行）并入上一项
    if (paragraph.isEmpty &&
        raw.startsWith(' ') &&
        blocks.isNotEmpty &&
        blocks.last.kind == ReleaseNotesBlockKind.bullet) {
      final prev = blocks.removeLast();
      blocks.add(
        ReleaseNotesBlock(
          prev.kind,
          '${prev.text}\n$trimmed',
          level: prev.level,
        ),
      );
      continue;
    }
    paragraph.add(trimmed);
  }
  flush();
  return blocks;
}
