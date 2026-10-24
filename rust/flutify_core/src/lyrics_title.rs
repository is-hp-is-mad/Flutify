//! 曲名清理：移除 `feat.` / `ft.` / `featuring` 伴唱署名，同时保留 Remix / Live / Version 等版本标记。
//!
//! 行为与 `lib/services/lyrics/lyrics_title.dart` 完全一致。

fn starts_with_feat_prefix(s: &str) -> bool {
    let low = s.trim_start().to_lowercase();
    for p in ["feat.", "ft."] {
        if low.starts_with(p) {
            return true;
        }
    }
    for p in ["feat", "ft", "featuring"] {
        if let Some(rest) = low.strip_prefix(p) {
            if rest.starts_with(char::is_whitespace) {
                return true;
            }
        }
    }
    false
}

fn remove_bracketed_credits(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let chars: Vec<(usize, char)> = input.char_indices().collect();
    let mut i = 0;
    while i < chars.len() {
        let (byte_pos, c) = chars[i];
        if matches!(c, '[' | '(' | '（') {
            // Find first closing bracket ], ), ）
            let mut close_idx = None;
            for (j, &(_, ch)) in chars.iter().enumerate().skip(i + 1) {
                if matches!(ch, ']' | ')' | '）') {
                    close_idx = Some(j);
                    break;
                }
            }
            if let Some(j) = close_idx {
                let inner_start = byte_pos + c.len_utf8();
                let inner_end = chars[j].0;
                let inner = &input[inner_start..inner_end];
                if !inner.is_empty() && starts_with_feat_prefix(inner) {
                    // Trim trailing whitespace already pushed to `out`
                    let trimmed_len = out.trim_end().len();
                    out.truncate(trimmed_len);
                    i = j + 1;
                    continue;
                }
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

fn remove_trailing_credit(input: &str) -> String {
    let chars: Vec<(usize, char)> = input.char_indices().collect();
    for (idx, &(pos, c)) in chars.iter().enumerate() {
        if !c.is_whitespace() {
            continue;
        }
        // Skip contiguous whitespace
        let mut after_ws_pos = pos + c.len_utf8();
        let mut k = idx + 1;
        while k < chars.len() && chars[k].1.is_whitespace() {
            after_ws_pos = chars[k].0 + chars[k].1.len_utf8();
            k += 1;
        }
        if k >= chars.len() {
            break;
        }
        let mut candidate = &input[after_ws_pos..];
        // Optional `[-–—]\s*`
        for dash in ['-', '–', '—'] {
            if let Some(r) = candidate.strip_prefix(dash) {
                candidate = r.trim_start();
                break;
            }
        }
        if starts_with_feat_prefix(candidate)
            && !candidate
                .chars()
                .any(|ch| matches!(ch, '[' | ']' | '(' | ')' | '（' | '）'))
        {
            return input[..pos].to_string();
        }
    }
    input.to_string()
}

/// 清理曲名中的伴唱署名并折叠多余空白。
pub fn clean_search_title(title: &str) -> String {
    let s1 = remove_bracketed_credits(title);
    let s2 = remove_trailing_credit(&s1);
    s2.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removes_featured_credits_but_keeps_version_tags() {
        assert_eq!(
            clean_search_title("Song (feat. Artist B) [Live]"),
            "Song [Live]"
        );
        assert_eq!(clean_search_title("Song - ft. Someone"), "Song");
        assert_eq!(
            clean_search_title("Song (Acoustic) feat. Someone"),
            "Song (Acoustic)"
        );
    }
}
