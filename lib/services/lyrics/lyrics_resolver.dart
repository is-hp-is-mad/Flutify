import '../../models/lyrics.dart';
import '../../models/lyrics_query.dart';
import 'lrclib_lyrics_source.dart';
import 'lyrics_language.dart';
import 'lyrics_translation.dart';
import 'translation_source.dart';
import 'zh_script.dart';

/// 合并后的歌词与是否可以缓存（网络问题导致的结果不缓存，下次打开会重试）。
class ResolvedLyrics {
  final SpotifyLyrics lyrics;
  final bool cacheable;

  const ResolvedLyrics(this.lyrics, {this.cacheable = true});
}

/// 歌词来源合并：Spotify 官方优先，没有逐行同步歌词时用 LRCLIB 补全；
/// 之后可选挂译文源（QQ 优先、网易云兜底，只取译文、不动原文）。
///
/// | Spotify 结果 | 处理 |
/// |---|---|
/// | 逐行同步（LINE_SYNCED） | 直接用，不查 LRCLIB |
/// | 只有纯文本（UNSYNCED） | LRCLIB 找到同步歌词就替换，否则保留纯文本 |
/// | 没有歌词（404） | LRCLIB 找到就用，否则为空 |
/// | 请求失败 | LRCLIB 找到就用，否则抛出原错误（调用方显示「暂无歌词」且不缓存） |
///
/// 「双语歌词」决定加载原文时是否预取中文译文；翻译按钮 / 自动翻译通过 translate 独立查询。
/// 查询会把曲名与歌手发给实际查询的来源。预取开关变化时由调用方重新解析
///（见 SpotifyProvider.invalidateResolvedLyrics）。查不到译文时保持单语；
/// 查询遇网络错误时把结果标记为不可缓存，下次打开歌词会重新尝试（原文本身已有缓存，重试很便宜）。
class LyricsResolver {
  final Future<SpotifyLyrics> Function(String trackId) _official;

  /// LRCLIB 补全来源；为 null 时只用官方歌词。
  final LrclibLyricsSource? fallback;

  /// 网易云译文来源；为 null 时不查网易云（兼容原有构造参数）。
  final TranslationSource? translation;

  /// QQ 中文译文优先来源；为空时保持原有来源链。
  final TranslationSource? qqTranslation;

  Iterable<TranslationSource> get translationSources sync* {
    if (qqTranslation != null) yield qqTranslation!;
    if (translation != null) yield translation!;
  }

  /// 设置里是否开启了补全；为 false 时行为与只用官方歌词相同。
  final bool Function() _fallbackEnabled;

  /// 是否在加载原文时预取双语歌词；主动翻译由 translate 单独处理。
  final bool Function() _translationEnabled;

  LyricsResolver(
    this._official, {
    this.fallback,
    bool Function()? fallbackEnabled,
    this.translation,
    this.qqTranslation,
    bool Function()? translationEnabled,
  }) : _fallbackEnabled = fallbackEnabled ?? (() => true),
       _translationEnabled = translationEnabled ?? (() => true);

  /// 翻译按钮或自动翻译明确发起的查询，不依赖「预加载双语歌词」开关。
  /// QQ / 网易云提供中文译词；只转换译词字形，不把原文转字形冒充翻译。
  /// 部分译文允许继续查已有备用源；只换成覆盖更多且不丢行的整份译词，
  /// 保留准确的来源标识。补查失败时返回已有译文，无任何译文才报告网络错误。
  Future<LyricsTranslation?> translate(
    LyricsQuery query,
    SpotifyLyrics lyrics,
    String target,
  ) async {
    final found = await _findTranslation(query, lyrics, target);
    if (found.translation == null && found.networkError) {
      throw StateError('Lyrics translation source unavailable');
    }
    return found.translation;
  }

  /// 预加载、主动翻译与自动翻译共享同一覆盖率规则和来源顺序。
  Future<({LyricsTranslation? translation, bool networkError})>
  _findTranslation(
    LyricsQuery query,
    SpotifyLyrics lyrics,
    String target,
  ) async {
    var best = LyricsTranslationController.official(lyrics, target);
    if ((best?.isCompleteFor(lyrics) ?? false) ||
        !lyrics.isSynced ||
        lyrics.lines.isEmpty) {
      return (translation: best, networkError: false);
    }
    void consider(LyricsTranslation? candidate) {
      if (candidate?.improvesCoverageOf(best, lyrics) ?? false) {
        best = candidate;
      }
    }

    final language = LyricsLanguage.normalize(target);
    var networkError = false;
    if (language.startsWith('zh')) {
      for (final source in translationSources) {
        if (best?.provider == source.provider) continue;
        try {
          final found = await source.find(query, lyrics.lines);
          networkError |= found.networkError;
          final lines = found.lines;
          if (lines != null &&
              lines.length == lyrics.lines.length &&
              lines.any((line) => line.words.trim().isNotEmpty)) {
            final code = LyricsLanguage.of(
              'und',
              lines.map((l) => l.words).join('\n'),
            );
            if (code.startsWith('zh')) {
              consider(
                LyricsTranslation(
                  List.unmodifiable(
                    lines.map(
                      (line) => ZhScript.convert(
                        line.words,
                        toSimplified: language != 'zh-Hant',
                      ),
                    ),
                  ),
                  source.provider,
                ),
              );
            }
          }
        } catch (_) {
          networkError = true;
        }
        if (best?.isCompleteFor(lyrics) ?? false) {
          return (translation: best, networkError: networkError);
        }
      }
    }
    if (_fallbackEnabled()) {
      try {
        consider(await fallback?.findTranslation(query, lyrics, target));
      } catch (_) {
        networkError = true;
      }
    }
    return (translation: best, networkError: networkError);
  }

  Future<ResolvedLyrics> resolve(LyricsQuery query) async {
    var resolved = await _resolveOriginal(query);
    final translated = await _attachTranslation(query, resolved);
    return translated ?? resolved;
  }

  /// 删除各路本地缓存（「重新获取歌词」），并作废来源内的进行中缓存写入。
  Future<void> forget(LyricsQuery query) async {
    await fallback?.forget(query);
    for (final source in translationSources) {
      await source.forget(query);
    }
  }

  Future<ResolvedLyrics> _resolveOriginal(LyricsQuery query) async {
    SpotifyLyrics? official;
    Object? error;
    StackTrace? stack;
    try {
      official = await _official(query.trackId);
    } catch (e, s) {
      error = e;
      stack = s;
    }
    if (official != null && official.isSynced) return ResolvedLyrics(official);

    final fallback = this.fallback;
    var cacheable = error == null;
    if (fallback != null && _fallbackEnabled()) {
      final found = await fallback.find(query);
      final lyrics = found.lyrics;
      if (lyrics != null) return ResolvedLyrics(lyrics);
      if (found.networkError) cacheable = false;
    }
    if (error != null) Error.throwWithStackTrace(error, stack!);
    return ResolvedLyrics(
      official ?? const SpotifyLyrics(lines: []),
      cacheable: cacheable,
    );
  }

  /// 预取中文译文；完整内嵌译文保持原样，部分译文只由不丢行的更完整来源替换。
  /// 开关在这一刻读取，解析途中切换以切换后的为准。
  Future<ResolvedLyrics?> _attachTranslation(
    LyricsQuery query,
    ResolvedLyrics resolved,
  ) async {
    if (translationSources.isEmpty || !_translationEnabled()) return null;
    final lyrics = resolved.lyrics;
    final lines = lyrics.lines;
    if (!lyrics.isSynced || lines.isEmpty) return null;
    // Preload only adds Chinese translations to foreign originals. Preserve
    // the existing skip before reaching LRCLIB, not merely inside QQ/NetEase.
    if (LyricsLanguage.of(
      'und',
      lines.map((line) => line.words).join('\n'),
    ).startsWith('zh'))
      return null;
    final inline = LyricsTranslation(
      lines.map((line) => line.translation).toList(),
      lyrics.translationProvider ?? lyrics.provider,
    );
    if (inline.isCompleteFor(lyrics)) return null;
    // Preloading has no target locale: do not replace a complete supplied
    // translation in any language just to fetch another Chinese version.
    for (final alternative in lyrics.alternatives) {
      if (LyricsTranslationController.official(
            lyrics,
            alternative.language,
          )?.isCompleteFor(lyrics) ??
          false) {
        return null;
      }
    }
    final existing =
        LyricsTranslationController.official(lyrics, 'zh-Hans') ??
        LyricsTranslationController.official(lyrics, 'zh-Hant');
    // Preserve partial embedded translations in another language as before;
    // an explicit target-language request may independently query sources.
    if (existing == null &&
        inline.lines.any((line) => line.trim().isNotEmpty)) {
      return null;
    }
    final target = existing == null
        ? 'zh-Hans'
        : LyricsLanguage.of('und', existing.lines.join('\n'));
    final found = await _findTranslation(query, lyrics, target);
    final selected = found.translation;
    final cacheable = resolved.cacheable && !found.networkError;
    if (selected == null || !selected.improvesCoverageOf(existing, lyrics)) {
      return cacheable == resolved.cacheable
          ? null
          : ResolvedLyrics(lyrics, cacheable: cacheable);
    }
    // 按下标对齐（译文源保证与 lines 等长）：同一时间戳的两句原文各拿各的译文
    return ResolvedLyrics(
      SpotifyLyrics(
        syncType: lyrics.syncType,
        language: lyrics.language,
        provider: lyrics.provider,
        translationProvider: selected.provider,
        alternatives: lyrics.alternatives,
        lines: [
          for (final (i, l) in lines.indexed)
            LyricLine(
              startTimeMs: l.startTimeMs,
              words: l.words,
              translation: selected.lines[i],
              syllables: l.syllables,
            ),
        ],
      ),
      cacheable: cacheable,
    );
  }
}
