/// 歌词来源，可在设置里拖拽调整优先级（越靠前越优先）。
///
/// 四个来源都可以给出原文（可带译文），按先后顺序查找；中文译词按同样的顺序补全，
/// Spotify 自带的完整译文始终保留。
enum LyricsSource {
  spotify,
  qqMusic,
  netease,
  lrclib;

  /// 与排序功能出现之前的固定来源链一致：原文 Spotify → LRCLIB，译文 QQ → 网易云 → LRCLIB。
  static const List<LyricsSource> defaultOrder = [
    spotify,
    qqMusic,
    netease,
    lrclib,
  ];

  /// 解析持久化的顺序：忽略未知与重复项，缺失的来源按默认顺序补在末尾。
  static List<LyricsSource> parseOrder(Object? raw) {
    final seen = <LyricsSource>{};
    if (raw is List) {
      for (final item in raw) {
        for (final source in values) {
          if (source.name == item) seen.add(source);
        }
      }
    }
    for (final source in defaultOrder) {
      seen.add(source);
    }
    return List.unmodifiable(seen);
  }
}
