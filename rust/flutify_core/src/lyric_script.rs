//! 文种识别：按字符所属文字（汉字 / 假名 / 谚文 / 拉丁 …）判断一段文本是哪种语言的歌词。
//!
//! 行为与 `lib/services/lyrics/lyric_script.dart` 保持一致（按 UTF-16 码元统计）。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(usize)]
pub enum Script {
    Han = 0,
    Kana = 1,
    Hangul = 2,
    Cyrillic = 3,
    Greek = 4,
    Thai = 5,
    Arabic = 6,
    Hebrew = 7,
    Latin = 8,
    Other = 9,
}

impl Script {
    pub const COUNT: usize = 10;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i32)]
pub enum LyricLang {
    Zh = 0,
    Ja = 1,
    Ko = 2,
    Latin = 3,
    Cyrillic = 4,
    Greek = 5,
    Thai = 6,
    Arabic = 7,
    Hebrew = 8,
    Unknown = 9,
}

impl LyricLang {
    pub fn from_index(index: i32) -> Self {
        match index {
            0 => Self::Zh,
            1 => Self::Ja,
            2 => Self::Ko,
            3 => Self::Latin,
            4 => Self::Cyrillic,
            5 => Self::Greek,
            6 => Self::Thai,
            7 => Self::Arabic,
            8 => Self::Hebrew,
            _ => Self::Unknown,
        }
    }

    pub fn index(self) -> i32 {
        self as i32
    }
}

pub fn script_of(c: u16) -> Option<Script> {
    if (0x0041..=0x005A).contains(&c) || (0x0061..=0x007A).contains(&c) {
        return Some(Script::Latin);
    }
    if (0x4E00..=0x9FFF).contains(&c)
        || (0x3400..=0x4DBF).contains(&c)
        || (0xF900..=0xFAFF).contains(&c)
    {
        return Some(Script::Han);
    }
    if (0x3040..=0x30FF).contains(&c)
        || (0x31F0..=0x31FF).contains(&c)
        || (0xFF66..=0xFF9F).contains(&c)
    {
        return Some(Script::Kana);
    }
    if (0xAC00..=0xD7AF).contains(&c)
        || (0x1100..=0x11FF).contains(&c)
        || (0x3130..=0x318F).contains(&c)
    {
        return Some(Script::Hangul);
    }
    if (0x0400..=0x052F).contains(&c) {
        return Some(Script::Cyrillic);
    }
    if (0x0370..=0x03FF).contains(&c) || (0x1F00..=0x1FFF).contains(&c) {
        return Some(Script::Greek);
    }
    if (0x0E00..=0x0E7F).contains(&c) {
        return Some(Script::Thai);
    }
    if (0x0600..=0x06FF).contains(&c)
        || (0x0750..=0x077F).contains(&c)
        || (0xFB50..=0xFDFF).contains(&c)
        || (0xFE70..=0xFEFF).contains(&c)
    {
        return Some(Script::Arabic);
    }
    if (0x0590..=0x05FF).contains(&c) {
        return Some(Script::Hebrew);
    }
    if (0x00C0..=0x024F).contains(&c) || (0x1E00..=0x1EFF).contains(&c) {
        return Some(Script::Latin);
    }
    if is_other_letter(c) {
        return Some(Script::Other);
    }
    None
}

fn is_other_letter(c: u16) -> bool {
    (0x0530..=0x058F).contains(&c)
        || (0x0900..=0x0DFF).contains(&c)
        || (0x0E80..=0x0FFF).contains(&c)
        || (0x10A0..=0x10FF).contains(&c)
        || (0x1780..=0x17FF).contains(&c)
}

#[derive(Debug, Clone, Copy)]
pub struct ScriptCounts {
    counts: [usize; Script::COUNT],
}

impl ScriptCounts {
    pub fn of(text: &str) -> Self {
        let mut counts = [0usize; Script::COUNT];
        for c in text.encode_utf16() {
            if let Some(s) = script_of(c) {
                counts[s as usize] += 1;
            }
        }
        Self { counts }
    }

    pub fn get(&self, s: Script) -> usize {
        self.counts[s as usize]
    }

    pub fn total(&self) -> usize {
        self.counts.iter().sum()
    }
}

pub fn detect_lang(text: &str) -> LyricLang {
    let c = ScriptCounts::of(text);
    if c.get(Script::Kana) > 0 {
        return LyricLang::Ja;
    }
    if c.get(Script::Hangul) > 0 {
        return LyricLang::Ko;
    }
    if c.get(Script::Han) > 0 {
        return LyricLang::Zh;
    }
    if c.get(Script::Cyrillic) > 0 {
        return LyricLang::Cyrillic;
    }
    if c.get(Script::Greek) > 0 {
        return LyricLang::Greek;
    }
    if c.get(Script::Thai) > 0 {
        return LyricLang::Thai;
    }
    if c.get(Script::Arabic) > 0 {
        return LyricLang::Arabic;
    }
    if c.get(Script::Hebrew) > 0 {
        return LyricLang::Hebrew;
    }
    if c.get(Script::Latin) > 0 {
        return LyricLang::Latin;
    }
    LyricLang::Unknown
}

pub fn lyric_lang(text: &str) -> LyricLang {
    let c = ScriptCounts::of(text);
    let total = c.total();
    if total < 1 {
        return LyricLang::Unknown;
    }
    let total_f = total as f64;
    if (c.get(Script::Kana) as f64) / total_f >= 0.05 {
        return LyricLang::Ja;
    }
    if (c.get(Script::Hangul) as f64) / total_f >= 0.15 {
        return LyricLang::Ko;
    }
    if (c.get(Script::Han) as f64) / total_f >= 0.15 {
        return LyricLang::Zh;
    }
    const ORDER: [(Script, LyricLang); 6] = [
        (Script::Latin, LyricLang::Latin),
        (Script::Cyrillic, LyricLang::Cyrillic),
        (Script::Greek, LyricLang::Greek),
        (Script::Thai, LyricLang::Thai),
        (Script::Arabic, LyricLang::Arabic),
        (Script::Hebrew, LyricLang::Hebrew),
    ];
    let mut best = LyricLang::Unknown;
    let mut best_n = 0usize;
    for (script, lang) in ORDER {
        if c.get(script) > best_n {
            best_n = c.get(script);
            best = lang;
        }
    }
    best
}

pub fn lang_score(target: LyricLang, text: &str) -> f64 {
    let c = ScriptCounts::of(text);
    let total = c.total() as f64;
    if total < 1.0 {
        return 0.0;
    }
    let r = |s: Script| (c.get(s) as f64) / total;
    let han = r(Script::Han);
    let kana = r(Script::Kana);
    let hangul = r(Script::Hangul);
    let latin = r(Script::Latin);
    let (exact, near) = match target {
        LyricLang::Zh => (han, kana + hangul),
        LyricLang::Ja => (kana + han * 0.6, han * 0.4),
        LyricLang::Ko => (hangul, han * 0.25),
        LyricLang::Latin => (latin, r(Script::Greek) * 0.2),
        LyricLang::Cyrillic => (r(Script::Cyrillic), 0.0),
        LyricLang::Greek => (r(Script::Greek), latin * 0.2),
        LyricLang::Thai => (r(Script::Thai), 0.0),
        LyricLang::Arabic => (r(Script::Arabic), 0.0),
        LyricLang::Hebrew => (r(Script::Hebrew), 0.0),
        LyricLang::Unknown => (-1.0, 0.0),
    };
    if exact < 0.0 {
        return 50.0;
    }
    let far = (1.0 - exact - near).clamp(0.0, 1.0);
    let m = exact + near * 0.5 - far * 0.5;
    (m * 100.0).clamp(0.0, 100.0)
}

pub fn line_family(text: &str) -> i32 {
    let mut fam = [0usize; 8];
    let mut best: i32 = -1;
    let mut best_n = 0usize;
    for c in text.encode_utf16() {
        let Some(s) = script_of(c) else {
            continue;
        };
        let f: usize = match s {
            Script::Han | Script::Kana | Script::Hangul => 0,
            Script::Latin => 1,
            Script::Cyrillic => 2,
            Script::Greek => 3,
            Script::Thai => 4,
            Script::Arabic => 5,
            Script::Hebrew => 6,
            Script::Other => 7,
        };
        fam[f] += 1;
        if fam[f] > best_n {
            best_n = fam[f];
            best = f as i32;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_short_text_languages() {
        assert_eq!(detect_lang("夜に駆ける"), LyricLang::Ja);
        assert_eq!(detect_lang("사랑해"), LyricLang::Ko);
        assert_eq!(detect_lang("晴天"), LyricLang::Zh);
        assert_eq!(detect_lang("Blinding Lights"), LyricLang::Latin);
        assert_eq!(detect_lang("123 !@#"), LyricLang::Unknown);
    }

    #[test]
    fn detects_main_lyric_language_and_family() {
        assert_eq!(lyric_lang("君の知らない物語 love you"), LyricLang::Ja);
        assert_eq!(lyric_lang("夜空中最亮的星 oh yeah"), LyricLang::Zh);
        assert_eq!(line_family("Hello world"), 1);
        assert_eq!(line_family("你好世界"), 0);
        assert_eq!(line_family("12345"), -1);
    }

    #[test]
    fn scores_target_language() {
        assert!(lang_score(LyricLang::Ja, "夜に駆ける") > lang_score(LyricLang::Ja, "Hello world"));
        assert_eq!(lang_score(LyricLang::Unknown, "Hello world"), 50.0);
        assert_eq!(lang_score(LyricLang::Zh, "123"), 0.0);
    }
}
