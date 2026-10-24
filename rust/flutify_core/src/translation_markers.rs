//! 翻译版 / 罗马音 / 对照歌词的标记词与署名行识别。
//!
//! 行为与 `lib/services/lyrics/translation_markers.dart` 完全一致。

const MARKER_WORDS: [&str; 22] = [
    "translation",
    "translated",
    "romanization",
    "romanized",
    "romanised",
    "romaji",
    "pronunciation",
    "phonetic",
    "pinyin",
    "翻譯",
    "翻译",
    "中譯",
    "中译",
    "羅馬音",
    "罗马音",
    "音譯",
    "音译",
    "空耳",
    "拼音",
    "注音",
    "對照",
    "对照",
];

const ZH_PREFIXES: [&str; 9] = [
    "中文", "中", "英文", "日文", "韩文", "韓文", "歌词", "歌詞", "",
];

const ZH_ROLES: [&str; 17] = [
    "翻譯", "翻译", "譯文", "译文", "中譯", "中译", "音譯", "音译", "羅馬音", "罗马音", "拼音",
    "注音", "對照", "对照", "空耳", "譯", "译",
];

const EN_ROLES: [&str; 7] = [
    "translation",
    "translated",
    "romanization",
    "romanized",
    "romanised",
    "romaji",
    "pinyin",
];

/// 判断文本是否包含翻译 / 罗马音标记词。
pub fn has_marker(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    let low = text.to_lowercase();
    MARKER_WORDS.iter().any(|w| low.contains(w))
}

fn strip_leading_bracket(s: &str) -> &str {
    let s = s.trim_start();
    for b in ['(', '（', '[', '【'] {
        if let Some(rest) = s.strip_prefix(b) {
            return rest.trim_start();
        }
    }
    s
}

fn starts_with_colon_or_by(s: &str) -> bool {
    let s = s.trim_start();
    if s.starts_with(':') || s.starts_with('：') {
        return true;
    }
    if s.len() >= 2 && s[..2].eq_ignore_ascii_case("by") {
        let after = &s[2..];
        return after.is_empty()
            || !after
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_');
    }
    false
}

/// 歌词正文里的翻译署名 / 制作署名行（如「中文翻译：xxx」「Translated by xxx」「by: xxx」）。
pub fn is_credit_line(text: &str) -> bool {
    let t = text.trim();
    if t.is_empty() {
        return false;
    }
    let body = strip_leading_bracket(t);
    let low = body.to_lowercase();

    // 1. _byCredit: ^[\(\[]?\s*by\s*[:：]
    if let Some(after_by) = low.strip_prefix("by") {
        let after_by = after_by.trim_start();
        if after_by.starts_with(':') || after_by.starts_with('：') {
            return true;
        }
    }

    // 2. _zhCredit
    for prefix in ZH_PREFIXES {
        let rest = if prefix.is_empty() {
            body
        } else if let Some(r) = body.strip_prefix(prefix) {
            r.trim_start()
        } else {
            continue;
        };
        for role in ZH_ROLES {
            if let Some(after_role) = rest.strip_prefix(role) {
                if starts_with_colon_or_by(after_role) {
                    return true;
                }
            }
        }
    }

    // 3. _enCredit: ^[\(\[]?\s*(?:lyrics?\s+)?(?:english\s+|chinese\s+)?(?:translation|...)\s*(?:[:：]|by\b)
    let mut en_rest = low.as_str();
    for lyr in ["lyrics", "lyric"] {
        if let Some(r) = en_rest.strip_prefix(lyr) {
            if r.starts_with(char::is_whitespace) {
                en_rest = r.trim_start();
                break;
            }
        }
    }
    for lang in ["english", "chinese"] {
        if let Some(r) = en_rest.strip_prefix(lang) {
            if r.starts_with(char::is_whitespace) {
                en_rest = r.trim_start();
                break;
            }
        }
    }
    for role in EN_ROLES {
        if let Some(after_role) = en_rest.strip_prefix(role) {
            if starts_with_colon_or_by(after_role) {
                return true;
            }
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_markers_and_credit_lines() {
        assert!(has_marker("Road (中文翻译)"));
        assert!(has_marker("Lost in Translation"));
        assert!(is_credit_line("中文翻译：某某"));
        assert!(is_credit_line("Translated by someone"));
        assert!(is_credit_line("by: 某某"));
        assert!(!is_credit_line("lost in translation"));
        assert!(!is_credit_line("迷失在翻译里"));
    }
}
