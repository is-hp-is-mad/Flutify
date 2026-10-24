import '../../core/rust_core.dart';
import '../../models/lyrics.dart';
import '../../src/rust/api/lyrics.dart' as rust;
import 'lyric_script.dart';
import 'translation_markers.dart';

/// 双语对照 LRC 拆分成「原文 + 译文」单行。
///
/// 很多歌词库里同一首歌另有一份对照版：同一时间点（或相差零点几秒）放原文与译文。
/// 这份歌词不再是「翻译版，不可用」，而是拆开后两者兼得——原文照常滚动，译文存进
/// [LyricLine.translation]。判定不到对照结构时返回 null，调用方按普通歌词处理。
///
/// 配对按逐行文种（[detectLang]）区分：拉丁 vs 中文、日文 vs 中文、中文 vs 韩文……
/// 日文靠假名与中文区分，全汉字的日文行可能与中文译文同文种而配对不到——
/// 这种情况两行都当原文保留，宁可多上一行也不丢行。
///
/// 哪种文种是原文（[_pickOriginalTag]）：
/// 1. 成对组里出现次数最多的文种；
/// 2. 平票（标准对照 LRC 每组各一行，必然平票）时优先非中文：本应用的译文来源（LRCLIB 对照版、
///    网易云 tlyric）几乎都是中文译文，「中文原文 + 外文译文」的对照极少；
///    不用曲名 / 歌手判断——Spotify 会本地化歌手名、J-pop 常用英文曲名，全汉字日文曲名也会被判成中文；
/// 3. 仍平票（如日文 + 罗马音 + 中文三行组）时取组内更常排在前面的文种。
///
/// 哪些文种是译文（[_pickTranslationTags]）：成对组里作为「非原文」出现次数不少于最多者一半的文种。
/// 只出现在零星几组里的其他文种（如日文歌里 0.5 秒内紧接着唱的英文句）是真歌词，单独成行，不吞进译文。
class TranslationMerge {
  TranslationMerge._();

  /// 同一时间点判定的容差（译文常与原文共用时间戳，或相差零点几秒）：
  /// 与上一行相差不超过它的相邻行归为一组。
  static const int _toleranceMs = 500;

  /// 行多时同时间点可叠原文 + 多种标注（假名 / 罗马音 / 译文），一句原文最多挂两行译文，
  /// 拼接起来，不逐条开新槽位。
  static const int _maxTranslationLines = 2;

  /// 尝试拆分；不是对照结构返回 null。返回的行数与原文行数一致（译文行被吸收）。
  static List<LyricLine>? tryMerge(List<LyricLine> lines) {
    if (RustCore.ready) {
      final merged = rust.tryMergeBilingualLines(
        lines: [
          for (final l in lines)
            rust.LrcLine(startTimeMs: l.startTimeMs, words: l.words),
        ],
      );
      if (merged == null) return null;
      return [
        for (final m in merged)
          LyricLine(
            startTimeMs: m.startTimeMs,
            words: m.words,
            translation: m.translation,
          ),
      ];
    }
    // 按时间邻近分组（解析已稳定排序，同时间点保持原有先后）：与上一行相差 ≤ 容差即同组。
    // 不用固定时间桶——01.24 与 01.26 会被桶边界拆开；组内再按时间就近配对（见 [_mergeGroup]）。
    // 空行是间奏标记（界面显示 • • •），不参与配对，原样保留；
    // 翻译署名行（常见于曲首，「中文翻译：xxx」「歌词翻译 by xxx」）不是歌词，剔除
    final groups = <List<LyricLine>>[];
    final empties = <LyricLine>[];
    for (final l in lines) {
      if (l.words.trim().isEmpty) {
        empties.add(l);
        continue;
      }
      if (TranslationMarkers.isCreditLine(l.words)) continue;
      if (groups.isNotEmpty &&
          l.startTimeMs - groups.last.last.startTimeMs <= _toleranceMs) {
        groups.last.add(l);
      } else {
        groups.add([l]);
      }
    }

    // 对照结构判定：组内至少两种已知文种算成对；配对数按「组内行数 − 最多的同文种行数」估计
    var pairs = 0, nonEmpty = 0;
    for (final group in groups) {
      nonEmpty += group.length;
      final counts = _tagLineCounts(group);
      if (counts.length < 2) continue;
      final known = counts.values.fold(0, (a, b) => a + b);
      final top = counts.values.reduce((a, b) => a > b ? a : b);
      pairs += known - top;
    }
    if (pairs < 3 || pairs * 3 < nonEmpty) return null;

    final originalTag = _pickOriginalTag(groups);
    final translationTags = _pickTranslationTags(groups, originalTag);

    final merged = <LyricLine>[];
    for (final group in groups) {
      if (_tagLineCounts(group).length < 2) {
        // 同文种多行（快歌 0.5 秒内连唱两句）或无法判定文种：逐行保留，它们不是对照
        merged.addAll(group);
        continue;
      }
      merged.addAll(_mergeGroup(group, originalTag, translationTags));
    }
    // 分组可能打散 0.5 秒内的原始顺序，合并后把间奏行放回去重新按时间排（稳定排序）
    merged.addAll(empties);
    final indexed = merged.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.startTimeMs.compareTo(b.$2.startTimeMs);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final result = [for (final (_, line) in indexed) line];
    return result.isEmpty ? null : result;
  }

  /// 拆开后所有行的原文拼接（语言投票 / 打分用，只看原文，不掺译文）。
  static String originalText(List<LyricLine> lines) => lines
      .where((l) => l.words.trim().isNotEmpty)
      .map((l) => l.words)
      .join('\n');

  /// 组内各已知文种的行数（无字母行不计）。
  static Map<LyricLang, int> _tagLineCounts(List<LyricLine> group) {
    final counts = <LyricLang, int>{};
    for (final l in group) {
      final tag = detectLang(l.words);
      if (tag != LyricLang.unknown) counts[tag] = (counts[tag] ?? 0) + 1;
    }
    return counts;
  }

  /// 全局文种投票定原文文种，规则见类注释。
  static LyricLang _pickOriginalTag(List<List<LyricLine>> groups) {
    final presence = <LyricLang, int>{}; // 出现在多少个成对组里
    final leading = <LyricLang, int>{}; // 在多少个成对组里排在最前
    for (final group in groups) {
      final tags = [
        for (final l in group) detectLang(l.words),
      ].where((t) => t != LyricLang.unknown).toList();
      if (tags.toSet().length < 2) continue;
      for (final tag in tags.toSet()) {
        presence[tag] = (presence[tag] ?? 0) + 1;
      }
      leading[tags.first] = (leading[tags.first] ?? 0) + 1;
    }
    var best = LyricLang.unknown;
    for (final tag in presence.keys) {
      if (best == LyricLang.unknown || _beats(tag, best, presence, leading))
        best = tag;
    }
    return best;
  }

  /// 组内的原文文种：有全局原文文种就用它，否则（如日文歌里夹的英文 hook + 中文译文）取组内第一行的文种。
  static LyricLang _groupTag(List<LyricLang> tags, LyricLang originalTag) =>
      tags.contains(originalTag)
      ? originalTag
      : tags.firstWhere((t) => t != LyricLang.unknown);

  /// 全局译文文种，规则见类注释。
  static Set<LyricLang> _pickTranslationTags(
    List<List<LyricLine>> groups,
    LyricLang originalTag,
  ) {
    final presence = <LyricLang, int>{};
    for (final group in groups) {
      final tags = [for (final l in group) detectLang(l.words)];
      final known = tags.where((t) => t != LyricLang.unknown).toSet();
      if (known.length < 2) continue;
      for (final tag in known.difference({_groupTag(tags, originalTag)})) {
        presence[tag] = (presence[tag] ?? 0) + 1;
      }
    }
    if (presence.isEmpty) return const {};
    final top = presence.values.reduce((a, b) => a > b ? a : b);
    return {
      for (final e in presence.entries)
        if (e.value * 2 >= top) e.key,
    };
  }

  static bool _beats(
    LyricLang a,
    LyricLang b,
    Map<LyricLang, int> presence,
    Map<LyricLang, int> leading,
  ) {
    final pa = presence[a] ?? 0, pb = presence[b] ?? 0;
    if (pa != pb) return pa > pb;
    // 平票：中文多半是译文
    if ((a == LyricLang.zh) != (b == LyricLang.zh)) return b == LyricLang.zh;
    return (leading[a] ?? 0) > (leading[b] ?? 0);
  }

  /// 拆一个成对组：原文文种的行各自独立成原文行，译文文种的行按时间就近挂到原文行上当译文；
  /// 既不是原文也不是译文文种的行（零星的另一种语言）照常保留为独立的歌词行。
  static List<LyricLine> _mergeGroup(
    List<LyricLine> group,
    LyricLang originalTag,
    Set<LyricLang> translationTags,
  ) {
    final tags = [for (final l in group) detectLang(l.words)];
    final groupTag = _groupTag(tags, originalTag);

    final originals = <int>[]; // group 下标
    final translations = <int, List<String>>{};
    final out = <LyricLine>[];
    for (var i = 0; i < group.length; i++) {
      if (tags[i] == groupTag) {
        originals.add(i);
        translations[i] = [];
      }
    }
    for (var i = 0; i < group.length; i++) {
      if (tags[i] == groupTag) continue;
      final l = group[i];
      // 无字母行（只有标点 / 音符）不当译文，免得把装饰行贴进译文槽；非译文文种的行是真歌词
      if (tags[i] == LyricLang.unknown || !translationTags.contains(tags[i])) {
        out.add(LyricLine(startTimeMs: l.startTimeMs, words: l.words));
        continue;
      }
      // 挑时间最近的原文行；同样近时挑译文少的、再挑靠前的（同时间点两句原文 + 两句译文按顺序一一对应）
      int? target;
      for (final o in originals) {
        if (translations[o]!.length >= _maxTranslationLines) continue;
        if (target == null) {
          target = o;
          continue;
        }
        final d = (group[o].startTimeMs - l.startTimeMs).abs();
        final bestD = (group[target].startTimeMs - l.startTimeMs).abs();
        if (d < bestD ||
            (d == bestD &&
                translations[o]!.length < translations[target]!.length))
          target = o;
      }
      // 每句原文的译文槽都满了：多余的标注行丢弃（与原先「只取前两种」一致）
      if (target != null) translations[target]!.add(l.words);
    }
    for (final o in originals) {
      final l = group[o];
      out.add(
        LyricLine(
          startTimeMs: l.startTimeMs,
          words: l.words,
          translation: translations[o]!.join(' / '),
        ),
      );
    }
    return out;
  }
}
