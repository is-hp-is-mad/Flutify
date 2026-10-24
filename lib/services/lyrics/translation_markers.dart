import '../../core/rust_core.dart';
import '../../src/rust/api/lyrics.dart' as rust;

/// 翻译版 / 罗马音 / 对照歌词的标记词：出现在曲名 / 歌手 / 专辑或歌词署名行里的特征字符串。
/// 供「排除翻译版」（translation_filter.dart）与「拆分双语对照」（translation_merge.dart）共用。
class TranslationMarkers {
  TranslationMarkers._();

  static const List<String> words = [
    'translation',
    'translated',
    'romanization',
    'romanized',
    'romanised',
    'romaji', //
    'pronunciation', 'phonetic', 'pinyin',
    '翻譯',
    '翻译',
    '中譯',
    '中译',
    '羅馬音',
    '罗马音',
    '音譯',
    '音译',
    '空耳',
    '拼音',
    '注音',
    '對照',
    '对照',
  ];

  static bool hasMarker(String text) {
    if (text.isEmpty) return false;
    if (RustCore.ready) {
      return rust.hasTranslationMarker(text: text);
    }
    final low = text.toLowerCase();
    return words.any(low.contains);
  }

  /// 歌词正文里的翻译署名 / 制作署名行：标记词后紧跟冒号或 by（「中文翻译：xxx」「歌词翻译 by xxx」
  /// 「译：xxx」「Translated by xxx」「Translation: xxx」「by: xxx」）。
  ///
  /// 只认署名格式，不看是否含标记词：歌词本身可能就唱到 "lost in translation"、「对照」「拼音」，
  /// 那些是正文，不能当署名剔掉。
  static bool isCreditLine(String text) {
    if (RustCore.ready) {
      return rust.isTranslationCreditLine(text: text);
    }
    final t = text.trim();
    if (t.isEmpty) return false;
    return _zhCredit.hasMatch(t) ||
        _enCredit.hasMatch(t) ||
        _byCredit.hasMatch(t);
  }

  /// 「（中文）翻译：」「歌词翻譯 by」「译：」「罗马音：」……，可带前导括号。
  static final RegExp _zhCredit = RegExp(
    r'^[\(（\[【]?\s*(?:中文|中|英文|日文|韩文|韓文|歌词|歌詞)?\s*'
    r'(?:翻譯|翻译|譯文|译文|中譯|中译|音譯|音译|羅馬音|罗马音|拼音|注音|對照|对照|空耳|譯|译)\s*'
    r'(?:[:：]|by\b)',
    caseSensitive: false,
  );

  /// 「Translation: xxx」「Translated by xxx」「Lyrics translation by xxx」「Romaji: xxx」。
  static final RegExp _enCredit = RegExp(
    r'^[\(\[]?\s*(?:lyrics?\s+)?(?:english\s+|chinese\s+)?'
    r'(?:translation|translated|romanization|romanized|romanised|romaji|pinyin)\s*(?:[:：]|by\b)',
    caseSensitive: false,
  );

  /// 「by: xxx」「by：xxx」（网易云 / LRC 惯用的署名行）。
  static final RegExp _byCredit = RegExp(
    r'^[\(\[]?\s*by\s*[:：]',
    caseSensitive: false,
  );
}
