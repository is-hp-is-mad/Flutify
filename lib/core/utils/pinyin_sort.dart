import 'package:pinyin/pinyin.dart';

/// 中文按拼音排序的比较器（音乐库「按字母顺序」等处使用）。
///
/// 汉字取无声调拼音后与数字 / 字母 / 符号一起按字典序比较，
/// 拼音相同（同音字）或完全相同时回退到原串小写比较，保证排序稳定。
int compareByPinyin(String a, String b) {
  final ka = _sortKey(a);
  final kb = _sortKey(b);
  final cmp = ka.compareTo(kb);
  return cmp != 0 ? cmp : a.toLowerCase().compareTo(b.toLowerCase());
}

/// 排序键：汉字 → 无声调拼音；其余字符原样保留（末尾统一小写）。
///
/// 逐字转换（不用词组表）：排序只需稳定、可预期，多音字按常用音即可。
///
/// 结果按原串缓存：一次排序要比较 O(n log n) 次，音乐库的排序又在 build 里，
/// 不缓存的话每次重建都要把所有标题逐字重新转一遍拼音。
String _sortKey(String s) {
  if (s.isEmpty) return s;
  final cached = _sortKeys[s];
  if (cached != null) return cached;
  if (_sortKeys.length >= _sortKeyLimit) _sortKeys.clear();
  return _sortKeys[s] = _buildSortKey(s);
}

final Map<String, String> _sortKeys = {};
const int _sortKeyLimit = 8192;

String _buildSortKey(String s) {
  final sb = StringBuffer();
  for (final rune in s.runes) {
    final char = String.fromCharCode(rune);
    if (ChineseHelper.isChinese(char)) {
      final pinyin = PinyinHelper.convertToPinyinArray(char, PinyinFormat.WITHOUT_TONE);
      sb.write(pinyin.isEmpty ? char : pinyin.first);
    } else {
      sb.write(char);
    }
  }
  return sb.toString().toLowerCase();
}

/// 便捷方法：按拼音排序后返回新列表（不改动原列表）。
List<T> sortByPinyin<T>(List<T> items, String Function(T) titleOf) {
  final sorted = List<T>.of(items)
    ..sort((a, b) => compareByPinyin(titleOf(a), titleOf(b)));
  return sorted;
}
