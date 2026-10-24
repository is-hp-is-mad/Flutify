//! 候选歌词的歌手与当前曲目比对（多位艺人拆分、繁简统一、同文种词覆盖判断）。
//!
//! 行为与 `lib/services/lyrics/artist_match.dart` 完全一致。

use std::collections::HashSet;

use crate::lyric_script::{detect_lang, LyricLang};
use crate::zh_script;

/// 返回值对应 Dart `ArtistMatch.index`：`0 = match`，`1 = mismatch`，`2 = unknown`。
pub fn compare_artists(query_artist: &str, candidate_artist: &str) -> i32 {
    let a = normalize(query_artist);
    let b = normalize(candidate_artist);
    if a.is_empty() || b.is_empty() {
        return 2;
    }
    let lang_a = detect_lang(&a);
    let lang_b = detect_lang(&b);
    if lang_a == LyricLang::Unknown || lang_a != lang_b {
        return 2;
    }

    let names_a = split_names(&a);
    let names_b = split_names(&b);
    let words_a: HashSet<&str> = names_a.iter().flatten().map(String::as_str).collect();
    let words_b: HashSet<&str> = names_b.iter().flatten().map(String::as_str).collect();

    let covered = |names: &[Vec<String>], words: &HashSet<&str>| -> bool {
        names
            .iter()
            .any(|n| !n.is_empty() && n.iter().all(|w| words.contains(w.as_str())))
    };

    if covered(&names_a, &words_b) || covered(&names_b, &words_a) {
        0
    } else {
        1
    }
}

fn normalize(artist: &str) -> String {
    let text = artist.trim().to_lowercase();
    if zh_script::count_traditional(&text) > 0 {
        zh_script::convert(&text, true)
    } else {
        text
    }
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric()
}

fn split_names(artist: &str) -> Vec<Vec<String>> {
    // 先把符号分隔符替换为 '\n'
    let mut s = String::with_capacity(artist.len());
    for c in artist.chars() {
        if matches!(c, ',' | '&' | '/' | ';' | '+' | '、' | '，') {
            s.push('\n');
        } else {
            s.push(c);
        }
    }

    let mut out = Vec::new();
    for segment in s.split('\n') {
        // 在 segment 内按词切分，遇到独立连接词（feat/ft/with/x/and/vs）时切开为多个人名
        let mut current_words: Vec<String> = Vec::new();
        for token in segment.split_whitespace() {
            let trimmed = token.trim_matches('.');
            if matches!(
                trimmed,
                "feat" | "ft" | "with" | "x" | "and" | "vs"
            ) {
                if !current_words.is_empty() {
                    out.push(std::mem::take(&mut current_words));
                }
                continue;
            }
            for w in token.split(|c: char| !is_word_char(c)) {
                if !w.is_empty() {
                    current_words.push(w.to_string());
                }
            }
        }
        if !current_words.is_empty() {
            out.push(current_words);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_and_normalizes_artists() {
        assert_eq!(compare_artists("GAMPER & DADONI, ILIRA", "Gamper, Dadoni"), 0);
        assert_eq!(compare_artists("Alpha", "Alpha feat. Beta"), 0);
        assert_eq!(compare_artists("Tiësto", "Tiësto, Someone Else"), 0);
        assert_eq!(compare_artists("Alpha & Beta", "Delta Band"), 1);
        assert_eq!(compare_artists("陈奕迅", "陳奕迅"), 0);
        assert_eq!(compare_artists("某歌手", "Some Singer"), 2);
        assert_eq!(compare_artists("", "Alpha"), 2);
    }
}
