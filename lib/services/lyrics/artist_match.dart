import '../../core/rust_core.dart';
import '../../src/rust/api/lyrics.dart' as rust;
import 'lyric_script.dart';
import 'zh_script.dart';

/// 候选歌词的歌手与当前曲目是否一致。
enum ArtistMatch {
  /// 至少一位艺人对得上。
  match,

  /// 两边是同一种文字却没有一位对得上：多半是同名的另一首歌，不能用。
  mismatch,

  /// 无法比较（一方为空，或文字不同——Spotify 会把歌手名本地化，如「周杰伦」与 "Jay Chou"）。
  unknown,
}

/// 歌手比对：LRCLIB 上同名歌曲很多（"Rule The World" 就有 Take That、The Wanted、Kamelot……），
/// 只看曲名和时长会配上别人的歌。
///
/// 规则：
/// - 两边都拆成多位艺人（`,` `&` `/` `feat.` `ft.` `x` `and` `、` 等分隔），每位艺人再拆成词（忽略大小写、标点）；
/// - 任一方的某位艺人的全部词都出现在另一方里，即算对上（"GAMPER & DADONI" 对 "Gamper, Dadoni"、"Tiësto" 对 "Tiësto, Tears For Fears"）；
/// - 中文先统一成简体再比，避免「周杰倫」与「周杰伦」对不上；
/// - 两边文字不同（中文名对英文名）时不做判断。
class ArtistMatcher {
  ArtistMatcher._();

  static final RegExp _separator = RegExp(
    r'\s*(?:,|&|/|;|\+|、|，|\bfeat\.?|\bft\.?|\bwith\b|\bx\b|\band\b|\bvs\.?)\s*',
    caseSensitive: false,
  );
  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  static ArtistMatch compare(String queryArtist, String candidateArtist) {
    if (RustCore.ready) {
      final idx = rust.compareArtists(
        queryArtist: queryArtist,
        candidateArtist: candidateArtist,
      );
      return idx >= 0 && idx < ArtistMatch.values.length
          ? ArtistMatch.values[idx]
          : ArtistMatch.unknown;
    }
    final a = _normalize(queryArtist), b = _normalize(candidateArtist);
    if (a.isEmpty || b.isEmpty) return ArtistMatch.unknown;
    final langA = detectLang(a), langB = detectLang(b);
    if (langA == LyricLang.unknown || langA != langB) return ArtistMatch.unknown;

    final namesA = _names(a), namesB = _names(b);
    final wordsA = {for (final n in namesA) ...n}, wordsB = {for (final n in namesB) ...n};
    bool covered(List<List<String>> names, Set<String> words) => names.any((n) => n.every(words.contains));
    return covered(namesA, wordsB) || covered(namesB, wordsA) ? ArtistMatch.match : ArtistMatch.mismatch;
  }

  static String _normalize(String artist) {
    final text = artist.trim().toLowerCase();
    return ZhScript.countTraditional(text) > 0 ? ZhScript.convert(text, toSimplified: true) : text;
  }

  /// 艺人列表，每位艺人是一组词；空名字丢弃。
  static List<List<String>> _names(String artist) => [
    for (final name in artist.split(_separator))
      if (_words(name) case final words when words.isNotEmpty) words,
  ];

  static List<String> _words(String name) => name.split(_nonWord).where((w) => w.isNotEmpty).toList();
}
