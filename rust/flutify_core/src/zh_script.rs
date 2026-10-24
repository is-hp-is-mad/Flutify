//! 基于 OpenCC（`zhconv` 双数组 Aho-Corasick 前缀自动机）的词组级简繁消歧转换与判定。
//!
//! 采用 `Variant::ZhHans`（`t2s`）与 `Variant::ZhHant`（`s2t`）字形消歧模式：
//! - 正确处理「一简多繁」歧义词组（如「白发 / 出发」「背后 / 皇后」「心里 / 千里」「眼泪干了 / 骨干」）；
//! - 不做地区惯用词替换（不把歌词作者的原始词汇改成异地同义词）。

use zhconv::{zhconv, Variant};

/// 繁体专用字的个数（经 OpenCC `ZhHans` 转换后会变化的字数）。
pub fn count_traditional(text: &str) -> usize {
    if text.is_empty() {
        return 0;
    }
    let simp = zhconv(text, Variant::ZhHans);
    text.chars().zip(simp.chars()).filter(|(a, b)| a != b).count()
}

/// 简体专用字的个数（经 OpenCC `ZhHant` 转换后会变化的字数）。
pub fn count_simplified(text: &str) -> usize {
    if text.is_empty() {
        return 0;
    }
    let trad = zhconv(text, Variant::ZhHant);
    text.chars().zip(trad.chars()).filter(|(a, b)| a != b).count()
}

/// 词组级消歧转换：`to_simplified = true` 转为简体（`ZhHans`），`false` 转为繁体（`ZhHant`）。
pub fn convert(text: &str, to_simplified: bool) -> String {
    if text.is_empty() {
        return String::new();
    }
    let target = if to_simplified {
        Variant::ZhHans
    } else {
        Variant::ZhHant
    };
    zhconv(text, target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disambiguates_one_to_many_phrases() {
        assert_eq!(convert("白发苍苍，准备出发", false), "白髮蒼蒼，準備出發");
        assert_eq!(convert("皇后的背后", false), "皇后的背後");
        assert_eq!(convert("心里千里之外", false), "心裏千里之外");
        assert_eq!(convert("說話的時候", true), "说话的时候");
        assert_eq!(convert("陳奕迅", true), "陈奕迅");
    }

    #[test]
    fn counts_traditional_and_simplified() {
        assert!(count_traditional("說話的時候") >= 2);
        assert_eq!(count_simplified("說話的時候"), 0);
        assert!(count_simplified("说话的时候") >= 2);
        assert_eq!(count_traditional("说话的时候"), 0);
    }
}
