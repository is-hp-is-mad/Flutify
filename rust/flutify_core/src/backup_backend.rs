//! 多账号歌单备份：用备份账号自己的 Web 会话（`sp_dc` + access_token）拉取唯一识别符、已点赞歌曲与收藏歌单。
//!
//! 对应原 Dart `SpDcBackupFetcher`。整个拉取在 [`spotify_session::with_session`] 作用域内进行，
//! 复用 `spotify_backend` 的 collection / rootlist / playlist / decorate 拉取，鉴权头、401 续期都落在备份账号上，
//! 不影响主会话。补全曲目详情时优先用主会话（与 Dart 一致：主会话的 decorate 结果更完整、不消耗备份账号配额）。

use std::collections::HashMap;

use serde_json::{json, Value};

use crate::ap_client;
use crate::spotify_backend::{
    self, BackendCollectionEntry, BackendPlaylist, BackendPlaylistSummary, BackendTrack,
};
use crate::spotify_session::{self, SessionState};

/// 收藏歌曲分页：每页条数与最多页数（与 Dart 一致）。
const LIKED_PAGE_SIZE: i32 = 300;
const LIKED_MAX_PAGES: usize = 50;

/// 最多带曲目备份的歌单个数（其余只保留 rootlist 摘要）。
const MAX_PLAYLISTS_WITH_TRACKS: usize = 30;

/// Pathfinder `fetchLibraryTracks` 回退：每页条数与最多页数。
const LIBRARY_PAGE_SIZE: i64 = 50;
const LIBRARY_MAX_PAGES: usize = 300;

/// 拉取请求：备份账号的会话凭据与已知资料（Dart 侧 WebView 登录时拿到的部分可能为空）。
#[derive(Clone, Debug, Default)]
pub struct BackupFetchInput {
    pub sp_dc: String,
    pub access_token: String,
    pub client_token: String,
    pub user_id: String,
    pub email: String,
    pub display_name: String,
    pub avatar_url: String,
    pub spclient_base: String,
    pub web_api_base: String,
    pub profile_attributes_hash: String,
    pub decorate_hash: String,
    pub library_tracks_hash: String,
    /// 主会话（本机登录账号）可用时，用它补全曲目详情、在备份账号读不到时拉取歌单。
    pub use_main_session: bool,
    pub proxy: String,
}

#[derive(Clone, Debug)]
pub struct BackupSnapshot {
    pub id: String,
    pub email: String,
    pub display_name: String,
    pub avatar_url: String,
    pub liked_tracks: Vec<BackendTrack>,
    pub playlists: Vec<BackendPlaylist>,
}

/// 页面给的 access_token 没有到期时间：先当作还能用 10 分钟，401 时用 `sp_dc` 续期。
const ASSUMED_TOKEN_LIFETIME_MS: i64 = 10 * 60 * 1000;

pub async fn fetch_snapshot(input: BackupFetchInput) -> Result<BackupSnapshot, String> {
    let now = spotify_session::now_ms();
    let access_token = input.access_token.trim().to_string();
    let client_token = input.client_token.trim().to_string();
    let state = SessionState {
        sp_dc: input.sp_dc.trim().to_string(),
        access_token_expiry_ms: if access_token.is_empty() { 0 } else { now + ASSUMED_TOKEN_LIFETIME_MS },
        access_token,
        client_token_expiry_ms: if client_token.is_empty() { 0 } else { i64::MAX },
        client_token,
        device_id: String::new(),
        proxy: input.proxy.clone(),
        epoch: 0,
    };
    if state.access_token.is_empty() && state.sp_dc.is_empty() {
        return Err("backup:missing credentials".to_string());
    }
    let proxy = input.proxy.clone();
    spotify_session::with_request_proxy(
        proxy,
        spotify_session::with_session(state, fetch_in_session(input)),
    )
    .await
}

async fn fetch_in_session(input: BackupFetchInput) -> Result<BackupSnapshot, String> {
    // 没有可用令牌（sp_dc 也换不到）时与 Dart 一致：只能报错
    let token = spotify_session::ensure_web_access_token(false)
        .await
        .map_err(|e| format!("backup:token:{e}"))?
        .token;

    let mut id = input.user_id.trim().to_string();
    let mut email = input.email.trim().to_string();
    let mut display_name = input.display_name.trim().to_string();
    let mut avatar_url = input.avatar_url.trim().to_string();

    // 1. 唯一识别符：Pathfinder profileAttributes → /v1/me → APWelcome → 邮箱
    if id.is_empty() || display_name.is_empty() || avatar_url.is_empty() {
        if let Ok(data) = spotify_session::pathfinder_query(
            "profileAttributes",
            &input.profile_attributes_hash,
            json!({}),
        )
        .await
        {
            if let Some(p) = parse_profile_attributes(&data) {
                fill_if_empty(&mut id, p.id);
                fill_if_empty(&mut display_name, p.display_name);
                fill_if_empty(&mut avatar_url, p.avatar_url);
            }
        }
    }
    if id.is_empty() || email.is_empty() {
        let url = format!("{}/me", input.web_api_base.trim_end_matches('/'));
        if let Ok((200, body)) = spotify_session::authorized_request(
            reqwest::Method::GET,
            &url,
            &[("Accept", "application/json")],
            None,
        )
        .await
        {
            if let Ok(me) = serde_json::from_slice::<Value>(&body) {
                let p = parse_web_api_me(&me);
                // /v1/me 的 id 与邮箱更权威，非空即覆盖（与 Dart 一致）
                if !p.id.is_empty() {
                    id = p.id;
                }
                if !p.email.is_empty() {
                    email = p.email;
                }
                fill_if_empty(&mut display_name, p.display_name);
                fill_if_empty(&mut avatar_url, p.avatar_url);
            }
        }
    }
    if id.is_empty() {
        if let Ok(w) = ap_client::ap_connect_and_login(
            None,
            None,
            &spotify_session::effective_proxy(),
            "",
            3, // AUTHENTICATION_SPOTIFY_TOKEN
            token.as_bytes(),
            "",
        )
        .await
        {
            ap_client::ap_close(w.session_id);
            fill_if_empty(&mut id, w.canonical_username);
        }
    }
    if id.is_empty() {
        id = email.clone();
    }
    if id.is_empty() {
        return Err("backup:no_user_id".to_string());
    }
    if display_name.is_empty() {
        display_name = if email.is_empty() { id.clone() } else { email.clone() };
    }

    // 2. 已点赞歌曲：collection 分页取 URI 再补全；读不到时回退 Pathfinder fetchLibraryTracks
    let mut liked = fetch_collection_liked(&input, &id).await;
    if liked.is_empty() && !input.library_tracks_hash.is_empty() {
        liked = fetch_library_tracks(&input.library_tracks_hash).await;
    }

    // 3. 收藏歌单：rootlist 取歌单，前若干个拉完整曲目
    let playlists = fetch_playlists(&input, &id).await;

    Ok(BackupSnapshot {
        id,
        email,
        display_name,
        avatar_url,
        liked_tracks: liked,
        playlists,
    })
}

fn fill_if_empty(target: &mut String, value: String) {
    if target.is_empty() && !value.is_empty() {
        *target = value;
    }
}

async fn fetch_collection_liked(input: &BackupFetchInput, user: &str) -> Vec<BackendTrack> {
    let entries = match spotify_backend::fetch_collection_entries(
        &input.spclient_base,
        user,
        "collection",
        "track",
        LIKED_MAX_PAGES,
        LIKED_PAGE_SIZE,
    )
    .await
    {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };
    if entries.is_empty() {
        return Vec::new();
    }
    let uris: Vec<String> = entries.iter().map(|e| e.uri.clone()).collect();
    let mut tracks = resolve_tracks(input, uris).await;
    apply_added_at(&mut tracks, &entries);
    tracks
}

/// 补全曲目详情：主会话优先（新任务里执行，不继承备份会话覆盖），失败或为空再用备份账号会话。
async fn resolve_tracks(input: &BackupFetchInput, uris: Vec<String>) -> Vec<BackendTrack> {
    if input.use_main_session {
        let main = tokio::spawn(spotify_session::with_request_proxy(
            input.proxy.clone(),
            spotify_backend_fetch_tracks(uris.clone(), input.decorate_hash.clone()),
        ))
        .await;
        if let Ok(Ok(tracks)) = main {
            if !tracks.is_empty() {
                return tracks;
            }
        }
    }
    spotify_backend::fetch_tracks_by_uris(uris, &input.decorate_hash)
        .await
        .unwrap_or_default()
}

async fn spotify_backend_fetch_tracks(
    uris: Vec<String>,
    decorate_hash: String,
) -> Result<Vec<BackendTrack>, String> {
    spotify_backend::fetch_tracks_by_uris(uris, &decorate_hash).await
}

/// 按 id / uri 写回收藏时间（collection 给的是秒）。
pub(crate) fn apply_added_at(tracks: &mut [BackendTrack], entries: &[BackendCollectionEntry]) {
    let mut by_key: HashMap<&str, i64> = HashMap::new();
    for e in entries.iter().filter(|e| e.added_at_sec > 0) {
        by_key.insert(e.id.as_str(), e.added_at_sec * 1000);
        by_key.insert(e.uri.as_str(), e.added_at_sec * 1000);
    }
    for t in tracks.iter_mut() {
        if let Some(ms) = by_key.get(t.id.as_str()).or_else(|| by_key.get(t.uri.as_str())) {
            t.added_at_ms = Some(*ms);
        }
    }
}

async fn fetch_library_tracks(hash: &str) -> Vec<BackendTrack> {
    let mut all = Vec::new();
    let mut offset = 0i64;
    for _ in 0..LIBRARY_MAX_PAGES {
        let data = match spotify_session::pathfinder_query(
            "fetchLibraryTracks",
            hash,
            json!({ "offset": offset, "limit": LIBRARY_PAGE_SIZE }),
        )
        .await
        {
            Ok(d) => d,
            Err(_) => break,
        };
        let (items, total) = parse_library_tracks_page(&data);
        if items.is_empty() {
            break;
        }
        let count = items.len() as i64;
        all.extend(items);
        offset += count;
        if total > 0 {
            if offset >= total {
                break;
            }
        } else if count < LIBRARY_PAGE_SIZE {
            break;
        }
    }
    all
}

async fn fetch_playlists(input: &BackupFetchInput, user: &str) -> Vec<BackendPlaylist> {
    let summaries = match spotify_backend::fetch_rootlist(&input.spclient_base, user).await {
        Ok(list) => list,
        Err(_) => return Vec::new(),
    };
    let mut result = Vec::new();
    for summary in summaries
        .into_iter()
        .filter(|p| !p.id.is_empty())
        .take(MAX_PLAYLISTS_WITH_TRACKS)
    {
        let full = fetch_single_playlist(input, &summary).await;
        result.push(full.unwrap_or_else(|| playlist_from_summary(summary)));
    }
    result
}

/// 先用备份账号自己的会话（专属 Mix / 私密歌单只有它读得到），读不到再用主会话按 ID 拉。
async fn fetch_single_playlist(
    input: &BackupFetchInput,
    base: &BackendPlaylistSummary,
) -> Option<BackendPlaylist> {
    let own = spotify_backend::fetch_playlist_full(&input.spclient_base, &base.id, &input.decorate_hash)
        .await
        .ok()
        .flatten()
        .filter(|p| !p.tracks.is_empty());
    let full = match own {
        Some(p) => Some(p),
        None if input.use_main_session => {
            let (spclient, id, hash) =
                (input.spclient_base.clone(), base.id.clone(), input.decorate_hash.clone());
            tokio::spawn(spotify_session::with_request_proxy(input.proxy.clone(), async move {
                spotify_backend::fetch_playlist_full(&spclient, &id, &hash).await
            }))
            .await
            .ok()
            .and_then(Result::ok)
            .flatten()
        }
        None => None,
    }?;
    Some(merge_with_summary(full, base))
}

/// 名称 / 封面缺失时用 rootlist 摘要补上；曲目数取实际拉到的条数（与 Dart 一致）。
pub(crate) fn merge_with_summary(mut full: BackendPlaylist, base: &BackendPlaylistSummary) -> BackendPlaylist {
    if full.name.is_empty() {
        full.name = base.name.clone();
    }
    if full.images.is_empty() {
        full.images = base.images.clone();
    }
    if !full.tracks.is_empty() {
        full.total_tracks = full.tracks.len() as i32;
    }
    full
}

fn playlist_from_summary(s: BackendPlaylistSummary) -> BackendPlaylist {
    BackendPlaylist {
        id: s.id,
        name: s.name,
        uri: s.uri,
        description: s.description,
        owner_name: s.owner_name,
        images: s.images,
        total_tracks: s.total_tracks,
        tracks: Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

#[derive(Debug, Default, PartialEq)]
pub(crate) struct ProfileInfo {
    pub id: String,
    pub email: String,
    pub display_name: String,
    pub avatar_url: String,
}

fn str_of(v: Option<&Value>) -> String {
    v.and_then(Value::as_str).unwrap_or("").trim().to_string()
}

/// Pathfinder `profileAttributes`：`me.profile.{username, name, avatar.sources[]}`，头像取最宽的一张。
pub(crate) fn parse_profile_attributes(data: &Value) -> Option<ProfileInfo> {
    let p = data.get("me")?.get("profile")?.as_object()?;
    let username = str_of(p.get("username"));
    let name = str_of(p.get("name"));
    if username.is_empty() && name.is_empty() {
        return None;
    }
    let avatar_url = p
        .get("avatar")
        .and_then(|a| a.get("sources"))
        .and_then(Value::as_array)
        .and_then(|sources| {
            sources
                .iter()
                .filter(|s| s.is_object())
                .max_by_key(|s| s.get("width").and_then(Value::as_f64).unwrap_or(0.0) as i64)
        })
        .map(|s| str_of(s.get("url")))
        .unwrap_or_default();
    Some(ProfileInfo {
        display_name: if name.is_empty() { username.clone() } else { name },
        id: username,
        email: String::new(),
        avatar_url,
    })
}

/// Web API `/v1/me`：`{id, email, display_name, images[0].url}`。
pub(crate) fn parse_web_api_me(me: &Value) -> ProfileInfo {
    ProfileInfo {
        id: str_of(me.get("id")),
        email: str_of(me.get("email")),
        display_name: str_of(me.get("display_name")),
        avatar_url: me
            .get("images")
            .and_then(Value::as_array)
            .and_then(|a| a.first())
            .map(|i| str_of(i.get("url")))
            .unwrap_or_default(),
    }
}

/// Pathfinder `fetchLibraryTracks`：`me.library.tracks.{totalCount, items[{track, addedAt}]}`。
pub(crate) fn parse_library_tracks_page(data: &Value) -> (Vec<BackendTrack>, i64) {
    let Some(page) = data
        .get("me")
        .and_then(|m| m.get("library"))
        .and_then(|l| l.get("tracks"))
        .filter(|p| p.is_object())
    else {
        return (Vec::new(), 0);
    };
    let total = page
        .get("totalCount")
        .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())))
        .unwrap_or(0);
    let mut items = Vec::new();
    for item in page.get("items").and_then(Value::as_array).into_iter().flatten() {
        let Some(wrapper) = item.get("track").filter(|t| t.is_object()) else {
            continue;
        };
        let mut inner = wrapper
            .get("data")
            .filter(|d| d.is_object())
            .unwrap_or(wrapper)
            .clone();
        if inner.get("uri").is_none() {
            if let Some(uri) = wrapper.get("_uri").and_then(Value::as_str) {
                inner["uri"] = Value::String(uri.to_string());
            }
        }
        let Some(mut track) = spotify_backend::parse_track(&inner) else {
            continue;
        };
        let added = item
            .get("addedAt")
            .and_then(|a| a.get("isoString").or(Some(a)))
            .and_then(Value::as_str)
            .and_then(iso8601_to_ms);
        track.added_at_ms = added;
        items.push(track);
    }
    (items, total)
}

/// `YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)` → Unix 毫秒；不认识的格式返回 None。
pub(crate) fn iso8601_to_ms(s: &str) -> Option<i64> {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b' ') || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, sec) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    let mut rest = &s[19..];
    let mut millis = 0i64;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits: String = frac.chars().take_while(char::is_ascii_digit).collect();
        if digits.is_empty() {
            return None;
        }
        let padded = format!("{digits:0<3}");
        millis = padded[..3].parse().ok()?;
        rest = &frac[digits.len()..];
    }
    let offset_min = match rest {
        "" | "Z" | "z" => 0,
        _ => {
            let sign = match rest.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let tz = rest[1..].replace(':', "");
            if tz.len() != 4 {
                return None;
            }
            sign * (tz[..2].parse::<i64>().ok()? * 60 + tz[2..].parse::<i64>().ok()?)
        }
    };
    // days_from_civil（Howard Hinnant）
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 86_400 + h * 3600 + mi * 60 + sec) - offset_min * 60) * 1000 + millis)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_parsing() {
        assert_eq!(iso8601_to_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso8601_to_ms("2024-02-29T12:34:56.789Z"), Some(1_709_210_096_789));
        assert_eq!(iso8601_to_ms("2024-02-29T20:34:56+08:00"), Some(1_709_210_096_000));
        assert_eq!(iso8601_to_ms("2024-02-29T12:34:56.5Z"), Some(1_709_210_096_500));
        assert_eq!(iso8601_to_ms("2024-02-29"), None);
        assert_eq!(iso8601_to_ms("not a date at all!!"), None);
    }

    #[test]
    fn profile_attributes_pick_widest_avatar_and_fallback_name() {
        let data = json!({"me": {"profile": {
            "username": " user1 ",
            "name": "",
            "avatar": {"sources": [
                {"url": "small", "width": 64},
                {"url": "big", "width": 640},
                "garbage"
            ]}
        }}});
        assert_eq!(
            parse_profile_attributes(&data),
            Some(ProfileInfo {
                id: "user1".into(),
                email: String::new(),
                display_name: "user1".into(),
                avatar_url: "big".into(),
            })
        );
        assert_eq!(parse_profile_attributes(&json!({"me": {"profile": {}}})), None);
        assert_eq!(parse_profile_attributes(&json!({})), None);
    }

    #[test]
    fn web_api_me() {
        let me = json!({"id": "u", "email": "a@b.c", "display_name": "Name", "images": [{"url": "img"}]});
        assert_eq!(
            parse_web_api_me(&me),
            ProfileInfo {
                id: "u".into(),
                email: "a@b.c".into(),
                display_name: "Name".into(),
                avatar_url: "img".into(),
            }
        );
        assert_eq!(parse_web_api_me(&json!({"images": "x"})), ProfileInfo::default());
    }

    fn track(uri: &str) -> BackendTrack {
        BackendTrack {
            id: uri.rsplit(':').next().unwrap().to_string(),
            name: String::new(),
            uri: uri.to_string(),
            artists: Vec::new(),
            album: None,
            duration_ms: 0,
            explicit: false,
            is_playable: true,
            added_at_ms: None,
        }
    }

    #[test]
    fn added_at_from_collection_entries() {
        let mut tracks = vec![track("spotify:track:a"), track("spotify:track:b"), track("spotify:track:c")];
        let entries = vec![
            BackendCollectionEntry { uri: "spotify:track:a".into(), id: "a".into(), added_at_sec: 10 },
            BackendCollectionEntry { uri: "spotify:track:b".into(), id: "b".into(), added_at_sec: 0 },
        ];
        apply_added_at(&mut tracks, &entries);
        assert_eq!(tracks[0].added_at_ms, Some(10_000));
        assert_eq!(tracks[1].added_at_ms, None);
        assert_eq!(tracks[2].added_at_ms, None);
    }

    #[test]
    fn library_page_items_and_total() {
        let data = json!({"me": {"library": {"tracks": {
            "totalCount": "2",
            "items": [
                {
                    "addedAt": {"isoString": "1970-01-01T00:00:01Z"},
                    "track": {"_uri": "spotify:track:t1", "data": {"name": "One", "duration": {"totalMilliseconds": 1000}}}
                },
                {"track": null},
                {"addedAt": "bad", "track": {"data": {"uri": "spotify:episode:e"}}}
            ]
        }}}});
        let (items, total) = parse_library_tracks_page(&data);
        assert_eq!(total, 2);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].uri, "spotify:track:t1");
        assert_eq!(items[0].added_at_ms, Some(1000));
        assert_eq!(parse_library_tracks_page(&json!({})).0.len(), 0);
    }

    #[test]
    fn summary_fills_missing_name_and_images() {
        let summary = BackendPlaylistSummary {
            id: "p".into(),
            name: "From rootlist".into(),
            uri: "spotify:playlist:p".into(),
            description: String::new(),
            owner_name: String::new(),
            images: vec![spotify_backend::BackendImage { url: "cover".into(), width: None, height: None }],
            total_tracks: 99,
        };
        let full = BackendPlaylist {
            id: "p".into(),
            name: String::new(),
            uri: "spotify:playlist:p".into(),
            description: String::new(),
            owner_name: String::new(),
            images: Vec::new(),
            total_tracks: 99,
            tracks: vec![track("spotify:track:x")],
        };
        let merged = merge_with_summary(full, &summary);
        assert_eq!(merged.name, "From rootlist");
        assert_eq!(merged.images.len(), 1);
        assert_eq!(merged.total_tracks, 1);
    }
}
