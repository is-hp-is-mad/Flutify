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
    pub images: Vec<BackendImage>,
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

fn id_from_uri(uri: &str) -> String {
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
    out.sort_by(|a, b| b.width.unwrap_or(0).cmp(&a.width.unwrap_or(0)));
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
    Some(BackendAlbum {
        id,
        name,
        uri: uri.to_string(),
        images,
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
    let (st, body) =
        spotify_session::authorized_request(reqwest::Method::GET, &url, &[], None).await?;
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
    let (status, bytes) =
        spotify_session::authorized_request(reqwest::Method::GET, &first_url, &[], None).await?;
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

            let mut pages_by_offset: BTreeMap<usize, (Vec<String>, Vec<(String, i64)>)> =
                BTreeMap::new();
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
    encode_varint(out, ((field as u64) << 3) | 0);
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

    all.sort_by(|a, b| b.added_at_sec.cmp(&a.added_at_sec));
    Ok(all)
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
}
