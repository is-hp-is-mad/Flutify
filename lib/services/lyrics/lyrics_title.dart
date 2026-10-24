import '../../core/rust_core.dart';
import '../../src/rust/api/lyrics.dart' as rust;

/// Remove featured-artist credits without erasing mix/live/version labels.
class LyricsTitle {
  LyricsTitle._();

  static final _credit = RegExp(
    r'\s*[\[(（]\s*(?:feat\.\s*|ft\.\s*|(?:feat|ft|featuring)\s+)[^\])）]+[\])）]',
    caseSensitive: false,
  );
  static final _trailingCredit = RegExp(
    r'\s+(?:[-–—]\s*)?(?:feat\.\s*|ft\.\s*|(?:feat|ft|featuring)\s+)[^\[\]()（）]+$',
    caseSensitive: false,
  );

  static String search(String title) {
    if (RustCore.ready) {
      return rust.cleanLyricsSearchTitle(title: title);
    }
    return title
        .replaceAll(_credit, '')
        .replaceFirst(_trailingCredit, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
