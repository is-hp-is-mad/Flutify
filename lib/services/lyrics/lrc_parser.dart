import '../../core/rust_core.dart';
import '../../models/lyrics.dart';
import '../../src/rust/api/lyrics.dart' as rust;

/// LRC 逐行同步歌词解析：`[mm:ss.xx]歌词`，一行可带多个时间标签（副歌复用）。
///
/// 没有时间标签的行（`[ar:…]` 等元信息、纯文本）忽略；结果按时间升序。
/// 空歌词行保留，表示间奏 / 停顿（与 Spotify 同步歌词里的空行同义）。
class LrcParser {
  LrcParser._();

  static final RegExp _tag = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');

  static List<LyricLine> parse(String lrc) {
    if (lrc.isEmpty) return const [];
    if (RustCore.ready) {
      try {
        return [for (final l in rust.parseLrc(lrc: lrc)) LyricLine(startTimeMs: l.startTimeMs.toInt(), words: l.words)];
      } catch (_) {
        // 回退到下面的 Dart 实现
      }
    }
    return _parseDart(lrc);
  }

  static List<LyricLine> _parseDart(String lrc) {
    final lines = <LyricLine>[];
    for (final raw in lrc.split('\n')) {
      final line = raw.replaceAll('\r', '');
      final tags = _tag.allMatches(line).toList();
      if (tags.isEmpty) continue;
      final text = line.replaceAll(_tag, '').trim();
      for (final t in tags) {
        final ms = int.parse(t.group(1)!) * 60000 + (double.parse(t.group(2)!) * 1000).round();
        lines.add(LyricLine(startTimeMs: ms, words: text));
      }
    }
    // 稳定排序：同一时间点的多行保持原有先后（译文对照行在原文之后）
    final indexed = lines.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.startTimeMs.compareTo(b.$2.startTimeMs);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final (_, line) in indexed) line];
  }
}
