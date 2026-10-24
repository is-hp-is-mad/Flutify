//! 解析分享页复制出的 `spotify:track:xxx`（及 `album` / `playlist` / `artist`）URI 与 `open.spotify.com` 分享链接。

use crate::spotify_id::SpotifyId;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpotifyLink {
    /// `"track"` | `"album"` | `"playlist"` | `"artist"`
    pub kind: String,
    /// 22 位 base62 ID
    pub id: String,
    /// 规范化 URI：`spotify:{kind}:{id}`
    pub uri: String,
}

const SUPPORTED_KINDS: [&str; 4] = ["track", "album", "playlist", "artist"];

fn build_link(kind: &str, raw_id: &str) -> Option<SpotifyLink> {
    if !SUPPORTED_KINDS.contains(&kind) {
        return None;
    }
    // 截取开头的连续 ASCII 字母数字（去掉 ?si=...、#、空白、标点等后缀）
    let id_len = raw_id
        .bytes()
        .take_while(|b| b.is_ascii_alphanumeric())
        .count();
    let id = &raw_id[..id_len];
    if SpotifyId::from_base62(id).is_err() {
        return None;
    }
    Some(SpotifyLink {
        kind: kind.to_string(),
        id: id.to_string(),
        uri: format!("spotify:{kind}:{id}"),
    })
}

/// 从任意输入文本（搜索框输入、剪贴板分享文案、URI、网页链接）中提取 Spotify 资源目标。
pub fn parse_spotify_link(input: &str) -> Option<SpotifyLink> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }

    // 1. 匹配 `spotify:...` URI（支持 `spotify:track:ID`、`spotify:user:xxx:playlist:ID`，以及混合在分享文本中的 URI）
    let lower = trimmed.to_ascii_lowercase();
    if let Some(pos) = lower.find("spotify:") {
        let tail = &trimmed[pos + "spotify:".len()..];
        let parts: Vec<&str> = tail.split(':').collect();
        if parts.len() >= 2 {
            // 处理 `spotify:user:xxx:playlist:ID`
            if parts.len() >= 4 && parts[0].eq_ignore_ascii_case("user") {
                let kind = parts[2].to_ascii_lowercase();
                if let Some(link) = build_link(&kind, parts[3]) {
                    return Some(link);
                }
            }
            let kind = parts[0].to_ascii_lowercase();
            if let Some(link) = build_link(&kind, parts[1]) {
                return Some(link);
            }
        }
    }

    // 2. 匹配 `open.spotify.com` / `play.spotify.com` 分享链接（含 `/intl-xx/`、`/embed/`）
    for host in ["open.spotify.com/", "play.spotify.com/"] {
        if let Some(pos) = lower.find(host) {
            let path = &trimmed[pos + host.len()..];
            let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
            for window in segments.windows(2) {
                let kind = window[0].to_ascii_lowercase();
                if SUPPORTED_KINDS.contains(&kind.as_str()) {
                    if let Some(link) = build_link(&kind, window[1]) {
                        return Some(link);
                    }
                }
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_ID: &str = "4uLU6hMCjMI75M1A2tKUQC";

    #[test]
    fn parses_spotify_track_and_entity_uris() {
        assert_eq!(
            parse_spotify_link(&format!("spotify:track:{SAMPLE_ID}")),
            Some(SpotifyLink {
                kind: "track".to_string(),
                id: SAMPLE_ID.to_string(),
                uri: format!("spotify:track:{SAMPLE_ID}"),
            })
        );
        assert_eq!(
            parse_spotify_link(&format!("  spotify:album:{SAMPLE_ID}?context=foo ")),
            Some(SpotifyLink {
                kind: "album".to_string(),
                id: SAMPLE_ID.to_string(),
                uri: format!("spotify:album:{SAMPLE_ID}"),
            })
        );
        assert_eq!(
            parse_spotify_link(&format!("spotify:user:spotify:playlist:{SAMPLE_ID}")),
            Some(SpotifyLink {
                kind: "playlist".to_string(),
                id: SAMPLE_ID.to_string(),
                uri: format!("spotify:playlist:{SAMPLE_ID}"),
            })
        );
    }

    #[test]
    fn parses_open_spotify_share_urls() {
        assert_eq!(
            parse_spotify_link(&format!(
                "https://open.spotify.com/track/{SAMPLE_ID}?si=123456"
            )),
            Some(SpotifyLink {
                kind: "track".to_string(),
                id: SAMPLE_ID.to_string(),
                uri: format!("spotify:track:{SAMPLE_ID}"),
            })
        );
        assert_eq!(
            parse_spotify_link(&format!(
                "分享单曲 https://open.spotify.com/intl-zh/artist/{SAMPLE_ID} 快听听"
            )),
            Some(SpotifyLink {
                kind: "artist".to_string(),
                id: SAMPLE_ID.to_string(),
                uri: format!("spotify:artist:{SAMPLE_ID}"),
            })
        );
    }

    #[test]
    fn ignores_normal_search_keywords_and_invalid_ids() {
        assert_eq!(parse_spotify_link("周杰伦 晴天"), None);
        assert_eq!(parse_spotify_link("spotify:track:too_short"), None);
    }
}
