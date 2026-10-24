//! 双语对照 LRC 拆分成「原文 + 译文」单行，以及双语整体混排判定。
//!
//! 行为与 `lib/services/lyrics/translation_merge.dart` 及 `translation_filter.dart` 完全一致。

use std::collections::{HashMap, HashSet};

use crate::lrc::LyricLine as ParsedLine;
use crate::lyric_script::{detect_lang, line_family, LyricLang};
use crate::translation_markers::is_credit_line;

const TOLERANCE_MS: i64 = 500;
const MAX_TRANSLATION_LINES: usize = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergedLyricLine {
    pub start_time_ms: i64,
    pub words: String,
    pub translation: String,
}

fn tag_line_counts(group: &[ParsedLine]) -> HashMap<LyricLang, usize> {
    let mut counts = HashMap::new();
    for l in group {
        let tag = detect_lang(&l.words);
        if tag != LyricLang::Unknown {
            *counts.entry(tag).or_insert(0) += 1;
        }
    }
    counts
}

fn beats(
    a: LyricLang,
    b: LyricLang,
    presence: &HashMap<LyricLang, usize>,
    leading: &HashMap<LyricLang, usize>,
) -> bool {
    let pa = presence.get(&a).copied().unwrap_or(0);
    let pb = presence.get(&b).copied().unwrap_or(0);
    if pa != pb {
        return pa > pb;
    }
    if (a == LyricLang::Zh) != (b == LyricLang::Zh) {
        return b == LyricLang::Zh;
    }
    let la = leading.get(&a).copied().unwrap_or(0);
    let lb = leading.get(&b).copied().unwrap_or(0);
    la > lb
}

fn pick_original_tag(groups: &[Vec<ParsedLine>]) -> LyricLang {
    let mut presence: HashMap<LyricLang, usize> = HashMap::new();
    let mut leading: HashMap<LyricLang, usize> = HashMap::new();
    let mut order: Vec<LyricLang> = Vec::new();
    for group in groups {
        let tags: Vec<LyricLang> = group
            .iter()
            .map(|l| detect_lang(&l.words))
            .filter(|&t| t != LyricLang::Unknown)
            .collect();
        let mut seen = HashSet::new();
        let mut unique_in_group = Vec::new();
        for &t in &tags {
            if seen.insert(t) {
                unique_in_group.push(t);
            }
        }
        if unique_in_group.len() < 2 {
            continue;
        }
        for t in unique_in_group {
            if !presence.contains_key(&t) {
                order.push(t);
            }
            *presence.entry(t).or_insert(0) += 1;
        }
        *leading.entry(tags[0]).or_insert(0) += 1;
    }
    let mut best = LyricLang::Unknown;
    for tag in order {
        if best == LyricLang::Unknown || beats(tag, best, &presence, &leading) {
            best = tag;
        }
    }
    best
}

fn group_tag(tags: &[LyricLang], original_tag: LyricLang) -> LyricLang {
    if tags.contains(&original_tag) {
        original_tag
    } else {
        tags.iter()
            .copied()
            .find(|&t| t != LyricLang::Unknown)
            .unwrap_or(LyricLang::Unknown)
    }
}

fn pick_translation_tags(groups: &[Vec<ParsedLine>], original_tag: LyricLang) -> HashSet<LyricLang> {
    let mut presence: HashMap<LyricLang, usize> = HashMap::new();
    for group in groups {
        let tags: Vec<LyricLang> = group.iter().map(|l| detect_lang(&l.words)).collect();
        let known: HashSet<LyricLang> = tags
            .iter()
            .copied()
            .filter(|&t| t != LyricLang::Unknown)
            .collect();
        if known.len() < 2 {
            continue;
        }
        let g_tag = group_tag(&tags, original_tag);
        for tag in known {
            if tag != g_tag {
                *presence.entry(tag).or_insert(0) += 1;
            }
        }
    }
    let Some(&top) = presence.values().max() else {
        return HashSet::new();
    };
    presence
        .into_iter()
        .filter_map(|(k, v)| if v * 2 >= top { Some(k) } else { None })
        .collect()
}

fn merge_group(
    group: &[ParsedLine],
    original_tag: LyricLang,
    translation_tags: &HashSet<LyricLang>,
) -> Vec<MergedLyricLine> {
    let tags: Vec<LyricLang> = group.iter().map(|l| detect_lang(&l.words)).collect();
    let g_tag = group_tag(&tags, original_tag);

    let mut originals: Vec<usize> = Vec::new();
    let mut translations: HashMap<usize, Vec<String>> = HashMap::new();
    let mut out: Vec<MergedLyricLine> = Vec::new();

    for (i, &t) in tags.iter().enumerate() {
        if t == g_tag {
            originals.push(i);
            translations.insert(i, Vec::new());
        }
    }

    for (i, l) in group.iter().enumerate() {
        if tags[i] == g_tag {
            continue;
        }
        if tags[i] == LyricLang::Unknown || !translation_tags.contains(&tags[i]) {
            out.push(MergedLyricLine {
                start_time_ms: l.start_time_ms,
                words: l.words.clone(),
                translation: String::new(),
            });
            continue;
        }
        let mut target: Option<usize> = None;
        for &o in &originals {
            let o_len = translations.get(&o).map_or(0, Vec::len);
            if o_len >= MAX_TRANSLATION_LINES {
                continue;
            }
            let Some(curr) = target else {
                target = Some(o);
                continue;
            };
            let d = (group[o].start_time_ms - l.start_time_ms).abs();
            let best_d = (group[curr].start_time_ms - l.start_time_ms).abs();
            let curr_len = translations.get(&curr).map_or(0, Vec::len);
            if d < best_d || (d == best_d && o_len < curr_len) {
                target = Some(o);
            }
        }
        if let Some(t_idx) = target {
            if let Some(list) = translations.get_mut(&t_idx) {
                list.push(l.words.clone());
            }
        }
    }

    for o in originals {
        let l = &group[o];
        let trans = translations
            .remove(&o)
            .unwrap_or_default()
            .join(" / ");
        out.push(MergedLyricLine {
            start_time_ms: l.start_time_ms,
            words: l.words.clone(),
            translation: trans,
        });
    }
    out
}

/// 尝试将双语对照 LRC 行拆分为「原文 + 译文」；不是对照结构时返回 `None`。
pub fn try_merge(lines: &[ParsedLine]) -> Option<Vec<MergedLyricLine>> {
    let mut groups: Vec<Vec<ParsedLine>> = Vec::new();
    let mut empties: Vec<MergedLyricLine> = Vec::new();

    for l in lines {
        if l.words.trim().is_empty() {
            empties.push(MergedLyricLine {
                start_time_ms: l.start_time_ms,
                words: l.words.clone(),
                translation: String::new(),
            });
            continue;
        }
        if is_credit_line(&l.words) {
            continue;
        }
        if let Some(last_group) = groups.last_mut() {
            if let Some(last_line) = last_group.last() {
                if l.start_time_ms - last_line.start_time_ms <= TOLERANCE_MS {
                    last_group.push(l.clone());
                    continue;
                }
            }
        }
        groups.push(vec![l.clone()]);
    }

    let mut pairs = 0usize;
    let mut non_empty = 0usize;
    for group in &groups {
        non_empty += group.len();
        let counts = tag_line_counts(group);
        if counts.len() < 2 {
            continue;
        }
        let known: usize = counts.values().sum();
        let top: usize = counts.values().copied().max().unwrap_or(0);
        pairs += known - top;
    }
    if pairs < 3 || pairs * 3 < non_empty {
        return None;
    }

    let original_tag = pick_original_tag(&groups);
    let translation_tags = pick_translation_tags(&groups, original_tag);

    let mut merged: Vec<MergedLyricLine> = Vec::new();
    for group in &groups {
        if tag_line_counts(group).len() < 2 {
            for l in group {
                merged.push(MergedLyricLine {
                    start_time_ms: l.start_time_ms,
                    words: l.words.clone(),
                    translation: String::new(),
                });
            }
            continue;
        }
        merged.extend(merge_group(group, original_tag, &translation_tags));
    }

    merged.extend(empties);
    merged.sort_by_key(|l| l.start_time_ms);
    if merged.is_empty() {
        None
    } else {
        Some(merged)
    }
}

/// 整首双语混排（非逐句对照，两种文字大类各占 40% 以上）。
pub fn is_mixed_lines(lines: &[String]) -> bool {
    let mut n = 0usize;
    let mut cjk = 0usize;
    let mut lat = 0usize;
    let mut cyr = 0usize;
    for w in lines {
        if w.trim().is_empty() {
            continue;
        }
        n += 1;
        match line_family(w) {
            0 => cjk += 1,
            1 => lat += 1,
            2 => cyr += 1,
            _ => {}
        }
    }
    if n < 4 {
        return false;
    }
    let big = [cjk, lat, cyr].into_iter().filter(|&k| k * 5 >= n * 2).count();
    big >= 2
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lrc::parse_lrc;

    #[test]
    fn merges_bilingual_and_preserves_order() {
        let lrc = "[00:00.00]中文翻译：某某\n\
                   [00:01.00]走在路上\n[00:01.00]walking down the road\n\
                   [00:02.00]\n\
                   [00:03.00]天空下面\n[00:03.00]under the sky\n\
                   [00:05.00]整夜不停\n[00:05.00]all night long";
        let merged = try_merge(&parse_lrc(lrc)).unwrap();
        let non_empty: Vec<_> = merged.iter().filter(|l| !l.words.is_empty()).collect();
        assert_eq!(
            non_empty.iter().map(|l| l.words.as_str()).collect::<Vec<_>>(),
            vec!["walking down the road", "under the sky", "all night long"]
        );
        assert_eq!(
            non_empty
                .iter()
                .map(|l| l.translation.as_str())
                .collect::<Vec<_>>(),
            vec!["走在路上", "天空下面", "整夜不停"]
        );
    }
}
