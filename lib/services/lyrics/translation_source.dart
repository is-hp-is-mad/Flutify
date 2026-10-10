import '../../models/lyrics.dart';
import '../../models/lyrics_query.dart';
import 'lyrics_disk_cache.dart';

/// Lines use the original indices/timestamps, including empty instrumental
/// lines and repeated timestamps. Missing translations have empty words;
/// implementations return null for a miss and mark transient failures separately.
class TranslationSourceLookup {
  final List<LyricLine>? lines;
  final bool networkError;

  const TranslationSourceLookup(this.lines, {this.networkError = false});
}

abstract interface class TranslationSource {
  LyricsProvider get provider;
  LyricsDiskCache? get cache;
  Future<TranslationSourceLookup> find(
    LyricsQuery query,
    List<LyricLine> originals,
  );
  Future<void> forget(LyricsQuery query);
}
