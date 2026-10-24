/// 文种识别：按字符所属文字（汉字 / 假名 / 谚文 / 拉丁 …）判断一段文本是哪种语言的歌词。
///
/// 只看字形不看词汇，足以区分「中 / 日 / 韩 / 拉丁字母语种 / 西里尔 …」这一粒度，
/// 用于在 LRCLIB 的多份候选歌词里挑出原唱语言的那一份（见 `lrclib_selector.dart`）。
library;

import '../../core/rust_core.dart';
import '../../src/rust/api/lyrics.dart' as rust;

/// 文字系统（按 UTF-16 码元归类，CJK 扩展 B 以外的字都在 BMP 内）。
enum Script { han, kana, hangul, cyrillic, greek, thai, arabic, hebrew, latin, other }

/// 歌词语言（文种粒度）：拉丁字母语种（英 / 法 / 西 …）统一归为 [latin]。
enum LyricLang { zh, ja, ko, latin, cyrillic, greek, thai, arabic, hebrew, unknown }

/// 字符所属文字；标点、数字、空白返回 null。
Script? scriptOf(int c) {
  if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) return Script.latin;
  if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0xF900 && c <= 0xFAFF)) {
    return Script.han;
  }
  if ((c >= 0x3040 && c <= 0x30FF) || (c >= 0x31F0 && c <= 0x31FF) || (c >= 0xFF66 && c <= 0xFF9F)) {
    return Script.kana;
  }
  if ((c >= 0xAC00 && c <= 0xD7AF) || (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F)) {
    return Script.hangul;
  }
  if (c >= 0x0400 && c <= 0x052F) return Script.cyrillic;
  if ((c >= 0x0370 && c <= 0x03FF) || (c >= 0x1F00 && c <= 0x1FFF)) return Script.greek;
  if (c >= 0x0E00 && c <= 0x0E7F) return Script.thai;
  if ((c >= 0x0600 && c <= 0x06FF) ||
      (c >= 0x0750 && c <= 0x077F) ||
      (c >= 0xFB50 && c <= 0xFDFF) ||
      (c >= 0xFE70 && c <= 0xFEFF)) {
    return Script.arabic;
  }
  if (c >= 0x0590 && c <= 0x05FF) return Script.hebrew;
  if ((c >= 0x00C0 && c <= 0x024F) || (c >= 0x1E00 && c <= 0x1EFF)) return Script.latin;
  if (_isOtherLetter(c)) return Script.other;
  return null;
}

/// 上面没覆盖到的字母类字符（天城文、格鲁吉亚文等）。粗略按区段判断，只用于计入总数。
bool _isOtherLetter(int c) =>
    (c >= 0x0530 && c <= 0x058F) || // 亚美尼亚
    (c >= 0x0900 && c <= 0x0DFF) || // 印度诸文字
    (c >= 0x0E80 && c <= 0x0FFF) || // 老挝 / 藏文
    (c >= 0x10A0 && c <= 0x10FF) || // 格鲁吉亚
    (c >= 0x1780 && c <= 0x17FF); // 高棉

/// 一段文本里各文字的字符数。
class ScriptCounts {
  final List<int> _counts = List.filled(Script.values.length, 0);

  ScriptCounts.of(String text) {
    for (final c in text.codeUnits) {
      final s = scriptOf(c);
      if (s != null) _counts[s.index]++;
    }
  }

  int operator [](Script s) => _counts[s.index];

  int get total => _counts.fold(0, (a, b) => a + b);
}

/// 按「出现过哪种文字」判断语言，用于曲名 / 歌手这种短文本：有假名即日文，有谚文即韩文，有汉字即中文。
LyricLang detectLang(String text) {
  if (RustCore.ready) {
    try {
      final idx = rust.detectLyricLang(text: text);
      if (idx >= 0 && idx < LyricLang.values.length) {
        return LyricLang.values[idx];
      }
    } catch (_) {}
  }
  final c = ScriptCounts.of(text);
  if (c[Script.kana] > 0) return LyricLang.ja;
  if (c[Script.hangul] > 0) return LyricLang.ko;
  if (c[Script.han] > 0) return LyricLang.zh;
  if (c[Script.cyrillic] > 0) return LyricLang.cyrillic;
  if (c[Script.greek] > 0) return LyricLang.greek;
  if (c[Script.thai] > 0) return LyricLang.thai;
  if (c[Script.arabic] > 0) return LyricLang.arabic;
  if (c[Script.hebrew] > 0) return LyricLang.hebrew;
  if (c[Script.latin] > 0) return LyricLang.latin;
  return LyricLang.unknown;
}

/// 歌词正文的主语言：日文必夹假名、韩文 / 中文歌常混英文，因此按占比阈值判断而不是简单取最多。
LyricLang lyricLang(String text) {
  if (RustCore.ready) {
    try {
      final idx = rust.mainLyricLang(text: text);
      if (idx >= 0 && idx < LyricLang.values.length) {
        return LyricLang.values[idx];
      }
    } catch (_) {}
  }
  final c = ScriptCounts.of(text);
  final total = c.total;
  if (total < 1) return LyricLang.unknown;
  if (c[Script.kana] / total >= 0.05) return LyricLang.ja;
  if (c[Script.hangul] / total >= 0.15) return LyricLang.ko;
  if (c[Script.han] / total >= 0.15) return LyricLang.zh;
  const order = [
    (Script.latin, LyricLang.latin),
    (Script.cyrillic, LyricLang.cyrillic),
    (Script.greek, LyricLang.greek),
    (Script.thai, LyricLang.thai),
    (Script.arabic, LyricLang.arabic),
    (Script.hebrew, LyricLang.hebrew),
  ];
  var best = LyricLang.unknown;
  var bestN = 0;
  for (final (script, lang) in order) {
    if (c[script] > bestN) {
      bestN = c[script];
      best = lang;
    }
  }
  return best;
}

/// 0 ~ 100：歌词文字与目标语言的吻合度。同属 CJK 的给部分分，避免同分时乱选。
/// 目标语言未知时一律 50。
double langScore(LyricLang target, String text) {
  if (RustCore.ready) {
    try {
      return rust.scoreLyricLang(target: target.index, text: text);
    } catch (_) {}
  }
  final c = ScriptCounts.of(text);
  final total = c.total.toDouble();
  if (total < 1) return 0;
  double r(Script s) => c[s] / total;
  final han = r(Script.han), kana = r(Script.kana), hangul = r(Script.hangul), latin = r(Script.latin);
  final (double exact, double near) = switch (target) {
    LyricLang.zh => (han, kana + hangul),
    LyricLang.ja => (kana + han * 0.6, han * 0.4),
    LyricLang.ko => (hangul, han * 0.25),
    LyricLang.latin => (latin, r(Script.greek) * 0.2),
    LyricLang.cyrillic => (r(Script.cyrillic), 0),
    LyricLang.greek => (r(Script.greek), latin * 0.2),
    LyricLang.thai => (r(Script.thai), 0),
    LyricLang.arabic => (r(Script.arabic), 0),
    LyricLang.hebrew => (r(Script.hebrew), 0),
    LyricLang.unknown => (-1, 0),
  };
  if (exact < 0) return 50;
  final far = (1 - exact - near).clamp(0.0, 1.0);
  final m = exact + near * 0.5 - far * 0.5;
  return (m * 100).clamp(0.0, 100.0);
}

/// 一行歌词的主导文字大类：0 = CJK（汉字 / 假名 / 谚文），1 = 拉丁，2 = 西里尔，3 = 希腊，
/// 4 = 泰文，5 = 阿拉伯，6 = 希伯来，7 = 其它；没有字母时为 -1。用于识别中外文对照的翻译版。
int lineFamily(String text) {
  if (RustCore.ready) {
    try {
      return rust.lyricLineFamily(text: text);
    } catch (_) {}
  }
  final fam = List.filled(8, 0);
  var best = -1, bestN = 0;
  for (final c in text.codeUnits) {
    final s = scriptOf(c);
    if (s == null) continue;
    final f = switch (s) {
      Script.han || Script.kana || Script.hangul => 0,
      Script.latin => 1,
      Script.cyrillic => 2,
      Script.greek => 3,
      Script.thai => 4,
      Script.arabic => 5,
      Script.hebrew => 6,
      Script.other => 7,
    };
    fam[f]++;
    if (fam[f] > bestN) {
      bestN = fam[f];
      best = f;
    }
  }
  return best;
}
