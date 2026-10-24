use crate::artist_match;
use crate::lrc::{self, LyricLine as ParsedLine};
use crate::lyric_script::{self, LyricLang};
use crate::lyrics_title;
use crate::translation_markers;
use crate::translation_merge;
use crate::zh_script;

/// 一行同步歌词（`start_time_ms` 为毫秒）。
pub struct LrcLine {
    pub start_time_ms: i64,
    pub words: String,
}

/// 拆分后的双语歌词行（原文 + 译文）。
pub struct BilingualLine {
    pub start_time_ms: i64,
    pub words: String,
    pub translation: String,
}

/// 解析 LRC 文本，语义与 Dart 版 `LrcParser.parse` 一致。
#[flutter_rust_bridge::frb(sync)]
pub fn parse_lrc(lrc: String) -> Vec<LrcLine> {
    lrc::parse_lrc(&lrc)
        .into_iter()
        .map(|l| LrcLine {
            start_time_ms: l.start_time_ms,
            words: l.words,
        })
        .collect()
}

/// 短文本（曲名 / 歌手）文种识别，返回 `LyricLang.index`。
#[flutter_rust_bridge::frb(sync)]
pub fn detect_lyric_lang(text: String) -> i32 {
    lyric_script::detect_lang(&text).index()
}

/// 歌词正文主语言识别，返回 `LyricLang.index`。
#[flutter_rust_bridge::frb(sync)]
pub fn main_lyric_lang(text: String) -> i32 {
    lyric_script::lyric_lang(&text).index()
}

/// 歌词文字与目标语言的吻合度（0 ~ 100）。
#[flutter_rust_bridge::frb(sync)]
pub fn score_lyric_lang(target: i32, text: String) -> f64 {
    lyric_script::lang_score(LyricLang::from_index(target), &text)
}

/// 一行歌词的主导文字大类（0..=7，无字母时为 -1）。
#[flutter_rust_bridge::frb(sync)]
pub fn lyric_line_family(text: String) -> i32 {
    lyric_script::line_family(&text)
}

/// 统计繁体专用字数（基于 OpenCC `ZhHans` 转换变化字数）。
#[flutter_rust_bridge::frb(sync)]
pub fn zh_count_traditional(text: String) -> i32 {
    zh_script::count_traditional(&text) as i32
}

/// 统计简体专用字数（基于 OpenCC `ZhHant` 转换变化字数）。
#[flutter_rust_bridge::frb(sync)]
pub fn zh_count_simplified(text: String) -> i32 {
    zh_script::count_simplified(&text) as i32
}

/// 基于 OpenCC 词组级消歧转换简繁字形（`to_simplified = true` 转简体，否则转繁体）。
#[flutter_rust_bridge::frb(sync)]
pub fn zh_convert(text: String, to_simplified: bool) -> String {
    zh_script::convert(&text, to_simplified)
}

/// 判断文本是否含翻译 / 罗马音标记词。
#[flutter_rust_bridge::frb(sync)]
pub fn has_translation_marker(text: String) -> bool {
    translation_markers::has_marker(&text)
}

/// 判断单行是否为翻译 / 制作署名行。
#[flutter_rust_bridge::frb(sync)]
pub fn is_translation_credit_line(text: String) -> bool {
    translation_markers::is_credit_line(&text)
}

/// 尝试将双语对照 LRC 拆分为「原文 + 译文」；非对照结构返回 `None`。
#[flutter_rust_bridge::frb(sync)]
pub fn try_merge_bilingual_lines(lines: Vec<LrcLine>) -> Option<Vec<BilingualLine>> {
    let parsed: Vec<ParsedLine> = lines
        .into_iter()
        .map(|l| ParsedLine {
            start_time_ms: l.start_time_ms,
            words: l.words,
        })
        .collect();
    let merged = translation_merge::try_merge(&parsed)?;
    Some(
        merged
            .into_iter()
            .map(|m| BilingualLine {
                start_time_ms: m.start_time_ms,
                words: m.words,
                translation: m.translation,
            })
            .collect(),
    )
}

/// 判断整首歌词是否为双语混排（非逐句对照）。
#[flutter_rust_bridge::frb(sync)]
pub fn is_mixed_script_lines(lines: Vec<String>) -> bool {
    translation_merge::is_mixed_lines(&lines)
}

/// 比对查询歌手与候选歌手：`0 = match`，`1 = mismatch`，`2 = unknown`。
#[flutter_rust_bridge::frb(sync)]
pub fn compare_artists(query_artist: String, candidate_artist: String) -> i32 {
    artist_match::compare_artists(&query_artist, &candidate_artist)
}

/// 清理曲名中的 `feat.` / `ft.` / `featuring` 署名。
#[flutter_rust_bridge::frb(sync)]
pub fn clean_lyrics_search_title(title: String) -> String {
    lyrics_title::clean_search_title(&title)
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
