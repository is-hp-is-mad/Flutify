import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/app_preferences.dart';
import '../../models/lyrics.dart';
import '../../models/lyrics_query.dart';
import 'lyrics_language.dart';

class LyricsTranslation {
  final List<String> lines;
  final LyricsProvider provider;

  const LyricsTranslation(this.lines, this.provider);

  /// 空行 / 间奏不需要译文；只要有一句正文缺译，就仍可查询备用源。
  bool isCompleteFor(SpotifyLyrics lyrics) =>
      lines.length == lyrics.lines.length &&
      lyrics.lines.indexed.every(
        (entry) => !_hasWords(entry.$2) || lines[entry.$1].trim().isNotEmpty,
      );

  /// 只接受补齐更多正文行、且不丢失已有译文位置的候选。
  /// 整份替换而不跨来源拼接，保留准确的来源归属和译文风格。
  bool improvesCoverageOf(LyricsTranslation? previous, SpotifyLyrics lyrics) {
    if (lines.length != lyrics.lines.length) return false;
    var added = false;
    for (final (i, line) in lyrics.lines.indexed) {
      if (!_hasWords(line)) continue;
      final next = lines[i].trim().isNotEmpty;
      final before =
          previous?.lines.elementAtOrNull(i)?.trim().isNotEmpty ?? false;
      if (before && !next) return false;
      added |= next && !before;
    }
    return added;
  }

  static bool _hasWords(LyricLine line) =>
      line.words.trim().isNotEmpty && line.words.trim() != '♪';
}

typedef TranslationLookup =
    Future<LyricsTranslation?> Function(
      LyricsQuery query,
      SpotifyLyrics lyrics,
      String target,
    );

/// Select source-provided translations. There is no machine translation here.
class LyricsTranslationController extends ChangeNotifier {
  final TranslationLookup? lookup;
  LyricsTranslationController({this.lookup});

  SpotifyLyrics? _lyrics;
  LyricsQuery? _query;
  String _target = '';
  String _trackKey = '';
  String _settingsKey = '';
  int _revision = 0;
  bool _disposed = false;
  bool _cancelled = false;
  bool _attempted = false;
  bool busy = false;
  bool failed = false;
  LyricsTranslation? _translation;

  List<String>? get lines => _translation?.lines;
  bool get fromLrclib => _translation?.provider == LyricsProvider.lrclib;
  bool get fromNetease => _translation?.provider == LyricsProvider.netease;
  bool get fromQqMusic => _translation?.provider == LyricsProvider.qqMusic;
  bool get available => _lyrics != null && _lyrics!.lines.isNotEmpty;
  bool get unavailable =>
      _attempted && !failed && !busy && _translation == null;

  static LyricsTranslation? official(SpotifyLyrics lyrics, String target) {
    final normalized = LyricsLanguage.normalize(target);
    LyricsTranslation? best;
    final alternatives = [...lyrics.alternatives]
      ..sort((a, b) {
        int rank(LyricsAlternative a) =>
            LyricsLanguage.normalize(a.language) == normalized ? 0 : 1;
        return rank(a).compareTo(rank(b));
      });
    for (final alternative in alternatives) {
      if (alternative.lines.length != lyrics.lines.length ||
          !alternative.lines.any((line) => line.trim().isNotEmpty))
        continue;
      final code = LyricsLanguage.of(
        alternative.language,
        alternative.lines.join('\n'),
      );
      if (!LyricsLanguage.matches(code, normalized)) continue;
      if (listEquals(
        alternative.lines,
        lyrics.lines.map((line) => line.words).toList(),
      ))
        continue;
      final candidate = LyricsTranslation(
        List.unmodifiable(alternative.lines),
        LyricsProvider.spotify,
      );
      if (candidate.improvesCoverageOf(best, lyrics)) best = candidate;
      if (best?.isCompleteFor(lyrics) ?? false) return best;
    }
    final inline = lyrics.lines.map((line) => line.translation).toList();
    final code = LyricsLanguage.of('und', inline.join('\n'));
    if (inline.any((line) => line.trim().isNotEmpty) &&
        LyricsLanguage.matches(code, normalized)) {
      final candidate = LyricsTranslation(
        List.unmodifiable(inline),
        lyrics.translationProvider ?? lyrics.provider,
      );
      if (candidate.improvesCoverageOf(best, lyrics)) best = candidate;
    }
    return best;
  }

  void configure(
    SpotifyLyrics? lyrics,
    AppPreferences prefs,
    String locale, {
    LyricsQuery? query,
  }) {
    if (_disposed) return;
    final code = LyricsLanguage.normalize(locale);
    final target = code == 'zh' ? 'zh-Hans' : code;
    final trackKey = query == null
        ? ''
        : '${query.trackId}|${query.title}|${query.artist}';
    final settingsKey =
        '${prefs.lyricsAutoTranslate}|${prefs.lyricsExcludeInterfaceLanguage}|'
        '${prefs.lyricsExcludedLanguages.join(',')}|${prefs.lyricsFallback}|${prefs.lyricsBilingual}';
    if (identical(lyrics, _lyrics) &&
        target == _target &&
        trackKey == _trackKey &&
        settingsKey == _settingsKey)
      return;
    final changedSong = trackKey != _trackKey;
    final changedContent =
        changedSong ||
        !identical(lyrics, _lyrics) ||
        target != _target ||
        settingsKey != _settingsKey;
    _lyrics = lyrics;
    _query = query;
    _target = target;
    _trackKey = trackKey;
    _settingsKey = settingsKey;
    if (changedSong) _cancelled = false;
    if (changedContent) {
      _revision++;
      busy = failed = _attempted = false;
      _translation = null;
    }
    notifyListeners();
    if (lyrics == null || _cancelled || !prefs.lyricsAutoTranslate) return;
    final source = LyricsLanguage.of(
      lyrics.language,
      lyrics.lines.map((l) => l.words).join('\n'),
    );
    if (prefs.lyricsExcludeInterfaceLanguage &&
        LyricsLanguage.excluded(source, target))
      return;
    if (prefs.lyricsExcludedLanguages.any(
      (code) => LyricsLanguage.excluded(source, code),
    ))
      return;
    unawaited(translate());
  }

  Future<void> translate() async {
    final lyrics = _lyrics;
    if (_disposed || lyrics == null || lyrics.lines.isEmpty || busy) return;
    _cancelled = false;
    failed = false;
    _attempted = true;
    final revision = ++_revision;
    _translation = official(lyrics, _target);
    if (_translation?.isCompleteFor(lyrics) ?? false) {
      notifyListeners();
      return;
    }
    final query = _query;
    if (lookup == null || query == null) {
      notifyListeners();
      return;
    }
    busy = true;
    notifyListeners();
    try {
      final result = await lookup!(query, lyrics, _target);
      if (_disposed || revision != _revision) return;
      if (result?.improvesCoverageOf(_translation, lyrics) ?? false) {
        _translation = result;
      }
    } catch (_) {
      if (_disposed || revision != _revision) return;
      // 补缺失败不应把仍可阅读的部分译文变成整首翻译失败。
      failed = _translation == null;
    }
    if (_disposed || revision != _revision) return;
    busy = false;
    notifyListeners();
  }

  void cancel() {
    _revision++;
    _cancelled = true;
    busy = failed = _attempted = false;
    _translation = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}
