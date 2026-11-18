//! 高并发 / 重解析 Spotify 后端操作（歌单并发分页 + 批量曲目补全 + 收藏 Protobuf 分页）。

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use base64::Engine as _;
use futures_util::future::join_all;
use serde_json::{json, Value};
use tokio::sync::Semaphore;

use crate::spotify_session;

const PLAYLIST_PAGE_LIMIT: usize = 100;
const DECORATE_BATCH_SIZE: usize = 50;
const MAX_CONCURRENCY: usize = 6;
const COLLECTION_CONTENT_TYPE: &str = "application/vnd.collection-v2.spotify.proto";

#[derive(Clone, Debug)]
pub struct BackendImage {
    pub url: String,
    pub width: Option<i32>,
    pub height: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct BackendArtist {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub images: Vec<BackendImage>,
    pub followers: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct BackendAlbum {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub album_type: String,
    pub release_date: String,
    pub total_tracks: i32,
    pub images: Vec<BackendImage>,
    pub artists: Vec<BackendArtist>,
}

#[derive(Clone, Debug)]
pub struct BackendTrack {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub artists: Vec<BackendArtist>,
    pub album: Option<BackendAlbum>,
    pub duration_ms: i32,
    pub explicit: bool,
    pub is_playable: bool,
    pub added_at_ms: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct BackendPlaylist {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub description: String,
    pub owner_name: String,
    pub images: Vec<BackendImage>,
    pub total_tracks: i32,
    pub tracks: Vec<BackendTrack>,
}

#[derive(Clone, Debug)]
pub struct BackendCollectionEntry {
    pub uri: String,
    pub id: String,
    pub added_at_sec: i64,
}

#[derive(Clone, Debug)]
pub struct BackendHomeChip {
    pub id: String,
    pub label: String,
    pub sub_chips: Vec<BackendHomeChip>,
}

#[derive(Clone, Debug)]
pub struct BackendHomeItem {
    pub kind: i32, // 0: playlist, 1: album, 2: artist, 3: likedSongs, 4: podcast, 5: episode
    pub uri: String,
    pub title: String,
    pub subtitle: String,
    pub images: Vec<BackendImage>,
    pub reason: String,
    pub reason_artist: Option<BackendArtist>,
    pub playlist: Option<BackendPlaylistSummary>,
    pub album: Option<BackendAlbum>,
    pub artist: Option<BackendArtist>,
    pub parent_uri: String,
}

#[derive(Clone, Debug)]
pub struct BackendHomeSection {
    pub uri: String,
    pub kind: i32, // 0: shelf, 1: recents, 2: feed
    pub title: String,
    pub subtitle: String,
    pub header_artist: Option<BackendArtist>,
    pub items: Vec<BackendHomeItem>,
    pub total_count: i32,
}

#[derive(Clone, Debug)]
pub struct BackendHomeFeed {
    pub greeting: String,
    pub chips: Vec<BackendHomeChip>,
    pub shortcuts: Vec<BackendHomeItem>,
    pub sections: Vec<BackendHomeSection>,
}

#[derive(Clone, Debug)]
pub struct BackendCatalogPageTrack {
    pub items: Vec<BackendTrack>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct BackendCatalogPageArtist {
    pub items: Vec<BackendArtist>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct BackendCatalogPagePlaylist {
    pub items: Vec<BackendPlaylistSummary>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct BackendCatalogPageAlbum {
    pub items: Vec<BackendAlbum>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct BackendSearchPage {
    pub tracks: BackendCatalogPageTrack,
    pub artists: BackendCatalogPageArtist,
    pub playlists: BackendCatalogPagePlaylist,
}

#[derive(Clone, Debug)]
pub struct BackendCategory {
    pub id: String,
    pub name: String,
    pub icon_url: String,
    pub color_hex: String,
}

#[derive(Clone, Debug)]
pub struct BackendAlbumPage {
    pub album: BackendAlbum,
    pub tracks: Vec<BackendTrack>,
}

#[derive(Clone, Debug)]
pub struct BackendArtistPage {
    pub artist: BackendArtist,
    pub top_tracks: Vec<BackendTrack>,
}

pub(crate) fn id_from_uri(uri: &str) -> String {
    uri.rsplit(':').next().unwrap_or("").to_string()
}

fn unwrap_wrapper(val: &Value) -> Option<&Value> {
    let obj = val.as_object()?;
    if let Some(typename) = obj.get("__typename").and_then(|v| v.as_str()) {
        if typename.ends_with("Wrapper") {
            return obj.get("data");
        }
    }
    Some(val)
}

fn parse_images(sources: Option<&Value>) -> Vec<BackendImage> {
    let Some(arr) = sources.and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(arr.len());
    for item in arr {
        let Some(url) = item.get("url").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) else {
            continue;
        };
        let width = item
            .get("width")
            .or_else(|| item.get("maxWidth"))
            .and_then(|v| v.as_i64())
            .map(|v| v as i32);
        let height = item
            .get("height")
            .or_else(|| item.get("maxHeight"))
            .and_then(|v| v.as_i64())
            .map(|v| v as i32);
        out.push(BackendImage {
            url: url.to_string(),
            width,
            height,
        });
    }
    out.sort_by_key(|a| std::cmp::Reverse(a.width.unwrap_or(0)));
    out
}

fn parse_artist(val: &Value) -> Option<BackendArtist> {
    let m = unwrap_wrapper(val)?;
    let uri = m.get("uri")?.as_str()?;
    let id = m
        .get("id")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| id_from_uri(uri));
    let name = m
        .get("profile")
        .and_then(|p| p.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let images = parse_images(
        m.get("visuals")
            .and_then(|v| v.get("avatarImage"))
            .and_then(|a| a.get("sources")),
    );
    let followers = m
        .get("stats")
        .and_then(|s| s.get("followers"))
        .and_then(|v| v.as_i64());
    Some(BackendArtist {
        id,
        name,
        uri: uri.to_string(),
        images,
        followers,
    })
}

fn parse_album_ref(val: &Value) -> Option<BackendAlbum> {
    let m = unwrap_wrapper(val)?;
    let uri = m.get("uri")?.as_str()?;
    let id = m
        .get("id")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| id_from_uri(uri));
    let name = m
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let images = parse_images(m.get("coverArt").and_then(|c| c.get("sources")));
    let artists = m
        .get("artists")
        .and_then(|a| a.get("items"))
        .and_then(|i| i.as_array())
        .map(|arr| arr.iter().filter_map(parse_artist).collect())
        .unwrap_or_default();
    Some(BackendAlbum {
        id,
        name,
        uri: uri.to_string(),
        album_type: "album".to_string(),
        release_date: String::new(),
        total_tracks: 0,
        images,
        artists,
    })
}

pub fn parse_track(val: &Value) -> Option<BackendTrack> {
    let m = unwrap_wrapper(val)?;
    let uri = m.get("uri")?.as_str()?;
    if !uri.starts_with("spotify:track:") {
        return None;
    }
    let id = m
        .get("id")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| id_from_uri(uri));
    let name = m
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let artists = m
        .get("artists")
        .and_then(|a| a.get("items"))
        .and_then(|i| i.as_array())
        .map(|arr| arr.iter().filter_map(parse_artist).collect())
        .unwrap_or_default();
    let album = m.get("albumOfTrack").and_then(parse_album_ref);
    let duration_ms = m
        .get("duration")
        .and_then(|d| d.get("totalMilliseconds"))
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let explicit = m
        .get("contentRating")
        .and_then(|c| c.get("label"))
        .and_then(|v| v.as_str())
        == Some("EXPLICIT");
    let is_playable = m
        .get("playability")
        .and_then(|p| p.get("playable"))
        .and_then(|v| v.as_bool())
        .unwrap_or(true);
    Some(BackendTrack {
        id,
        name,
        uri: uri.to_string(),
        artists,
        album,
        duration_ms,
        explicit,
        is_playable,
        added_at_ms: None,
    })
}

fn strip_html(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut in_tag = false;
    for ch in input.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out.trim().to_string()
}

fn playlist_images_from_attributes(attributes: &Value) -> Vec<BackendImage> {
    if let Some(sizes) = attributes.get("pictureSize").and_then(|v| v.as_array()) {
        for target in ["large", "default", "small"] {
            for p in sizes {
                if p.get("targetName").and_then(|v| v.as_str()) == Some(target) {
                    if let Some(url) = p.get("url").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                        return vec![BackendImage {
                            url: url.to_string(),
                            width: None,
                            height: None,
                        }];
                    }
                }
            }
        }
    }
    if let Some(picture) = attributes.get("picture").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(picture) {
            if !bytes.is_empty() {
                let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
                return vec![BackendImage {
                    url: format!("https://i.scdn.co/image/{hex}"),
                    width: None,
                    height: None,
                }];
            }
        }
    }
    Vec::new()
}

fn parse_timestamp_ms(val: Option<&Value>) -> Option<i64> {
    let v = val?;
    let ms = v
        .as_i64()
        .or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok()))?;
    if ms <= 0 {
        None
    } else {
        Some(ms)
    }
}

fn extract_page_items(page: &Value) -> (usize, Vec<String>, Vec<(String, i64)>) {
    let items = page
        .get("contents")
        .and_then(|c| c.get("items"))
        .and_then(|i| i.as_array());
    let Some(arr) = items else {
        return (0, Vec::new(), Vec::new());
    };
    let raw_len = arr.len();
    let mut uris = Vec::with_capacity(raw_len);
    let mut timestamps = Vec::new();
    for item in arr {
        let Some(uri) = item.get("uri").and_then(|v| v.as_str()) else {
            continue;
        };
        if !uri.starts_with("spotify:track:") {
            continue;
        }
        uris.push(uri.to_string());
        if let Some(ms) = parse_timestamp_ms(
            item.get("attributes").and_then(|a| a.get("timestamp")),
        ) {
            timestamps.push((uri.to_string(), ms));
        }
    }
    (raw_len, uris, timestamps)
}

/// 并发按 URI 批量补全曲目（Pathfinder `decorateContextTracks`，每批 50 首，有界并发）。
pub async fn fetch_tracks_by_uris(
    uris: Vec<String>,
    decorate_hash: &str,
) -> Result<Vec<BackendTrack>, String> {
    if uris.is_empty() {
        return Ok(Vec::new());
    }
    let sem = Arc::new(Semaphore::new(MAX_CONCURRENCY));
    let mut tasks = Vec::new();
    for chunk in uris.chunks(DECORATE_BATCH_SIZE) {
        let sem = sem.clone();
        let chunk_uris: Vec<String> = chunk.to_vec();
        let hash = decorate_hash.to_string();
        tasks.push(tokio::spawn(async move {
            let _permit = sem.acquire_owned().await.map_err(|e| e.to_string())?;
            let data = spotify_session::pathfinder_query(
                "decorateContextTracks",
                &hash,
                json!({ "uris": chunk_uris }),
            )
            .await?;
            let tracks = data
                .get("tracks")
                .and_then(|v| v.as_array())
                .map(|arr| arr.iter().filter_map(parse_track).collect::<Vec<_>>())
                .unwrap_or_default();
            Ok::<Vec<BackendTrack>, String>(tracks)
        }));
    }

    let results = join_all(tasks).await;
    let mut by_uri: HashMap<String, BackendTrack> = HashMap::with_capacity(uris.len());
    for res in results {
        let batch = res.map_err(|e| format!("join:{e}"))??;
        for t in batch {
            by_uri.insert(t.uri.clone(), t);
        }
    }
    let mut ordered = Vec::with_capacity(uris.len());
    for uri in &uris {
        if let Some(t) = by_uri.get(uri) {
            ordered.push(t.clone());
        }
    }
    Ok(ordered)
}

async fn fetch_playlist_page(
    base: &str,
    playlist_id: &str,
    offset: usize,
) -> Result<(usize, Vec<String>, Vec<(String, i64)>), String> {
    let url = format!(
        "{base}/playlist/v2/playlist/{playlist_id}?decorate=attributes,length,owner&from={offset}&length={PLAYLIST_PAGE_LIMIT}"
    );
    let (st, body) = spotify_session::authorized_request(
        reqwest::Method::GET,
        &url,
        &[("Accept", "application/json")],
        None,
    )
    .await?;
    if st != 200 {
        return Err(format!("http:{st}:playlist page {offset}"));
    }
    let page: Value = serde_json::from_slice(&body)
        .map_err(|e| format!("decode:playlist page {offset}: {e}"))?;
    Ok(extract_page_items(&page))
}

/// 并发拉取完整歌单：第一页获取元信息与总曲目数，剩余分页与 `decorateContextTracks` 均并发执行。
pub async fn fetch_playlist_full(
    spclient_base: &str,
    playlist_id: &str,
    decorate_hash: &str,
) -> Result<Option<BackendPlaylist>, String> {
    let base = spclient_base.trim_end_matches('/');
    let first_url = format!(
        "{base}/playlist/v2/playlist/{playlist_id}?decorate=attributes,length,owner&from=0&length={PLAYLIST_PAGE_LIMIT}"
    );
    let (status, bytes) = spotify_session::authorized_request(
        reqwest::Method::GET,
        &first_url,
        &[("Accept", "application/json")],
        None,
    )
    .await?;
    if status == 404 {
        return Ok(None);
    }
    if status != 200 {
        return Err(format!("http:{status}:playlist/v2"));
    }

    let first_json: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("decode:playlist/v2: {e}"))?;
    let Some(attributes) = first_json.get("attributes").filter(|v| v.is_object()) else {
        return Ok(None);
    };
    let name = attributes
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let description = strip_html(
        attributes
            .get("description")
            .and_then(|v| v.as_str())
            .unwrap_or(""),
    );
    let owner_raw = first_json
        .get("ownerUsername")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let owner_name = if owner_raw.is_empty() || owner_raw == "spotify" {
        "Spotify".to_string()
    } else {
        owner_raw.to_string()
    };
    let images = playlist_images_from_attributes(attributes);

    let (first_len, mut all_uris, first_ts) = extract_page_items(&first_json);
    let total_tracks = first_json
        .get("length")
        .and_then(|v| v.as_i64())
        .map(|v| v as usize)
        .unwrap_or(all_uris.len());

    let mut added_at: HashMap<String, i64> = HashMap::new();
    for (u, ms) in first_ts {
        added_at.entry(u).or_insert(ms);
    }

    if first_len > 0 && first_len < total_tracks {
        if first_len < PLAYLIST_PAGE_LIMIT {
            // 服务端返回短页时按实际条数顺序步进，避免跳过中间偏移。
            let mut offset = first_len;
            while offset < total_tracks {
                let (raw, uris, ts) = fetch_playlist_page(base, playlist_id, offset).await?;
                if raw == 0 {
                    return Err("playlist returned an empty page before its end".into());
                }
                all_uris.extend(uris);
                for (u, ms) in ts {
                    added_at.entry(u).or_insert(ms);
                }
                offset += raw;
            }
        } else {
            let sem = Arc::new(Semaphore::new(MAX_CONCURRENCY));
            let mut page_tasks = Vec::new();
            let mut offset = first_len;
            while offset < total_tracks {
                let sem = sem.clone();
                let base_owned = base.to_string();
                let pid_owned = playlist_id.to_string();
                page_tasks.push(tokio::spawn(async move {
                    let _permit = sem.acquire_owned().await.map_err(|e| e.to_string())?;
                    let (_raw, uris, ts) =
                        fetch_playlist_page(&base_owned, &pid_owned, offset).await?;
                    Ok::<(usize, Vec<String>, Vec<(String, i64)>), String>((offset, uris, ts))
                }));
                offset += PLAYLIST_PAGE_LIMIT;
            }

            type PageSlice = (Vec<String>, Vec<(String, i64)>);
            let mut pages_by_offset: BTreeMap<usize, PageSlice> = BTreeMap::new();
            for res in join_all(page_tasks).await {
                let (off, uris, ts) = res.map_err(|e| format!("join:{e}"))??;
                pages_by_offset.insert(off, (uris, ts));
            }
            for (_off, (uris, ts)) in pages_by_offset {
                all_uris.extend(uris);
                for (u, ms) in ts {
                    added_at.entry(u).or_insert(ms);
                }
            }
        }
    }

    let mut tracks = fetch_tracks_by_uris(all_uris, decorate_hash).await?;
    for track in &mut tracks {
        if let Some(&ms) = added_at.get(&track.uri) {
            track.added_at_ms = Some(ms);
        }
    }

    Ok(Some(BackendPlaylist {
        id: playlist_id.to_string(),
        name,
        uri: format!("spotify:playlist:{playlist_id}"),
        description,
        owner_name,
        images,
        total_tracks: total_tracks as i32,
        tracks,
    }))
}

// ---------------------------------------------------------------------------
// collection/v2/paging Protobuf 编解码（无 500 首上限）
// ---------------------------------------------------------------------------

fn encode_varint(out: &mut Vec<u8>, mut val: u64) {
    loop {
        let mut byte = (val & 0x7F) as u8;
        val >>= 7;
        if val != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if val == 0 {
            break;
        }
    }
}

fn encode_proto_string(out: &mut Vec<u8>, field: u32, s: &str) {
    if s.is_empty() {
        return;
    }
    encode_varint(out, ((field as u64) << 3) | 2);
    encode_varint(out, s.len() as u64);
    out.extend_from_slice(s.as_bytes());
}

fn encode_proto_int32(out: &mut Vec<u8>, field: u32, v: i32) {
    encode_varint(out, (field as u64) << 3);
    encode_varint(out, v as u64);
}

pub fn encode_collection_page_request(
    username: &str,
    set: &str,
    token: &str,
    limit: i32,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(64);
    encode_proto_string(&mut out, 1, username);
    encode_proto_string(&mut out, 2, set);
    encode_proto_string(&mut out, 3, token);
    encode_proto_int32(&mut out, 4, limit);
    out
}

fn read_varint(data: &[u8], pos: &mut usize) -> Option<u64> {
    let mut val = 0u64;
    let mut shift = 0u32;
    while *pos < data.len() && shift < 64 {
        let b = data[*pos];
        *pos += 1;
        val |= ((b & 0x7F) as u64) << shift;
        if (b & 0x80) == 0 {
            return Some(val);
        }
        shift += 7;
    }
    None
}

fn skip_field(data: &[u8], pos: &mut usize, wire_type: u64) -> Option<()> {
    match wire_type {
        0 => {
            read_varint(data, pos)?;
        }
        1 => {
            if *pos + 8 > data.len() {
                return None;
            }
            *pos += 8;
        }
        2 => {
            let len = read_varint(data, pos)? as usize;
            if *pos + len > data.len() {
                return None;
            }
            *pos += len;
        }
        5 => {
            if *pos + 4 > data.len() {
                return None;
            }
            *pos += 4;
        }
        _ => return None,
    }
    Some(())
}

fn decode_collection_item(bytes: &[u8]) -> Option<(String, i64)> {
    let mut pos = 0usize;
    let mut uri = String::new();
    let mut added_at = 0i64;
    let mut removed = false;
    while pos < bytes.len() {
        let Some(tag) = read_varint(bytes, &mut pos) else {
            break;
        };
        let field = tag >> 3;
        let wire = tag & 0x7;
        match (field, wire) {
            (1, 2) => {
                let Some(len) = read_varint(bytes, &mut pos).map(|n| n as usize) else {
                    break;
                };
                if pos + len > bytes.len() {
                    break;
                }
                uri = String::from_utf8_lossy(&bytes[pos..pos + len]).to_string();
                pos += len;
            }
            (2, 0) => {
                added_at = read_varint(bytes, &mut pos).unwrap_or(0) as i64;
            }
            (3, 0) => {
                removed = read_varint(bytes, &mut pos).unwrap_or(0) != 0;
            }
            _ => {
                if skip_field(bytes, &mut pos, wire).is_none() {
                    break;
                }
            }
        }
    }
    if uri.is_empty() || removed {
        None
    } else {
        Some((uri, added_at))
    }
}

pub fn decode_collection_page(data: &[u8]) -> (Vec<(String, i64)>, String) {
    let mut pos = 0usize;
    let mut items = Vec::new();
    let mut next_token = String::new();
    while pos < data.len() {
        let Some(tag) = read_varint(data, &mut pos) else {
            break;
        };
        let field = tag >> 3;
        let wire = tag & 0x7;
        match (field, wire) {
            (1, 2) => {
                let Some(len) = read_varint(data, &mut pos).map(|n| n as usize) else {
                    break;
                };
                if pos + len > data.len() {
                    break;
                }
                if let Some(entry) = decode_collection_item(&data[pos..pos + len]) {
                    items.push(entry);
                }
                pos += len;
            }
            (2, 2) => {
                let Some(len) = read_varint(data, &mut pos).map(|n| n as usize) else {
                    break;
                };
                if pos + len > data.len() {
                    break;
                }
                next_token = String::from_utf8_lossy(&data[pos..pos + len]).to_string();
                pos += len;
            }
            _ => {
                if skip_field(data, &mut pos, wire).is_none() {
                    break;
                }
            }
        }
    }
    (items, next_token)
}

/// 分页读取 `collection/v2/paging`（已过滤 `is_removed` 与非目标类型，按 `added_at` 倒序）。
pub async fn fetch_collection_entries(
    spclient_base: &str,
    username: &str,
    set: &str,
    kind: &str,
    max_pages: usize,
    page_size: i32,
) -> Result<Vec<BackendCollectionEntry>, String> {
    let base = spclient_base.trim_end_matches('/');
    let url = format!("{base}/collection/v2/paging");
    let prefix = format!("spotify:{kind}:");
    let mut all = Vec::new();
    let mut token = String::new();

    for _ in 0..max_pages {
        let req_body = encode_collection_page_request(username, set, &token, page_size);
        let (status, resp_bytes) = spotify_session::authorized_request(
            reqwest::Method::POST,
            &url,
            &[
                ("Content-Type", COLLECTION_CONTENT_TYPE),
                ("Accept", COLLECTION_CONTENT_TYPE),
            ],
            Some(req_body),
        )
        .await?;
        if status != 200 {
            return Err(format!("http:{status}:collection/v2/paging"));
        }
        let (items, next) = decode_collection_page(&resp_bytes);
        for (uri, added_at_sec) in items {
            if uri.starts_with(&prefix) {
                all.push(BackendCollectionEntry {
                    id: id_from_uri(&uri),
                    uri,
                    added_at_sec,
                });
            }
        }
        if next.is_empty() || next == token {
            break;
        }
        token = next;
    }

    all.sort_by_key(|a| std::cmp::Reverse(a.added_at_sec));
    Ok(all)
}

#[derive(Debug, Clone)]
pub struct BackendPlaylistSummary {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub description: String,
    pub owner_name: String,
    pub images: Vec<BackendImage>,
    pub total_tracks: i32,
}

#[derive(Debug, Clone)]
pub struct BackendCreditPerson {
    pub name: String,
    pub roles: Vec<String>,
    pub artist_id: String,
}

#[derive(Debug, Clone)]
pub struct BackendCreditGroup {
    pub name: String,
    pub people: Vec<BackendCreditPerson>,
}

#[derive(Debug, Clone)]
pub struct BackendTrackCredits {
    pub track_name: String,
    pub groups: Vec<BackendCreditGroup>,
    pub sources: Vec<String>,
}

/// 流式/懒加载拉取歌单：
/// 第一页（最多 100 首）装饰完立刻通过 `on_snapshot` 回调发给 UI 渲染，
/// 后续分页并发拉取并分块装饰，每完成一批增量回调一次，直至全量完成。
pub async fn fetch_playlist_stream<F>(
    spclient_base: &str,
    playlist_id: &str,
    decorate_hash: &str,
    mut on_snapshot: F,
) -> Result<Option<BackendPlaylist>, String>
where
    F: FnMut(BackendPlaylist),
{
    let base = spclient_base.trim_end_matches('/');
    let first_url = format!(
        "{base}/playlist/v2/playlist/{playlist_id}?decorate=attributes,length,owner&from=0&length={PLAYLIST_PAGE_LIMIT}"
    );
    let (status, bytes) = spotify_session::authorized_request(
        reqwest::Method::GET,
        &first_url,
        &[("Accept", "application/json")],
        None,
    )
    .await?;
    if status == 404 {
        return Ok(None);
    }
    if status != 200 {
        return Err(format!("http:{status}:playlist/v2"));
    }

    let first_json: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("decode:playlist/v2: {e}"))?;
    let Some(attributes) = first_json.get("attributes").filter(|v| v.is_object()) else {
        return Ok(None);
    };
    let name = attributes
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let description = strip_html(
        attributes
            .get("description")
            .and_then(|v| v.as_str())
            .unwrap_or(""),
    );
    let owner_raw = first_json
        .get("ownerUsername")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let owner_name = if owner_raw.is_empty() || owner_raw == "spotify" {
        "Spotify".to_string()
    } else {
        owner_raw.to_string()
    };
    let images = playlist_images_from_attributes(attributes);

    let (first_len, first_uris, first_ts) = extract_page_items(&first_json);
    let total_tracks = first_json
        .get("length")
        .and_then(|v| v.as_i64())
        .map(|v| v as usize)
        .unwrap_or(first_uris.len());

    let mut added_at: HashMap<String, i64> = HashMap::new();
    for (u, ms) in first_ts {
        added_at.entry(u).or_insert(ms);
    }

    // 1) 第一批（首 100 首）立刻装饰并先吐出，方便 UI 秒开展示。
    let mut loaded_tracks = fetch_tracks_by_uris(first_uris, decorate_hash).await?;
    for track in &mut loaded_tracks {
        if let Some(&ms) = added_at.get(&track.uri) {
            track.added_at_ms = Some(ms);
        }
    }

    let mut snapshot = BackendPlaylist {
        id: playlist_id.to_string(),
        name,
        uri: format!("spotify:playlist:{playlist_id}"),
        description,
        owner_name,
        images,
        total_tracks: total_tracks as i32,
        tracks: loaded_tracks.clone(),
    };
    on_snapshot(snapshot.clone());

    if first_len == 0 || first_len >= total_tracks {
        return Ok(Some(snapshot));
    }

    // 2) 拉取剩余分页 URI 列表
    let mut remaining_uris: Vec<String> = Vec::new();
    if first_len < PLAYLIST_PAGE_LIMIT {
        let mut offset = first_len;
        while offset < total_tracks {
            let (raw, uris, ts) = fetch_playlist_page(base, playlist_id, offset).await?;
            if raw == 0 {
                return Err("playlist returned an empty page before its end".into());
            }
            remaining_uris.extend(uris);
            for (u, ms) in ts {
                added_at.entry(u).or_insert(ms);
            }
            offset += raw;
        }
    } else {
        let sem = Arc::new(Semaphore::new(MAX_CONCURRENCY));
        let mut page_tasks = Vec::new();
        let mut offset = first_len;
        while offset < total_tracks {
            let sem = sem.clone();
            let base_owned = base.to_string();
            let pid_owned = playlist_id.to_string();
            page_tasks.push(tokio::spawn(async move {
                let _permit = sem.acquire_owned().await.map_err(|e| e.to_string())?;
                let (_raw, uris, ts) =
                    fetch_playlist_page(&base_owned, &pid_owned, offset).await?;
                Ok::<(usize, Vec<String>, Vec<(String, i64)>), String>((offset, uris, ts))
            }));
            offset += PLAYLIST_PAGE_LIMIT;
        }
        type PageSlice = (Vec<String>, Vec<(String, i64)>);
        let mut pages_by_offset: BTreeMap<usize, PageSlice> = BTreeMap::new();
        for res in join_all(page_tasks).await {
            let (off, uris, ts) = res.map_err(|e| format!("join:{e}"))??;
            pages_by_offset.insert(off, (uris, ts));
        }
        for (_off, (uris, ts)) in pages_by_offset {
            remaining_uris.extend(uris);
            for (u, ms) in ts {
                added_at.entry(u).or_insert(ms);
            }
        }
    }

    // 3) 分块并发装饰剩余曲目（每块最多 200 首 = 4 批），每完成一块通知 UI 增量追加。
    const STREAM_CHUNK_SIZE: usize = DECORATE_BATCH_SIZE * 4;
    for chunk in remaining_uris.chunks(STREAM_CHUNK_SIZE) {
        let mut batch_tracks = fetch_tracks_by_uris(chunk.to_vec(), decorate_hash).await?;
        for track in &mut batch_tracks {
            if let Some(&ms) = added_at.get(&track.uri) {
                track.added_at_ms = Some(ms);
            }
        }
        snapshot.tracks.extend(batch_tracks);
        on_snapshot(snapshot.clone());
    }

    Ok(Some(snapshot))
}

/// 解析 spclient `playlist/v2/user/{username}/rootlist` JSON。
pub fn parse_rootlist_value(json: &Value) -> Vec<BackendPlaylistSummary> {
    let contents = json.get("contents");
    let items = contents
        .and_then(|c| c.get("items"))
        .and_then(|v| v.as_array())
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let metas = contents
        .and_then(|c| c.get("metaItems"))
        .and_then(|v| v.as_array())
        .map(Vec::as_slice)
        .unwrap_or(&[]);

    let mut result = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let Some(uri) = item.get("uri").and_then(|v| v.as_str()) else {
            continue;
        };
        if !uri.starts_with("spotify:playlist:") {
            continue;
        }
        let meta = metas.get(i);
        let attributes = meta.and_then(|m| m.get("attributes"));
        let owner = meta
            .and_then(|m| m.get("ownerUsername"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let name = attributes
            .and_then(|a| a.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let description = strip_html(
            attributes
                .and_then(|a| a.get("description"))
                .and_then(|v| v.as_str())
                .unwrap_or(""),
        );
        let images = attributes
            .map(playlist_images_from_attributes)
            .unwrap_or_default();
        let total_tracks = meta
            .and_then(|m| m.get("length"))
            .and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok()))
            .unwrap_or(0) as i32;
        result.push(BackendPlaylistSummary {
            id: id_from_uri(uri),
            name,
            uri: uri.to_string(),
            description,
            owner_name: owner,
            images,
            total_tracks,
        });
    }
    result
}

pub async fn fetch_rootlist(
    spclient_base: &str,
    username: &str,
) -> Result<Vec<BackendPlaylistSummary>, String> {
    let base = spclient_base.trim_end_matches('/');
    let url = format!("{base}/playlist/v2/user/{username}/rootlist?decorate=attributes,length,owner");
    let (status, bytes) = spotify_session::authorized_request(
        reqwest::Method::GET,
        &url,
        &[("Accept", "application/json")],
        None,
    )
    .await?;
    if status != 200 {
        return Err(format!("http:{status}:rootlist"));
    }
    let val: Value = serde_json::from_slice(&bytes).map_err(|e| format!("decode:rootlist: {e}"))?;
    Ok(parse_rootlist_value(&val))
}

/// 解析 `queryTrackCreditsGroupedModal` JSON。
pub fn parse_credits_value(data: &Value) -> Option<BackendTrackCredits> {
    let track = data
        .get("trackUnion")
        .or_else(|| data.get("data").and_then(|d| d.get("trackUnion")))?;
    if !track.is_object() {
        return None;
    }
    let trait_obj = track.get("creditsTrait");
    let items = trait_obj
        .and_then(|t| t.get("contributors"))
        .and_then(|c| c.get("items"))
        .and_then(|v| v.as_array());

    // 保持分组首次出现顺序与组内人员顺序
    let mut group_order: Vec<String> = Vec::new();
    let mut group_people: HashMap<String, Vec<BackendCreditPerson>> = HashMap::new();

    if let Some(arr) = items {
        for item in arr {
            let Some(name) = item.get("name").and_then(|v| v.as_str()).map(str::trim) else {
                continue;
            };
            if name.is_empty() {
                continue;
            }
            let group = item
                .get("roleGroup")
                .and_then(|rg| rg.get("name"))
                .and_then(|v| v.as_str())
                .map(str::trim)
                .unwrap_or("")
                .to_string();
            let role = item
                .get("role")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .unwrap_or("")
                .to_string();
            let uri = item.get("uri").and_then(|v| v.as_str()).unwrap_or("");
            let artist_id = uri
                .strip_prefix("spotify:artist:")
                .unwrap_or("")
                .to_string();

            if !group_people.contains_key(&group) {
                group_order.push(group.clone());
                group_people.insert(group.clone(), Vec::new());
            }
            let people = group_people.get_mut(&group).unwrap();
            let key_matches = |p: &BackendCreditPerson| {
                if !artist_id.is_empty() {
                    p.artist_id == artist_id
                } else {
                    p.name == name
                }
            };
            if let Some(existing) = people.iter_mut().find(|p| key_matches(p)) {
                if !role.is_empty() && !existing.roles.contains(&role) {
                    existing.roles.push(role);
                }
            } else {
                let roles = if role.is_empty() { vec![] } else { vec![role] };
                people.push(BackendCreditPerson {
                    name: name.to_string(),
                    roles,
                    artist_id,
                });
            }
        }
    }

    let groups = group_order
        .into_iter()
        .map(|g| {
            let people = group_people.remove(&g).unwrap_or_default();
            BackendCreditGroup { name: g, people }
        })
        .collect();

    let sources = trait_obj
        .and_then(|t| t.get("sources"))
        .and_then(|s| s.get("items"))
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|s| s.get("name").and_then(|v| v.as_str()).map(str::trim))
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    Some(BackendTrackCredits {
        track_name: track
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        groups,
        sources,
    })
}

pub async fn fetch_track_credits(
    hash: &str,
    track_uri: &str,
) -> Result<Option<BackendTrackCredits>, String> {
    let data = spotify_session::pathfinder_query(
        "queryTrackCreditsGroupedModal",
        hash,
        json!({
            "trackUri": track_uri,
            "contributorsLimit": 100,
            "contributorsOffset": 0
        }),
    )
    .await?;
    Ok(parse_credits_value(&data))
}

// ---------------------------------------------------------------------------
// Pathfinder 页面解析：Home / Browse / Search / Album / Artist
// ---------------------------------------------------------------------------

fn json_int(v: Option<&Value>) -> Option<i32> {
    match v {
        Some(Value::Number(n)) => n.as_i64().map(|x| x as i32),
        Some(Value::String(s)) => s.parse::<i32>().ok(),
        _ => None,
    }
}

fn label_text(v: Option<&Value>) -> String {
    let Some(obj) = v.and_then(|x| x.as_object()) else {
        return String::new();
    };
    obj.get("transformedLabel")
        .or_else(|| obj.get("translatedBaseText"))
        .and_then(|s| s.as_str())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

pub fn parse_album(val: &Value, fallback_artists: Option<&[BackendArtist]>) -> Option<BackendAlbum> {
    let m = unwrap_wrapper(val)?;
    let uri = m.get("uri")?.as_str()?;
    if !uri.starts_with("spotify:album:") {
        return None;
    }
    let id = m
        .get("id")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| id_from_uri(uri));
    let name = m.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let album_type = m
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("album")
        .to_lowercase();
    let date = m.get("date").and_then(|v| v.as_object());
    let release_date = match date.and_then(|d| d.get("isoString")).and_then(|v| v.as_str()) {
        Some(iso) if iso.len() >= 10 => iso[..10].to_string(),
        _ => date
            .and_then(|d| d.get("year"))
            .and_then(|v| v.as_i64())
            .map(|y| y.to_string())
            .unwrap_or_default(),
    };
    let total_tracks = json_int(m.get("tracksV2").and_then(|t| t.get("totalCount")))
        .or_else(|| json_int(m.get("tracks").and_then(|t| t.get("totalCount"))))
        .unwrap_or(0);
    let images = parse_images(m.get("coverArt").and_then(|c| c.get("sources")));
    let mut artists: Vec<BackendArtist> = m
        .get("artists")
        .and_then(|a| a.get("items"))
        .and_then(|i| i.as_array())
        .map(|arr| arr.iter().filter_map(parse_artist).collect())
        .unwrap_or_default();
    if artists.is_empty() {
        if let Some(fb) = fallback_artists {
            artists = fb.to_vec();
        }
    }
    Some(BackendAlbum {
        id,
        name,
        uri: uri.to_string(),
        album_type,
        release_date,
        total_tracks,
        images,
        artists,
    })
}

pub fn parse_playlist_summary(val: &Value) -> Option<BackendPlaylistSummary> {
    let m = unwrap_wrapper(val)?;
    let uri = m.get("uri")?.as_str()?;
    if !uri.starts_with("spotify:playlist:") {
        return None;
    }
    let id = id_from_uri(uri);
    let name = m.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let description = strip_html(
        m.get("description")
            .and_then(|v| v.as_str())
            .unwrap_or(""),
    );
    let owner_name = m
        .get("ownerV2")
        .and_then(unwrap_wrapper)
        .and_then(|o| o.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("Spotify")
        .to_string();
    let images = m
        .get("images")
        .and_then(|i| i.get("items"))
        .and_then(|i| i.as_array())
        .and_then(|arr| arr.first())
        .map(|first| parse_images(first.get("sources")))
        .unwrap_or_default();
    let total_tracks = json_int(m.get("content").and_then(|c| c.get("totalCount"))).unwrap_or(0);
    Some(BackendPlaylistSummary {
        id,
        name,
        uri: uri.to_string(),
        description,
        owner_name,
        images,
        total_tracks,
    })
}

fn parse_track_item(item: &Value, album_override: Option<&BackendAlbum>) -> Option<BackendTrack> {
    let target = item
        .get("track")
        .or_else(|| item.get("item"))
        .unwrap_or(item);
    let mut track = parse_track(target)?;
    if let Some(alb) = album_override {
        track.album = Some(alb.clone());
    }
    Some(track)
}

fn is_liked_songs_uri(uri: &str) -> bool {
    uri == "spotify:collection:tracks"
        || (uri.starts_with("spotify:user:") && uri.ends_with(":collection"))
}

fn parse_home_chip(raw: &Value) -> Option<BackendHomeChip> {
    let m = raw.as_object()?;
    let id = m.get("id").and_then(|v| v.as_str()).filter(|s| !s.is_empty())?;
    let label = label_text(m.get("label"));
    if label.is_empty() {
        return None;
    }
    let sub_chips = m
        .get("subChips")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(parse_home_chip).collect())
        .unwrap_or_default();
    Some(BackendHomeChip {
        id: id.to_string(),
        label,
        sub_chips,
    })
}

fn parse_home_item(raw: &Value) -> Option<BackendHomeItem> {
    let m = raw.as_object()?;
    let content = m.get("content");
    let uri = m
        .get("uri")
        .and_then(|v| v.as_str())
        .or_else(|| content.and_then(|c| c.get("uri")).and_then(|v| v.as_str()))
        .unwrap_or("");
    if is_liked_songs_uri(uri) {
        return Some(BackendHomeItem {
            kind: 3, // likedSongs
            uri: uri.to_string(),
            title: String::new(),
            subtitle: String::new(),
            images: Vec::new(),
            reason: String::new(),
            reason_artist: None,
            playlist: None,
            album: None,
            artist: None,
            parent_uri: String::new(),
        });
    }
    let entity = content.and_then(unwrap_wrapper)?;
    let typename = entity.get("__typename").and_then(|v| v.as_str()).unwrap_or("");
    match typename {
        "Playlist" => {
            let p = parse_playlist_summary(entity)?;
            let subtitle = if !p.description.is_empty() {
                p.description.clone()
            } else {
                p.owner_name.clone()
            };
            Some(BackendHomeItem {
                kind: 0,
                uri: p.uri.clone(),
                title: p.name.clone(),
                subtitle,
                images: p.images.clone(),
                reason: String::new(),
                reason_artist: None,
                playlist: Some(p),
                album: None,
                artist: None,
                parent_uri: String::new(),
            })
        }
        "Album" => {
            let a = parse_album(entity, None)?;
            let subtitle = a
                .artists
                .iter()
                .map(|ar| ar.name.as_str())
                .filter(|n| !n.is_empty())
                .collect::<Vec<_>>()
                .join(", ");
            Some(BackendHomeItem {
                kind: 1,
                uri: a.uri.clone(),
                title: a.name.clone(),
                subtitle,
                images: a.images.clone(),
                reason: String::new(),
                reason_artist: None,
                playlist: None,
                album: Some(a),
                artist: None,
                parent_uri: String::new(),
            })
        }
        "Artist" => {
            let a = parse_artist(entity)?;
            Some(BackendHomeItem {
                kind: 2,
                uri: a.uri.clone(),
                title: a.name.clone(),
                subtitle: String::new(),
                images: a.images.clone(),
                reason: String::new(),
                reason_artist: None,
                playlist: None,
                album: None,
                artist: Some(a),
                parent_uri: String::new(),
            })
        }
        "Podcast" => {
            let e_uri = entity.get("uri").and_then(|v| v.as_str()).filter(|s| !s.is_empty())?;
            Some(BackendHomeItem {
                kind: 4,
                uri: e_uri.to_string(),
                title: entity.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                subtitle: entity
                    .get("publisher")
                    .and_then(|p| p.get("name"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                images: parse_images(entity.get("coverArt").and_then(|c| c.get("sources"))),
                reason: String::new(),
                reason_artist: None,
                playlist: None,
                album: None,
                artist: None,
                parent_uri: String::new(),
            })
        }
        "Episode" => {
            let e_uri = entity.get("uri").and_then(|v| v.as_str()).filter(|s| !s.is_empty())?;
            let show = entity.get("podcastV2").and_then(unwrap_wrapper);
            Some(BackendHomeItem {
                kind: 5,
                uri: e_uri.to_string(),
                title: entity.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                subtitle: show
                    .and_then(|s| s.get("name"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                images: parse_images(entity.get("coverArt").and_then(|c| c.get("sources"))),
                reason: String::new(),
                reason_artist: None,
                playlist: None,
                album: None,
                artist: None,
                parent_uri: show
                    .and_then(|s| s.get("uri"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
            })
        }
        _ => None,
    }
}

fn parse_recent_entity(entity: &Value) -> Option<BackendHomeItem> {
    let data = entity.get("data");
    let uri = entity
        .get("_uri")
        .and_then(|v| v.as_str())
        .or_else(|| data.and_then(|d| d.get("uri")).and_then(|v| v.as_str()))
        .unwrap_or("");
    if uri.is_empty() {
        return None;
    }
    if is_liked_songs_uri(uri) {
        return Some(BackendHomeItem {
            kind: 3,
            uri: uri.to_string(),
            title: String::new(),
            subtitle: String::new(),
            images: Vec::new(),
            reason: String::new(),
            reason_artist: None,
            playlist: None,
            album: None,
            artist: None,
            parent_uri: String::new(),
        });
    }
    let identity = data.and_then(|d| d.get("identityTrait"));
    let name = identity
        .and_then(|i| i.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let description = strip_html(
        identity
            .and_then(|i| i.get("description"))
            .and_then(|v| v.as_str())
            .unwrap_or(""),
    );
    let contributors: Vec<BackendArtist> = identity
        .and_then(|i| i.get("contributors"))
        .and_then(|c| c.get("items"))
        .and_then(|i| i.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|c| {
                    let c_uri = c.get("uri").and_then(|v| v.as_str()).unwrap_or("");
                    let c_name = c.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    if c_name.is_empty() {
                        return None;
                    }
                    Some(BackendArtist {
                        id: id_from_uri(c_uri),
                        name: c_name.to_string(),
                        uri: c_uri.to_string(),
                        images: Vec::new(),
                        followers: None,
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    let cover_sources = data
        .and_then(|d| d.get("visualIdentityTrait"))
        .and_then(|v| v.get("squareCoverImage"))
        .and_then(|s| s.get("image"))
        .and_then(|i| i.get("data"))
        .and_then(|d| d.get("sources"));
    let images = parse_images(cover_sources);
    let id = id_from_uri(uri);
    let byline = contributors
        .iter()
        .map(|c| c.name.as_str())
        .collect::<Vec<_>>()
        .join(", ");

    let kind_str = uri.split(':').nth(1).unwrap_or("");
    match kind_str {
        "playlist" => {
            let owner_name = contributors
                .first()
                .map(|c| c.name.clone())
                .unwrap_or_else(|| "Spotify".to_string());
            let playlist = BackendPlaylistSummary {
                id,
                name: name.clone(),
                uri: uri.to_string(),
                description: description.clone(),
                owner_name,
                images: images.clone(),
                total_tracks: 0,
            };
            Some(BackendHomeItem {
                kind: 0,
                uri: uri.to_string(),
                title: name,
                subtitle: if !description.is_empty() { description } else { byline },
                images,
                reason: String::new(),
                reason_artist: None,
                playlist: Some(playlist),
                album: None,
                artist: None,
                parent_uri: String::new(),
            })
        }
        "album" => {
            let album = BackendAlbum {
                id,
                name: name.clone(),
                uri: uri.to_string(),
                album_type: "album".to_string(),
                release_date: String::new(),
                total_tracks: 0,
                images: images.clone(),
                artists: contributors,
            };
            Some(BackendHomeItem {
                kind: 1,
                uri: uri.to_string(),
                title: name,
                subtitle: byline,
                images,
                reason: String::new(),
                reason_artist: None,
                playlist: None,
                album: Some(album),
                artist: None,
                parent_uri: String::new(),
            })
        }
        "artist" => {
            let artist = BackendArtist {
                id,
                name: name.clone(),
                uri: uri.to_string(),
                images: images.clone(),
                followers: None,
            };
            Some(BackendHomeItem {
                kind: 2,
                uri: uri.to_string(),
                title: name,
                subtitle: String::new(),
                images,
                reason: String::new(),
                reason_artist: None,
                playlist: None,
                album: None,
                artist: Some(artist),
                parent_uri: String::new(),
            })
        }
        "show" => Some(BackendHomeItem {
            kind: 4,
            uri: uri.to_string(),
            title: name,
            subtitle: byline,
            images,
            reason: String::new(),
            reason_artist: None,
            playlist: None,
            album: None,
            artist: None,
            parent_uri: String::new(),
        }),
        "episode" => Some(BackendHomeItem {
            kind: 5,
            uri: uri.to_string(),
            title: name,
            subtitle: byline,
            images,
            reason: String::new(),
            reason_artist: None,
            playlist: None,
            album: None,
            artist: None,
            parent_uri: String::new(),
        }),
        _ => None,
    }
}

/// 解析 Pathfinder `home` 响应为 `BackendHomeFeed`。
pub fn parse_home_feed(data: &Value) -> BackendHomeFeed {
    let Some(home) = data.get("home").and_then(|v| v.as_object()) else {
        return BackendHomeFeed {
            greeting: String::new(),
            chips: Vec::new(),
            shortcuts: Vec::new(),
            sections: Vec::new(),
        };
    };

    let mut shortcuts = Vec::new();
    let mut sections: Vec<BackendHomeSection> = Vec::new();
    let mut feed_idx: Option<usize> = None;

    let raw_sections = home
        .get("sectionContainer")
        .and_then(|c| c.get("sections"))
        .and_then(|s| s.get("items"))
        .and_then(|i| i.as_array());

    if let Some(arr) = raw_sections {
        for section in arr {
            let Some(sec_obj) = section.as_object() else {
                continue;
            };
            let sec_data = sec_obj.get("data").and_then(|v| v.as_object());
            let typename = sec_data
                .and_then(|d| d.get("__typename"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let uri = sec_obj
                .get("uri")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let section_items = sec_obj.get("sectionItems").and_then(|v| v.as_object());
            let raw_items = section_items
                .and_then(|si| si.get("items"))
                .and_then(|i| i.as_array())
                .map(Vec::as_slice)
                .unwrap_or(&[]);

            if typename == "HomeFeedBaselineSectionData" {
                let idx = match feed_idx {
                    Some(i) => i,
                    None => {
                        sections.push(BackendHomeSection {
                            uri: uri.clone(),
                            kind: 2, // feed
                            title: String::new(),
                            subtitle: String::new(),
                            header_artist: None,
                            items: Vec::new(),
                            total_count: 0,
                        });
                        let new_idx = sections.len() - 1;
                        feed_idx = Some(new_idx);
                        new_idx
                    }
                };
                let reason = label_text(sec_data.and_then(|d| d.get("title")));
                let reason_artist = sec_data.and_then(|d| d.get("headerEntity")).and_then(parse_artist);
                for raw_item in raw_items {
                    if let Some(mut item) = parse_home_item(raw_item) {
                        if item.kind == 2 {
                            continue;
                        }
                        item.reason = reason.clone();
                        item.reason_artist = reason_artist.clone();
                        sections[idx].items.push(item);
                    }
                }
                continue;
            }
            feed_idx = None;

            match typename {
                "HomeShortsSectionData" => {
                    let mut list: Vec<BackendHomeItem> =
                        raw_items.iter().filter_map(parse_home_item).take(8).collect();
                    if list.len() < 8 && list.len() % 2 == 1 {
                        list.pop();
                    }
                    shortcuts = list;
                }
                "HomeGenericSectionData" | "HomeRecentlyPlayedSectionData" => {
                    let recents = typename == "HomeRecentlyPlayedSectionData";
                    let items: Vec<BackendHomeItem> = if recents {
                        let mut out = Vec::new();
                        for raw_item in raw_items {
                            if let Some(list) = raw_item.get("content").and_then(unwrap_wrapper) {
                                if let Some(inner_arr) = list
                                    .get("items")
                                    .and_then(|i| i.get("items"))
                                    .and_then(|i| i.as_array())
                                {
                                    for entry in inner_arr {
                                        if let Some(ent) = entry.get("entity") {
                                            if let Some(parsed) = parse_recent_entity(ent) {
                                                out.push(parsed);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        out
                    } else {
                        raw_items.iter().filter_map(parse_home_item).collect()
                    };
                    if items.is_empty() {
                        continue;
                    }
                    let total_count = if recents {
                        items.len() as i32
                    } else {
                        json_int(section_items.and_then(|si| si.get("totalCount")))
                            .unwrap_or(items.len() as i32)
                    };
                    sections.push(BackendHomeSection {
                        uri,
                        kind: if recents { 1 } else { 0 },
                        title: label_text(sec_data.and_then(|d| d.get("title"))),
                        subtitle: label_text(sec_data.and_then(|d| d.get("subtitle"))),
                        header_artist: sec_data
                            .and_then(|d| d.get("headerEntity"))
                            .and_then(parse_artist),
                        items,
                        total_count,
                    });
                }
                _ => {}
            }
        }
    }

    sections.retain(|s| !(s.kind == 2 && s.items.is_empty()));

    let greeting = label_text(home.get("greeting"));
    let chips = home
        .get("homeChips")
        .and_then(|c| c.as_array())
        .map(|arr| arr.iter().filter_map(parse_home_chip).collect())
        .unwrap_or_default();

    BackendHomeFeed {
        greeting,
        chips,
        shortcuts,
        sections,
    }
}

fn find_first_sections_container<'a>(data: &'a Value, depth: usize) -> Option<&'a Value> {
    let map = data.as_object()?;
    for val in map.values() {
        let Some(m) = val.as_object() else {
            continue;
        };
        if m.contains_key("sections") || m.contains_key("sectionContainer") {
            return Some(val);
        }
        if depth > 0 {
            if let Some(nested) = find_first_sections_container(val, depth - 1) {
                return Some(nested);
            }
        }
    }
    None
}

/// 解析 Pathfinder `browsePage` 分类页分区列表。
pub fn parse_browse_sections(data: &Value) -> Vec<BackendHomeSection> {
    let root = data
        .get("browse")
        .or_else(|| data.get("browsePage"))
        .or_else(|| find_first_sections_container(data, 2));
    let Some(root) = root else {
        return Vec::new();
    };
    let sections_map = root
        .get("sectionContainer")
        .and_then(|c| c.get("sections"))
        .or_else(|| root.get("sections"));
    let Some(arr) = sections_map
        .and_then(|s| s.get("items"))
        .and_then(|i| i.as_array())
    else {
        return Vec::new();
    };

    let mut sections = Vec::new();
    for raw in arr {
        let Some(sec_obj) = raw.as_object() else {
            continue;
        };
        let section_items = sec_obj.get("sectionItems");
        let items: Vec<BackendHomeItem> = section_items
            .and_then(|si| si.get("items"))
            .and_then(|i| i.as_array())
            .map(|a| a.iter().filter_map(parse_home_item).collect())
            .unwrap_or_default();
        if items.is_empty() {
            continue;
        }
        let meta = sec_obj.get("data");
        sections.push(BackendHomeSection {
            uri: sec_obj
                .get("uri")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            kind: 0,
            title: label_text(meta.and_then(|m| m.get("title"))),
            subtitle: label_text(meta.and_then(|m| m.get("subtitle"))),
            header_artist: None,
            total_count: json_int(section_items.and_then(|si| si.get("totalCount")))
                .unwrap_or(items.len() as i32),
            items,
        });
    }
    sections
}

/// 解析 Pathfinder `browseAll` 分类列表。
pub fn parse_categories(data: &Value) -> Vec<BackendCategory> {
    let mut result = Vec::new();
    let Some(sections) = data
        .get("browseStart")
        .and_then(|b| b.get("sections"))
        .and_then(|s| s.get("items"))
        .and_then(|i| i.as_array())
    else {
        return result;
    };
    for section in sections {
        let Some(items) = section
            .get("sectionItems")
            .and_then(|si| si.get("items"))
            .and_then(|i| i.as_array())
        else {
            continue;
        };
        for item in items {
            let Some(m) = item.as_object() else {
                continue;
            };
            let card = m
                .get("content")
                .and_then(unwrap_wrapper)
                .and_then(|d| d.get("data"))
                .and_then(|d| d.get("cardRepresentation"))
                .and_then(|c| c.as_object());
            let Some(card) = card else {
                continue;
            };
            let artwork = parse_images(card.get("artwork").and_then(|a| a.get("sources")));
            result.push(BackendCategory {
                id: m.get("uri").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                name: card
                    .get("title")
                    .and_then(|t| t.get("transformedLabel"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                icon_url: artwork.first().map(|i| i.url.clone()).unwrap_or_default(),
                color_hex: card
                    .get("backgroundColor")
                    .and_then(|b| b.get("hex"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
            });
        }
    }
    result
}

fn parse_paging<T>(
    value: Option<&Value>,
    offset: i32,
    limit: i32,
    mut parse_item: impl FnMut(&Value) -> Option<T>,
) -> Result<(Vec<T>, Option<i32>, Option<i32>), String> {
    let page = value
        .and_then(|v| v.as_object())
        .ok_or_else(|| "Missing catalog items".to_string())?;
    let raw_items = page
        .get("items")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "Missing catalog items".to_string())?;
    let raw_count = raw_items.len() as i32;
    let total = json_int(page.get("totalCount"));
    let paging = page
        .get("pagingInfo")
        .or_else(|| page.get("pageInfo"))
        .and_then(|v| v.as_object());
    let next_from_server = json_int(paging.and_then(|p| p.get("nextOffset")));
    if total.is_some_and(|t| t < 0) || next_from_server.is_some_and(|n| n < 0) {
        return Err("Invalid catalog pagination".to_string());
    }
    let has_next_page = paging
        .and_then(|p| p.get("hasNextPage"))
        .and_then(|v| v.as_bool());
    let more = has_next_page.unwrap_or_else(|| {
        next_from_server.is_some()
            || total.map_or(raw_count >= limit, |t| offset + raw_count < t)
    });
    let next_offset = if more {
        let n = next_from_server.unwrap_or(offset + raw_count);
        if n <= offset {
            return Err("Catalog page did not advance".to_string());
        }
        Some(n)
    } else {
        None
    };
    let items = raw_items.iter().filter_map(&mut parse_item).collect();
    Ok((items, total, next_offset))
}

/// 解析 Pathfinder `searchDesktop` 分页结果。
pub fn parse_search_page(
    data: &Value,
    offset: i32,
    limit: i32,
) -> Result<BackendSearchPage, String> {
    let search = data
        .get("searchV2")
        .and_then(|v| v.as_object())
        .ok_or_else(|| "Missing search results".to_string())?;
    let (tracks, t_total, t_next) = parse_paging(search.get("tracksV2"), offset, limit, |i| {
        parse_track_item(i, None)
    })?;
    let (artists, a_total, a_next) =
        parse_paging(search.get("artists"), offset, limit, parse_artist)?;
    let (playlists, p_total, p_next) = parse_paging(
        search.get("playlists"),
        offset,
        limit,
        parse_playlist_summary,
    )?;
    Ok(BackendSearchPage {
        tracks: BackendCatalogPageTrack {
            items: tracks,
            offset,
            total: t_total,
            next_offset: t_next,
        },
        artists: BackendCatalogPageArtist {
            items: artists,
            offset,
            total: a_total,
            next_offset: a_next,
        },
        playlists: BackendCatalogPagePlaylist {
            items: playlists,
            offset,
            total: p_total,
            next_offset: p_next,
        },
    })
}

/// 解析 Pathfinder `getAlbum` 专辑信息与曲目列表。
pub fn parse_album_page(data: &Value) -> Option<BackendAlbumPage> {
    let union = data.get("albumUnion")?;
    let parsed_album = parse_album(union, None)?;
    let tracks = union
        .get("tracksV2")
        .and_then(|t| t.get("items"))
        .and_then(|i| i.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|i| parse_track_item(i, Some(&parsed_album)))
                .collect()
        })
        .unwrap_or_default();
    Some(BackendAlbumPage {
        album: parsed_album,
        tracks,
    })
}

/// 解析 Pathfinder `getAlbum` 分页曲目。
pub fn parse_album_tracks_page(
    data: &Value,
    offset: i32,
    limit: i32,
) -> Result<BackendCatalogPageTrack, String> {
    let union = data
        .get("albumUnion")
        .ok_or_else(|| "Missing album".to_string())?;
    let parsed_album =
        parse_album(union, None).ok_or_else(|| "Missing album".to_string())?;
    let (items, total, next_offset) = parse_paging(union.get("tracksV2"), offset, limit, |i| {
        parse_track_item(i, Some(&parsed_album))
    })?;
    Ok(BackendCatalogPageTrack {
        items,
        offset,
        total,
        next_offset,
    })
}

/// 解析 Pathfinder `queryArtistOverview`。
pub fn parse_artist_overview(data: &Value) -> Option<BackendArtistPage> {
    let union = data.get("artistUnion")?;
    let artist = parse_artist(union)?;
    let top_tracks = union
        .get("discography")
        .and_then(|d| d.get("topTracks"))
        .and_then(|t| t.get("items"))
        .and_then(|i| i.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|i| parse_track_item(i, None))
                .collect()
        })
        .unwrap_or_default();
    Some(BackendArtistPage { artist, top_tracks })
}

/// 解析 Pathfinder `queryArtistDiscographyAll` 分页结果。
pub fn parse_artist_discography_page(
    data: &Value,
    fallback_artist: Option<BackendArtist>,
    offset: i32,
    limit: i32,
) -> Result<BackendCatalogPageAlbum, String> {
    let all = data
        .get("artistUnion")
        .and_then(|u| u.get("discography"))
        .and_then(|d| d.get("all"));
    let fb_slice = fallback_artist.as_ref().map(std::slice::from_ref);
    let (items, total, next_offset) = parse_paging(all, offset, limit, |item| {
        let releases = item
            .get("releases")
            .and_then(|r| r.get("items"))
            .and_then(|i| i.as_array())?;
        let first = releases.first()?;
        parse_album(first, fb_slice)
    })?;
    Ok(BackendCatalogPageAlbum {
        items,
        offset,
        total,
        next_offset,
    })
}

pub async fn fetch_home_feed(
    hash: &str,
    timezone: &str,
    facet: &str,
    section_items_limit: i32,
) -> Result<BackendHomeFeed, String> {
    let mut vars = json!({
        "timeZone": timezone,
        "sp_t": "",
        "facet": facet,
        "sectionItemsLimit": section_items_limit,
    });
    if facet.is_empty() {
        vars.as_object_mut().unwrap().remove("facet");
    }
    let data = spotify_session::pathfinder_query("home", hash, vars).await?;
    Ok(parse_home_feed(&data))
}

pub async fn fetch_browse_categories(hash: &str, timezone: &str) -> Result<Vec<BackendCategory>, String> {
    let data = spotify_session::pathfinder_query(
        "browseAll",
        hash,
        json!({ "timeZone": timezone }),
    )
    .await?;
    Ok(parse_categories(&data))
}

pub async fn fetch_browse_sections(
    hash: &str,
    uri: &str,
    timezone: &str,
) -> Result<Vec<BackendHomeSection>, String> {
    let data = spotify_session::pathfinder_query(
        "browsePage",
        hash,
        json!({
            "uri": uri,
            "timeZone": timezone,
            "sp_t": "",
            "facet": "",
        }),
    )
    .await?;
    Ok(parse_browse_sections(&data))
}

pub async fn fetch_search_page(
    hash: &str,
    term: &str,
    offset: i32,
    limit: i32,
) -> Result<BackendSearchPage, String> {
    let data = spotify_session::pathfinder_query(
        "searchDesktop",
        hash,
        json!({
            "searchTerm": term,
            "offset": offset,
            "limit": limit,
            "numberOfTopResults": 5,
            "includeAudiobooks": false,
            "includeArtistHasConcertsField": false,
            "includePreReleases": false,
            "includeLocalConcertsField": false,
            "includeAuthors": false,
        }),
    )
    .await?;
    parse_search_page(&data, offset, limit)
}

pub async fn fetch_album_page(
    hash: &str,
    album_uri: &str,
    offset: i32,
    limit: i32,
) -> Result<Option<BackendAlbumPage>, String> {
    let data = spotify_session::pathfinder_query(
        "getAlbum",
        hash,
        json!({
            "uri": album_uri,
            "locale": "",
            "offset": offset,
            "limit": limit,
        }),
    )
    .await?;
    Ok(parse_album_page(&data))
}

pub async fn fetch_album_tracks_page(
    hash: &str,
    album_uri: &str,
    offset: i32,
    limit: i32,
) -> Result<BackendCatalogPageTrack, String> {
    let data = spotify_session::pathfinder_query(
        "getAlbum",
        hash,
        json!({
            "uri": album_uri,
            "locale": "",
            "offset": offset,
            "limit": limit,
        }),
    )
    .await?;
    parse_album_tracks_page(&data, offset, limit)
}

pub async fn fetch_artist_overview(
    hash: &str,
    artist_uri: &str,
    locale: &str,
) -> Result<Option<BackendArtistPage>, String> {
    let data = spotify_session::pathfinder_query(
        "queryArtistOverview",
        hash,
        json!({
            "uri": artist_uri,
            "locale": locale,
            "includePrerelease": true,
        }),
    )
    .await?;
    Ok(parse_artist_overview(&data))
}

pub async fn fetch_artist_discography_page(
    hash: &str,
    artist_uri: &str,
    fallback_artist: Option<BackendArtist>,
    offset: i32,
    limit: i32,
) -> Result<BackendCatalogPageAlbum, String> {
    let data = spotify_session::pathfinder_query(
        "queryArtistDiscographyAll",
        hash,
        json!({
            "uri": artist_uri,
            "offset": offset,
            "limit": limit,
            "order": "DATE_DESC",
        }),
    )
    .await?;
    parse_artist_discography_page(&data, fallback_artist, offset, limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collection_protobuf_roundtrip_filters_removed_and_parses_next_token() {
        let mut item1 = Vec::new();
        encode_proto_string(&mut item1, 1, "spotify:track:abc");
        encode_proto_int32(&mut item1, 2, 1_700_000_000);

        let mut item2 = Vec::new();
        encode_proto_string(&mut item2, 1, "spotify:track:removed");
        encode_proto_int32(&mut item2, 2, 1_700_000_100);
        encode_proto_int32(&mut item2, 3, 1);

        let mut page = Vec::new();
        encode_varint(&mut page, (1 << 3) | 2);
        encode_varint(&mut page, item1.len() as u64);
        page.extend_from_slice(&item1);
        encode_varint(&mut page, (1 << 3) | 2);
        encode_varint(&mut page, item2.len() as u64);
        page.extend_from_slice(&item2);
        encode_proto_string(&mut page, 2, "next-cursor-2");

        let (items, next) = decode_collection_page(&page);
        assert_eq!(items, vec![("spotify:track:abc".to_string(), 1_700_000_000)]);
        assert_eq!(next, "next-cursor-2");
    }

    #[test]
    fn parse_track_handles_wrapper_and_unwrapped_objects() {
        let v = json!({
            "__typename": "TrackResponseWrapper",
            "data": {
                "uri": "spotify:track:123",
                "name": "Test Song",
                "duration": { "totalMilliseconds": 210000 },
                "contentRating": { "label": "EXPLICIT" },
                "playability": { "playable": true },
                "artists": {
                    "items": [{
                        "uri": "spotify:artist:ar1",
                        "profile": { "name": "Artist 1" }
                    }]
                },
                "albumOfTrack": {
                    "uri": "spotify:album:al1",
                    "name": "Album 1",
                    "coverArt": { "sources": [{ "url": "https://img/1.jpg", "width": 640, "height": 640 }] }
                }
            }
        });
        let track = parse_track(&v).expect("track parsed");
        assert_eq!(track.id, "123");
        assert_eq!(track.name, "Test Song");
        assert_eq!(track.duration_ms, 210000);
        assert!(track.explicit);
        assert_eq!(track.artists.len(), 1);
        assert_eq!(track.artists[0].name, "Artist 1");
        assert_eq!(track.album.as_ref().unwrap().name, "Album 1");
    }

    #[test]
    fn parse_home_feed_handles_shorts_shelves_and_feed_baseline() {
        let data = json!({
            "home": {
                "greeting": { "transformedLabel": "Good morning" },
                "homeChips": [
                    { "id": "music-chip", "label": { "transformedLabel": "Music" }, "subChips": [] }
                ],
                "sectionContainer": {
                    "sections": {
                        "items": [
                            {
                                "uri": "spotify:section:shorts",
                                "data": { "__typename": "HomeShortsSectionData" },
                                "sectionItems": {
                                    "items": [
                                        { "uri": "spotify:user:me:collection" },
                                        {
                                            "uri": "spotify:playlist:pl1",
                                            "content": {
                                                "__typename": "PlaylistResponseWrapper",
                                                "data": {
                                                    "__typename": "Playlist",
                                                    "uri": "spotify:playlist:pl1",
                                                    "name": "Liked Mix"
                                                }
                                            }
                                        }
                                    ]
                                }
                            },
                            {
                                "uri": "spotify:section:feed1",
                                "data": {
                                    "__typename": "HomeFeedBaselineSectionData",
                                    "title": { "transformedLabel": "For you" }
                                },
                                "sectionItems": {
                                    "items": [
                                        {
                                            "uri": "spotify:album:al1",
                                            "content": {
                                                "__typename": "AlbumResponseWrapper",
                                                "data": {
                                                    "__typename": "Album",
                                                    "uri": "spotify:album:al1",
                                                    "name": "Album 1"
                                                }
                                            }
                                        }
                                    ]
                                }
                            }
                        ]
                    }
                }
            }
        });
        let feed = parse_home_feed(&data);
        assert_eq!(feed.greeting, "Good morning");
        assert_eq!(feed.chips.len(), 1);
        assert_eq!(feed.shortcuts.len(), 2);
        assert_eq!(feed.shortcuts[0].kind, 3); // likedSongs
        assert_eq!(feed.sections.len(), 1);
        assert_eq!(feed.sections[0].kind, 2); // feed
        assert_eq!(feed.sections[0].items[0].reason, "For you");
    }

    #[test]
    fn parse_search_page_and_album_page_works() {
        let search_data = json!({
            "searchV2": {
                "tracksV2": { "totalCount": 1, "items": [{ "item": { "uri": "spotify:track:t1", "name": "T1" } }] },
                "artists": { "totalCount": 0, "items": [] },
                "playlists": { "totalCount": 0, "items": [] }
            }
        });
        let page = parse_search_page(&search_data, 0, 20).unwrap();
        assert_eq!(page.tracks.items.len(), 1);
        assert_eq!(page.tracks.items[0].id, "t1");
        assert_eq!(page.tracks.next_offset, None);

        let album_data = json!({
            "albumUnion": {
                "uri": "spotify:album:a1",
                "name": "Album One",
                "type": "ALBUM",
                "date": { "isoString": "2026-05-01T00:00:00Z" },
                "tracksV2": {
                    "totalCount": 1,
                    "items": [{ "track": { "uri": "spotify:track:t2", "name": "T2" } }]
                }
            }
        });
        let alb = parse_album_page(&album_data).unwrap();
        assert_eq!(alb.album.name, "Album One");
        assert_eq!(alb.album.release_date, "2026-05-01");
        assert_eq!(alb.tracks.len(), 1);
        assert_eq!(alb.tracks[0].album.as_ref().unwrap().id, "a1");
    }
}
