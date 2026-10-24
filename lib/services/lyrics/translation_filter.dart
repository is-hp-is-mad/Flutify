import '../../core/rust_core.dart';
import '../../models/lyrics.dart';
import '../../src/rust/api/lyrics.dart' as rust;
import 'lrclib_candidate.dart';
import 'lyric_script.dart';
import 'translation_markers.dart';

/// 识别 LRCLIB 里的「翻译版 / 罗马音」歌词：这些都不是原唱歌词，一律不用。
/// 「双语对照版」（同一时间点原文 + 译文）不再排除——它能拆成原文 + 译文，
/// 见 `translation_merge.dart`；这里只看拆不出对照结构的混排与标记。
///
/// 依据（满足任一即排除）：
/// 1. 曲名 / 歌手 / 专辑带翻译标记（曲名与当前曲目完全一致时不看，避免误杀 "Lost in Translation"）；
/// 2. 歌词开头 600 字内带翻译标记（常见于「中文翻译：xxx」署名行）；
/// 3. 整首有两种文字大类各占 40% 以上且拆不出逐句对照（整体混排，译文与原文时间轴对不上）。
class TranslationFilter {
  TranslationFilter._();

  static bool hasMarker(String text) => TranslationMarkers.hasMarker(text);

  /// 返回 true 表示这份歌词不要。[title] 为当前曲目名。
  static bool isRejected(LrclibCandidate c, String title) {
    final nameMatch =
        c.trackName.trim().toLowerCase() == title.trim().toLowerCase();
    if (!nameMatch &&
        hasMarker('${c.trackName} ${c.artistName} ${c.albumName}'))
      return true;
    // 双语对照可拆分：原文照常、译文随行展示，不是「翻译版」
    if (c.mergedLines != null) return false;
    final head = c.synced.length > 600 ? c.synced.substring(0, 600) : c.synced;
    if (hasMarker(head)) return true;
    return isMixed(c.lines);
  }

  /// 第 3 条：整首双语混排（不是逐句对照，拆不出译文才走到这）。
  static bool isMixed(List<LyricLine> lines) {
    if (RustCore.ready) {
      return rust.isMixedScriptLines(
        lines: [for (final l in lines) l.words],
      );
    }
    var n = 0, cjk = 0, lat = 0, cyr = 0;
    for (final l in lines) {
      if (l.words.trim().isEmpty) continue;
      n++;
      final fam = lineFamily(l.words);
      if (fam == 0) {
        cjk++;
      } else if (fam == 1) {
        lat++;
      } else if (fam == 2) {
        cyr++;
      }
    }
    if (n < 4) return false;
    final big = [cjk, lat, cyr].where((k) => k * 5 >= n * 2).length;
    return big >= 2;
  }
}
