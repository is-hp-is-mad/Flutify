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
pub struct BackendCategory {
    pub id: String,
    pub name: String,
    pub icon_url: String,
    pub color_hex: String,
}

pub(crate) fn id_from_uri(uri: &str) -> String {
    uri.rsplit(':').next().unwrap_or("").to_string()
}

/// 解开 `{__typename: XxxResponseWrapper | XxxWrapper, data: {...}}` 包装；非包装对象原样返回。
pub(crate) fn unwrap_wrapper(val: &Value) -> Option<&Value> {
    let obj = val.as_object()?;
    if let Some(typename) = obj.get("__typename").and_then(|v| v.as_str()) {
        if typename.ends_with("Wrapper") {
            return json_map(obj.get("data"));
        }
    }
    Some(val)
}

/// Dart `x as String? ?? ''` 的对应：非字符串（含 null / 缺失）一律视为缺失。
pub(crate) fn json_str(v: Option<&Value>) -> Option<&str> {
    v.and_then(Value::as_str)
}

/// Dart `a ?? b` 的对应：JSON null 与缺失等价。
fn non_null(v: Option<&Value>) -> Option<&Value> {
    v.filter(|x| !x.is_null())
}

/// Dart `v is Map<String, dynamic> ? v : null`。
fn json_map(v: Option<&Value>) -> Option<&Value> {
    v.filter(|x| x.is_object())
}

/// Dart `int.tryParse`：允许首尾空白、正负号与 `0x` 前缀。
pub(crate) fn dart_int_parse(s: &str) -> Option<i64> {
    let t = s.trim();
    let (neg, body) = match t.as_bytes().first() {
        Some(b'-') => (true, &t[1..]),
        Some(b'+') => (false, &t[1..]),
        _ => (false, t),
    };
    if body.is_empty() {
        return None;
    }
    let magnitude = if let Some(hex) = body.strip_prefix("0x").or_else(|| body.strip_prefix("0X")) {
        if hex.is_empty() || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        i128::from_str_radix(hex, 16).ok()?
    } else {
        if !body.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        body.parse::<i128>().ok()?
    };
    let value = if neg { -magnitude } else { magnitude };
    i64::try_from(value).ok()
}

/// `PathfinderParsers._int`：数字取整，字符串按 `int.tryParse`。
pub(crate) fn dart_int(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::String(s) => dart_int_parse(s),
        other => dart_num_int(Some(other)),
    }
}

/// `HomeParser._int`：只认数字（字符串视为缺失）。
pub(crate) fn dart_num_int(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f.trunc() as i64)),
        _ => None,
    }
}

/// Dart 字符串插值 `'${v ?? ''}'` 的对应（只覆盖 JSON 标量）。
fn dart_display(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Number(n)) => {
            if n.is_f64() {
                let f = n.as_f64().unwrap_or_default();
                if f.fract() == 0.0 && f.is_finite() {
                    format!("{f:.1}")
                } else {
                    f.to_string()
                }
            } else {
                n.to_string()
            }
        }
        Some(other) => other.to_string(),
    }
}

/// 图片 sources：[{url, width|maxWidth, height|maxHeight}]，按宽度从大到小排列。
pub(crate) fn parse_images(sources: Option<&Value>) -> Vec<BackendImage> {
    let Some(arr) = sources.and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(arr.len());
    for item in arr {
        let Some(url) = json_str(item.get("url")).filter(|s| !s.is_empty()) else {
            continue;
        };
        let width = dart_int(item.get("width")).or_else(|| dart_int(item.get("maxWidth")));
        let height = dart_int(item.get("height")).or_else(|| dart_int(item.get("maxHeight")));
        out.push(BackendImage {
            url: url.to_string(),
            width: width.map(|v| v as i32),
            height: height.map(|v| v as i32),
        });
    }
    // 稳定排序，与 Dart 小列表的插入排序一致
    out.sort_by_key(|a| std::cmp::Reverse(a.width.unwrap_or(0)));
    out
}

fn entity_id(m: &Value, uri: &str) -> String {
    json_str(m.get("id"))
        .map(str::to_string)
        .unwrap_or_else(|| id_from_uri(uri))
}

fn parse_artist_list(page: Option<&Value>) -> Vec<BackendArtist> {
    page.and_then(|p| p.get("items"))
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_artist).collect())
        .unwrap_or_default()
}

/// Artist（精简：profile.name + uri，可带 visuals.avatarImage 与 stats）。
pub(crate) fn parse_artist(val: &Value) -> Option<BackendArtist> {
    let m = unwrap_wrapper(val)?;
    let uri = json_str(m.get("uri"))?;
    let name = json_str(m.get("profile").and_then(|p| p.get("name")))
        .unwrap_or("")
        .to_string();
    let images = parse_images(
        m.get("visuals")
            .and_then(|v| v.get("avatarImage"))
            .and_then(|a| a.get("sources")),
    );
    let followers = dart_int(m.get("stats").and_then(|s| s.get("followers")));
    Some(BackendArtist {
        id: entity_id(m, uri),
        name,
        uri: uri.to_string(),
        images,
        followers,
    })
}

/// 曲目所属专辑的引用（`albumOfTrack`，不解包装、uri 可缺失；只有名称、封面与艺人）。
fn parse_album_ref(val: &Value) -> Option<BackendAlbum> {
    let m = json_map(Some(val))?;
    let uri = json_str(m.get("uri")).unwrap_or("");
    Some(BackendAlbum {
        id: entity_id(m, uri),
        name: json_str(m.get("name")).unwrap_or("").to_string(),
        uri: uri.to_string(),
        album_type: "album".to_string(),
        release_date: String::new(),
        total_tracks: 0,
        images: parse_images(m.get("coverArt").and_then(|c| c.get("sources"))),
        artists: parse_artist_list(m.get("artists")),
    })
}

/// Track（decorateContextTracks / 搜索 / 专辑曲目 / 艺人热门曲目共用）。
pub fn parse_track(val: &Value) -> Option<BackendTrack> {
    let m = unwrap_wrapper(val)?;
    let uri = json_str(m.get("uri"))?;
    if !uri.starts_with("spotify:track:") {
        return None;
    }
    let album = m.get("albumOfTrack").and_then(parse_album_ref);
    let duration_ms = dart_int(m.get("duration").and_then(|d| d.get("totalMilliseconds")))
        .unwrap_or(0) as i32;
    let explicit = json_str(m.get("contentRating").and_then(|c| c.get("label"))) == Some("EXPLICIT");
    let is_playable = m
        .get("playability")
        .and_then(|p| p.get("playable"))
        .and_then(Value::as_bool)
        .unwrap_or(true);
    Some(BackendTrack {
        id: entity_id(m, uri),
        name: json_str(m.get("name")).unwrap_or("").to_string(),
        uri: uri.to_string(),
        artists: parse_artist_list(m.get("artists")),
        album,
        duration_ms,
        explicit,
        is_playable,
        added_at_ms: None,
    })
}

/// 与 Dart `PathfinderParsers.stripHtml` 一致：去掉 `<...>` 标签（未闭合的 `<` 保留），
/// 依次还原 `&amp;` `&quot;` `&#x27;` `&#39;`，再去首尾空白。
pub(crate) fn strip_html(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(lt) = rest.find('<') {
        let after = &rest[lt + 1..];
        match after.find('>') {
            Some(gt) => {
                out.push_str(&rest[..lt]);
                rest = &after[gt + 1..];
            }
            None => break,
        }
    }
    out.push_str(rest);
    out.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#x27;", "'")
        .replace("&#39;", "'")
        .trim()
        .to_string()
}

/// 与 Dart `PlaylistCover.fromAttributes` 一致：pictureSize large → default → small，
/// 其次 `picture`（Base64 / URL-safe Base64 图片 ID，补齐填充后解码）。
pub(crate) fn playlist_images_from_attributes(attributes: &Value) -> Vec<BackendImage> {
    if let Some(sizes) = attributes.get("pictureSize").and_then(|v| v.as_array()) {
        for target in ["large", "default", "small"] {
            for p in sizes.iter().filter(|p| p.is_object()) {
                if json_str(p.get("targetName")) == Some(target) {
                    if let Some(url) = json_str(p.get("url")).filter(|s| !s.is_empty()) {
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
    if let Some(picture) = json_str(attributes.get("picture")).filter(|s| !s.is_empty()) {
        let normalized = picture.replace('-', "+").replace('_', "/");
        let engine = base64::engine::GeneralPurpose::new(
            &base64::alphabet::STANDARD,
            base64::engine::GeneralPurposeConfig::new()
                .with_decode_padding_mode(base64::engine::DecodePaddingMode::Indifferent)
                .with_decode_allow_trailing_bits(true),
        );
        if let Ok(bytes) = engine.decode(normalized) {
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

/// 毫秒时间戳（整数或字符串）；不合理的值（≤ 0）视为缺失。
fn parse_timestamp_ms(val: Option<&Value>) -> Option<i64> {
    let ms = match val? {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => dart_int_parse(s),
        _ => None,
    }?;
    (ms > 0).then_some(ms)
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

fn read_len_slice<'a>(data: &'a [u8], pos: &mut usize) -> Option<&'a [u8]> {
    let raw = read_varint(data, pos)?;
    let len = usize::try_from(raw).ok()?;
    let end = pos.checked_add(len)?;
    if end > data.len() {
        return None;
    }
    let slice = &data[*pos..end];
    *pos = end;
    Some(slice)
}

fn skip_field(data: &[u8], pos: &mut usize, wire: u64) -> Option<()> {
    match wire {
        0 => {
            read_varint(data, pos)?;
        }
        1 => {
            let end = pos.checked_add(8)?;
            if end > data.len() {
                return None;
            }
            *pos = end;
        }
        2 => {
            read_len_slice(data, pos)?;
        }
        5 => {
            let end = pos.checked_add(4)?;
            if end > data.len() {
                return None;
            }
            *pos = end;
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
                let Some(slice) = read_len_slice(bytes, &mut pos) else {
                    break;
                };
                uri = String::from_utf8_lossy(slice).to_string();
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
                let Some(slice) = read_len_slice(data, &mut pos) else {
                    break;
                };
                if let Some(entry) = decode_collection_item(slice) {
                    items.push(entry);
                }
            }
            (2, 2) => {
                let Some(slice) = read_len_slice(data, &mut pos) else {
                    break;
                };
                next_token = String::from_utf8_lossy(slice).to_string();
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
// Pathfinder 页面解析：Home / Browse / Search / Album / Artist / Library
//
// 与 Dart 端 `PathfinderParsers` / `HomeParser` 逐字段对齐（字段缺失一律宽松处理，
// 单个条目解析失败只跳过该条目）；分页协议错误以 `format:` 前缀返回，Dart 侧还原为 FormatException。
// ---------------------------------------------------------------------------

/// `{transformedLabel, translatedBaseText}` → 本地化后的文本（与 Dart `HomeParser._label` 一致）。
fn label_text(v: Option<&Value>) -> String {
    let Some(obj) = json_map(v) else {
        return String::new();
    };
    non_null(obj.get("transformedLabel"))
        .or_else(|| non_null(obj.get("translatedBaseText")))
        .and_then(Value::as_str)
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

/// Dart `iso.substring(0, 10)`（按字符截取，避免非 ASCII 时按字节切片 panic）。
fn first_chars(s: &str, n: usize) -> Option<String> {
    let mut it = s.char_indices();
    let end = match it.nth(n) {
        Some((idx, _)) => idx,
        None if s.chars().count() == n => s.len(),
        None => return None,
    };
    Some(s[..end].to_string())
}

/// Album（getAlbum 的 albumUnion、搜索结果、唱片目录的 release 共用）。
pub fn parse_album(val: &Value, fallback_artists: Option<&[BackendArtist]>) -> Option<BackendAlbum> {
    let m = unwrap_wrapper(val)?;
    let uri = json_str(m.get("uri"))?;
    if !uri.starts_with("spotify:album:") {
        return None;
    }
    let album_type = json_str(m.get("type")).unwrap_or("album").to_lowercase();
    let date = json_map(m.get("date"));
    let release_date = match json_str(date.and_then(|d| d.get("isoString"))).and_then(|iso| first_chars(iso, 10)) {
        Some(day) => day,
        None => dart_display(date.and_then(|d| d.get("year"))),
    };
    let total_tracks = dart_int(m.get("tracksV2").and_then(|t| t.get("totalCount")))
        .or_else(|| dart_int(m.get("tracks").and_then(|t| t.get("totalCount"))))
        .unwrap_or(0) as i32;
    let mut artists = parse_artist_list(m.get("artists"));
    if artists.is_empty() {
        if let Some(fb) = fallback_artists {
            artists = fb.to_vec();
        }
    }
    Some(BackendAlbum {
        id: entity_id(m, uri),
        name: json_str(m.get("name")).unwrap_or("").to_string(),
        uri: uri.to_string(),
        album_type,
        release_date,
        total_tracks,
        images: parse_images(m.get("coverArt").and_then(|c| c.get("sources"))),
        artists,
    })
}

/// Playlist（home 卡片、搜索结果）。
pub fn parse_playlist_summary(val: &Value) -> Option<BackendPlaylistSummary> {
    let m = unwrap_wrapper(val)?;
    let uri = json_str(m.get("uri"))?;
    if !uri.starts_with("spotify:playlist:") {
        return None;
    }
    let owner_name = m
        .get("ownerV2")
        .and_then(unwrap_wrapper)
        .and_then(|o| json_str(o.get("name")))
        .unwrap_or("Spotify")
        .to_string();
    let images = m
        .get("images")
        .and_then(|i| i.get("items"))
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .map(|first| parse_images(json_map(Some(first)).and_then(|f| f.get("sources"))))
        .unwrap_or_default();
    Some(BackendPlaylistSummary {
        id: id_from_uri(uri),
        name: json_str(m.get("name")).unwrap_or("").to_string(),
        uri: uri.to_string(),
        description: strip_html(json_str(m.get("description")).unwrap_or("")),
        owner_name,
        images,
        total_tracks: dart_int(m.get("content").and_then(|c| c.get("totalCount"))).unwrap_or(0) as i32,
    })
}

/// 曲目列表中的 `{track: {...}}` / `{item: {...}}` / 直接的 Track；[album_override] 用于专辑页回填。
fn parse_track_item(item: &Value, album_override: Option<&BackendAlbum>) -> Option<BackendTrack> {
    let m = json_map(Some(item))?;
    let target = non_null(m.get("track"))
        .or_else(|| non_null(m.get("item")))
        .unwrap_or(m);
    let mut track = parse_track(target)?;
    if let Some(alb) = album_override {
        track.album = Some(alb.clone());
    }
    Some(track)
}

/// 「已点赞的歌曲」的两种写法：快捷入口 `spotify:user:{用户名}:collection`，最近播放 `spotify:collection:tracks`。
fn is_liked_songs_uri(uri: &str) -> bool {
    uri == "spotify:collection:tracks"
        || (uri.starts_with("spotify:user:") && uri.ends_with(":collection"))
}

fn parse_home_chip(raw: &Value) -> Option<BackendHomeChip> {
    let m = raw.as_object()?;
    let id = json_str(m.get("id")).filter(|s| !s.is_empty())?;
    let label = label_text(m.get("label"));
    if label.is_empty() {
        return None;
    }
    let sub_chips = m
        .get("subChips")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_home_chip).collect())
        .unwrap_or_default();
    Some(BackendHomeChip {
        id: id.to_string(),
        label,
        sub_chips,
    })
}

fn home_item(kind: i32, uri: &str, title: String) -> BackendHomeItem {
    BackendHomeItem {
        kind,
        uri: uri.to_string(),
        title,
        subtitle: String::new(),
        images: Vec::new(),
        reason: String::new(),
        reason_artist: None,
        playlist: None,
        album: None,
        artist: None,
        parent_uri: String::new(),
    }
}

/// 播客 / 单集卡片（与 Dart `HomeParser._media` 一致：uri 必须非空）。
fn home_media(kind: i32, m: &Value, subtitle: Option<&str>, parent_uri: Option<&str>) -> Option<BackendHomeItem> {
    let uri = json_str(m.get("uri")).filter(|s| !s.is_empty())?;
    let mut item = home_item(kind, uri, json_str(m.get("name")).unwrap_or("").to_string());
    item.subtitle = subtitle.unwrap_or("").to_string();
    item.images = parse_images(m.get("coverArt").and_then(|c| c.get("sources")));
    item.parent_uri = parent_uri.unwrap_or("").to_string();
    Some(item)
}

/// 分区条目 `{uri, content: {__typename: XxxResponseWrapper | UnknownType, data}}`。
fn parse_home_item(raw: &Value) -> Option<BackendHomeItem> {
    let m = raw.as_object()?;
    let content = json_map(m.get("content"));
    let uri = json_str(m.get("uri"))
        .or_else(|| json_str(content.and_then(|c| c.get("uri"))))
        .unwrap_or("");
    if is_liked_songs_uri(uri) {
        return Some(home_item(3, uri, String::new()));
    }
    let entity = content.and_then(unwrap_wrapper)?;
    match json_str(entity.get("__typename")).unwrap_or("") {
        "Playlist" => {
            let p = parse_playlist_summary(entity)?;
            let mut item = home_item(0, &p.uri, p.name.clone());
            item.subtitle = if !p.description.is_empty() {
                p.description.clone()
            } else {
                p.owner_name.clone()
            };
            item.images = p.images.clone();
            item.playlist = Some(p);
            Some(item)
        }
        "Album" => {
            let a = parse_album(entity, None)?;
            let mut item = home_item(1, &a.uri, a.name.clone());
            // SpotifyAlbum.artistNames：空名字也参与拼接
            item.subtitle = a
                .artists
                .iter()
                .map(|ar| ar.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            item.images = a.images.clone();
            item.album = Some(a);
            Some(item)
        }
        "Artist" => {
            let a = parse_artist(entity)?;
            let mut item = home_item(2, &a.uri, a.name.clone());
            item.images = a.images.clone();
            item.artist = Some(a);
            Some(item)
        }
        "Podcast" => home_media(
            4,
            entity,
            json_str(json_map(entity.get("publisher")).and_then(|p| p.get("name"))),
            None,
        ),
        "Episode" => {
            let show = entity.get("podcastV2").and_then(unwrap_wrapper);
            home_media(
                5,
                entity,
                json_str(show.and_then(|s| s.get("name"))),
                json_str(show.and_then(|s| s.get("uri"))),
            )
        }
        _ => None,
    }
}

/// 最近播放条目（trait 结构：identityTrait 名称 / 描述 / 作者，visualIdentityTrait 封面）。
fn parse_recent_entity(entity: Option<&Value>) -> Option<BackendHomeItem> {
    let entity = json_map(entity)?;
    let data = json_map(entity.get("data"));
    let uri = json_str(entity.get("_uri"))
        .or_else(|| json_str(data.and_then(|d| d.get("uri"))))
        .unwrap_or("");
    if uri.is_empty() {
        return None;
    }
    if is_liked_songs_uri(uri) {
        return Some(home_item(3, uri, String::new()));
    }
    let identity = json_map(data.and_then(|d| d.get("identityTrait")));
    let name = json_str(identity.and_then(|i| i.get("name"))).unwrap_or("").to_string();
    let description = strip_html(json_str(identity.and_then(|i| i.get("description"))).unwrap_or(""));
    let contributors: Vec<BackendArtist> = json_map(identity.and_then(|i| i.get("contributors")))
        .and_then(|c| c.get("items"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter(|c| c.is_object())
                .filter_map(|c| {
                    let c_uri = json_str(c.get("uri")).unwrap_or("");
                    let c_name = json_str(c.get("name")).unwrap_or("");
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
    let cover = json_map(
        json_map(data.and_then(|d| d.get("visualIdentityTrait"))).and_then(|v| v.get("squareCoverImage")),
    );
    let images = parse_images(
        json_map(json_map(cover.and_then(|c| c.get("image"))).and_then(|i| i.get("data")))
            .and_then(|d| d.get("sources")),
    );
    let id = id_from_uri(uri);
    let byline = contributors
        .iter()
        .map(|c| c.name.as_str())
        .collect::<Vec<_>>()
        .join(", ");

    match uri.split(':').nth(1).unwrap_or("") {
        "playlist" => {
            let owner_name = contributors
                .first()
                .map(|c| c.name.clone())
                .unwrap_or_else(|| "Spotify".to_string());
            let mut item = home_item(0, uri, name.clone());
            item.subtitle = if !description.is_empty() {
                description.clone()
            } else {
                byline
            };
            item.images = images.clone();
            item.playlist = Some(BackendPlaylistSummary {
                id,
                name,
                uri: uri.to_string(),
                description,
                owner_name,
                images,
                total_tracks: 0,
            });
            Some(item)
        }
        "album" => {
            let mut item = home_item(1, uri, name.clone());
            item.subtitle = byline;
            item.images = images.clone();
            item.album = Some(BackendAlbum {
                id,
                name,
                uri: uri.to_string(),
                album_type: "album".to_string(),
                release_date: String::new(),
                total_tracks: 0,
                images,
                artists: contributors,
            });
            Some(item)
        }
        "artist" => {
            let mut item = home_item(2, uri, name.clone());
            item.images = images.clone();
            item.artist = Some(BackendArtist {
                id,
                name,
                uri: uri.to_string(),
                images,
                followers: None,
            });
            Some(item)
        }
        "show" | "episode" => {
            let kind = if uri.split(':').nth(1) == Some("show") { 4 } else { 5 };
            let mut item = home_item(kind, uri, name);
            item.subtitle = byline;
            item.images = images;
            Some(item)
        }
        _ => None,
    }
}

/// 快捷入口最多显示的数量（官方：最多 8 个，不足 8 个且为奇数时去掉最后一个凑成整行）。
const MAX_SHORTCUTS: usize = 8;

fn section_items(section: &Value) -> (Option<&Value>, &[Value]) {
    let items = json_map(section.get("sectionItems"));
    let raw = items
        .and_then(|si| si.get("items"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    (items, raw)
}

/// 解析 Pathfinder `home` 响应（与 Dart `HomeParser.parse` 一致）。
pub fn parse_home_feed(data: &Value) -> BackendHomeFeed {
    let Some(home) = json_map(data.get("home")) else {
        return BackendHomeFeed {
            greeting: String::new(),
            chips: Vec::new(),
            shortcuts: Vec::new(),
            sections: Vec::new(),
        };
    };

    let mut shortcuts = Vec::new();
    let mut sections: Vec<BackendHomeSection> = Vec::new();
    // 正在累积的推荐流（遇到非 FeedBaseline 分区即结束）
    let mut feed_idx: Option<usize> = None;

    let raw_sections = json_map(json_map(home.get("sectionContainer")).and_then(|c| c.get("sections")))
        .and_then(|s| s.get("items"))
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);

    for section in raw_sections.iter().filter(|s| s.is_object()) {
        let sec_data = json_map(section.get("data"));
        let typename = json_str(sec_data.and_then(|d| d.get("__typename"))).unwrap_or("");
        let uri = json_str(section.get("uri")).unwrap_or("").to_string();
        let (items_map, raw_items) = section_items(section);

        if typename == "HomeFeedBaselineSectionData" {
            let idx = *feed_idx.get_or_insert_with(|| {
                sections.push(BackendHomeSection {
                    uri: uri.clone(),
                    kind: 2,
                    title: String::new(),
                    subtitle: String::new(),
                    header_artist: None,
                    items: Vec::new(),
                    total_count: 0,
                });
                sections.len() - 1
            });
            let reason = label_text(sec_data.and_then(|d| d.get("title")));
            let reason_artist = sec_data.and_then(|d| d.get("headerEntity")).and_then(parse_artist);
            for mut item in raw_items.iter().filter_map(parse_home_item) {
                if item.kind == 2 {
                    continue; // 官方推荐流只展示专辑 / 歌单 / 单集
                }
                item.reason = reason.clone();
                item.reason_artist = reason_artist.clone();
                sections[idx].items.push(item);
            }
            continue;
        }
        feed_idx = None;

        match typename {
            "HomeShortsSectionData" => {
                let mut list: Vec<BackendHomeItem> =
                    raw_items.iter().filter_map(parse_home_item).take(MAX_SHORTCUTS).collect();
                if list.len() < MAX_SHORTCUTS && list.len() % 2 == 1 {
                    list.pop();
                }
                shortcuts = list;
            }
            "HomeGenericSectionData" | "HomeRecentlyPlayedSectionData" => {
                let recents = typename == "HomeRecentlyPlayedSectionData";
                let items: Vec<BackendHomeItem> = if recents {
                    let mut out = Vec::new();
                    for raw_item in raw_items {
                        let list = json_map(Some(raw_item))
                            .and_then(|r| json_map(r.get("content")))
                            .and_then(unwrap_wrapper);
                        let entries = json_map(list.and_then(|l| l.get("items")))
                            .and_then(|i| i.get("items"))
                            .and_then(Value::as_array);
                        for entry in entries.into_iter().flatten() {
                            if let Some(parsed) =
                                parse_recent_entity(json_map(Some(entry)).and_then(|e| e.get("entity")))
                            {
                                out.push(parsed);
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
                    dart_num_int(items_map.and_then(|si| si.get("totalCount")))
                        .map(|v| v as i32)
                        .unwrap_or(items.len() as i32)
                };
                sections.push(BackendHomeSection {
                    uri,
                    kind: if recents { 1 } else { 0 },
                    title: label_text(sec_data.and_then(|d| d.get("title"))),
                    subtitle: label_text(sec_data.and_then(|d| d.get("subtitle"))),
                    header_artist: sec_data.and_then(|d| d.get("headerEntity")).and_then(parse_artist),
                    items,
                    total_count,
                });
            }
            _ => {}
        }
    }

    // 推荐流若一张卡都没解析出来就去掉
    sections.retain(|s| !(s.kind == 2 && s.items.is_empty()));

    BackendHomeFeed {
        greeting: label_text(home.get("greeting")),
        chips: home
            .get("homeChips")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(parse_home_chip).collect())
            .unwrap_or_default(),
        shortcuts,
        sections,
    }
}

/// 根字段名对不上时兜底：在响应里找第一个带 `sections` 的对象（最多下探两层）。
fn find_first_sections_container(data: &Value, depth: usize) -> Option<&Value> {
    let map = data.as_object()?;
    for val in map.values() {
        let Some(m) = val.as_object() else {
            continue;
        };
        if non_null(m.get("sections")).is_some() || non_null(m.get("sectionContainer")).is_some() {
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

/// 解析 Pathfinder `browsePage` 分类页分区列表（与 Dart `HomeParser.browseSections` 一致）。
pub fn parse_browse_sections(data: &Value) -> Vec<BackendHomeSection> {
    let root = json_map(data.get("browse"))
        .or_else(|| json_map(data.get("browsePage")))
        .or_else(|| find_first_sections_container(data, 2));
    let Some(root) = root else {
        return Vec::new();
    };
    let sections_map = json_map(json_map(root.get("sectionContainer")).and_then(|c| c.get("sections")))
        .or_else(|| json_map(root.get("sections")));
    let Some(arr) = sections_map.and_then(|s| s.get("items")).and_then(Value::as_array) else {
        return Vec::new();
    };

    let mut sections = Vec::new();
    for raw in arr.iter().filter(|s| s.is_object()) {
        let (items_map, raw_items) = section_items(raw);
        let items: Vec<BackendHomeItem> = raw_items.iter().filter_map(parse_home_item).collect();
        if items.is_empty() {
            continue;
        }
        let meta = json_map(raw.get("data"));
        sections.push(BackendHomeSection {
            uri: json_str(raw.get("uri")).unwrap_or("").to_string(),
            kind: 0,
            title: label_text(meta.and_then(|m| m.get("title"))),
            subtitle: label_text(meta.and_then(|m| m.get("subtitle"))),
            header_artist: None,
            total_count: dart_num_int(items_map.and_then(|si| si.get("totalCount")))
                .map(|v| v as i32)
                .unwrap_or(items.len() as i32),
            items,
        });
    }
    sections
}

/// 解析 Pathfinder `browseAll` 分类列表；颜色保留原始 hex，由 Dart 转换（缺失 / 非法时回落默认色）。
pub fn parse_categories(data: &Value) -> Vec<BackendCategory> {
    let mut result = Vec::new();
    let sections = json_map(json_map(data.get("browseStart")).and_then(|b| b.get("sections")))
        .and_then(|s| s.get("items"))
        .and_then(Value::as_array);
    for section in sections.into_iter().flatten() {
        let items = json_map(json_map(Some(section)).and_then(|s| s.get("sectionItems")))
            .and_then(|si| si.get("items"))
            .and_then(Value::as_array);
        for item in items.into_iter().flatten() {
            let Some(m) = json_map(Some(item)) else {
                continue;
            };
            let card = json_map(m.get("content"))
                .and_then(unwrap_wrapper)
                .and_then(|d| json_map(d.get("data")))
                .and_then(|d| json_map(d.get("cardRepresentation")));
            let Some(card) = card else {
                continue;
            };
            let artwork = parse_images(json_map(card.get("artwork")).and_then(|a| a.get("sources")));
            result.push(BackendCategory {
                id: json_str(m.get("uri")).unwrap_or("").to_string(),
                name: json_str(json_map(card.get("title")).and_then(|t| t.get("transformedLabel")))
                    .unwrap_or("")
                    .to_string(),
                icon_url: artwork.first().map(|i| i.url.clone()).unwrap_or_default(),
                color_hex: json_str(json_map(card.get("backgroundColor")).and_then(|b| b.get("hex")))
                    .unwrap_or("")
                    .to_string(),
            });
        }
    }
    result
}

/// 一页目录结果（items 已过滤；offset / total / next_offset 按原始条目推导，见 Dart `CatalogPage.fromSlice`）。
#[derive(Clone, Debug)]
pub struct BackendCatalogPage<T> {
    pub items: Vec<T>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

/// 分页元数据（与 Dart `PathfinderParsers._catalogPage` + `CatalogPage.fromSlice` 一致）。
fn page_meta(page: &Value, offset: i32, limit: i32, raw_count: i32) -> Result<(Option<i32>, Option<i32>), String> {
    let total = dart_int(page.get("totalCount"));
    let paging = json_map(page.get("pagingInfo")).or_else(|| json_map(page.get("pageInfo")));
    let next_from_server = dart_int(paging.and_then(|p| p.get("nextOffset")));
    if total.is_some_and(|t| t < 0) || next_from_server.is_some_and(|n| n < 0) {
        return Err("format:Invalid catalog pagination".to_string());
    }
    let has_next_page = paging.and_then(|p| p.get("hasNextPage")).and_then(Value::as_bool);
    let (offset64, raw64) = (i64::from(offset), i64::from(raw_count));
    let more = has_next_page.unwrap_or_else(|| {
        next_from_server.is_some()
            || total.map_or(raw_count >= limit, |t| offset64 + raw64 < t)
    });
    let next_offset = if more {
        let n = next_from_server.unwrap_or(offset64 + raw64);
        if n <= offset64 {
            return Err("format:Catalog page did not advance".to_string());
        }
        Some(n as i32)
    } else {
        None
    };
    Ok((total.map(|t| t as i32), next_offset))
}

fn parse_catalog_page<T>(
    value: Option<&Value>,
    offset: i32,
    limit: i32,
    parse_item: impl FnMut(&Value) -> Option<T>,
) -> Result<BackendCatalogPage<T>, String> {
    let page = json_map(value).ok_or_else(|| "format:Missing catalog items".to_string())?;
    let raw_items = page
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| "format:Missing catalog items".to_string())?;
    let (total, next_offset) = page_meta(page, offset, limit, raw_items.len() as i32)?;
    Ok(BackendCatalogPage {
        items: raw_items.iter().filter_map(parse_item).collect(),
        offset,
        total,
        next_offset,
    })
}

#[derive(Clone, Debug)]
pub struct BackendSearchPage {
    pub tracks: BackendCatalogPage<BackendTrack>,
    pub artists: BackendCatalogPage<BackendArtist>,
    pub playlists: BackendCatalogPage<BackendPlaylistSummary>,
}

/// 解析 Pathfinder `searchDesktop` 分页结果。缺少集合是协议错误，不是「空结果 / 到底」。
pub fn parse_search_page(data: &Value, offset: i32, limit: i32) -> Result<BackendSearchPage, String> {
    let search = json_map(data.get("searchV2")).ok_or_else(|| "format:Missing search results".to_string())?;
    Ok(BackendSearchPage {
        tracks: parse_catalog_page(search.get("tracksV2"), offset, limit, |i| parse_track_item(i, None))?,
        artists: parse_catalog_page(search.get("artists"), offset, limit, parse_artist)?,
        playlists: parse_catalog_page(search.get("playlists"), offset, limit, parse_playlist_summary)?,
    })
}

/// `getAlbum` 一次响应同时服务专辑页（[album] + [tracks]）与分页曲目（[page_error] 为空时的分页信息）。
#[derive(Clone, Debug)]
pub struct BackendAlbumQuery {
    pub album: Option<BackendAlbum>,
    pub tracks: Vec<BackendTrack>,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
    /// 分页解析失败的原因（`format:` 前缀）；专辑缺失时为 `format:Missing album`。
    pub page_error: Option<String>,
}

/// 解析 Pathfinder `getAlbum`：专辑信息与曲目（曲目回填专辑，保证封面可用）。
pub fn parse_album_query(data: &Value, offset: i32, limit: i32) -> BackendAlbumQuery {
    let union = json_map(data.get("albumUnion"));
    let Some(album) = union.and_then(|u| parse_album(u, None)) else {
        return BackendAlbumQuery {
            album: None,
            tracks: Vec::new(),
            total: None,
            next_offset: None,
            page_error: Some("format:Missing album".to_string()),
        };
    };
    let tracks_v2 = union.and_then(|u| json_map(u.get("tracksV2")));
    let raw_items = tracks_v2.and_then(|t| t.get("items")).and_then(Value::as_array);
    let tracks: Vec<BackendTrack> = raw_items
        .map(|arr| arr.iter().filter_map(|i| parse_track_item(i, Some(&album))).collect())
        .unwrap_or_default();
    let meta = match (tracks_v2, raw_items) {
        (Some(page), Some(arr)) => page_meta(page, offset, limit, arr.len() as i32),
        _ => Err("format:Missing catalog items".to_string()),
    };
    let (total, next_offset, page_error) = match meta {
        Ok((total, next)) => (total, next, None),
        Err(e) => (None, None, Some(e)),
    };
    BackendAlbumQuery {
        album: Some(album),
        tracks,
        total,
        next_offset,
        page_error,
    }
}

#[derive(Clone, Debug)]
pub struct BackendArtistPage {
    pub artist: BackendArtist,
    pub top_tracks: Vec<BackendTrack>,
}

/// 解析 Pathfinder `queryArtistOverview`：艺人信息与热门曲目。
pub fn parse_artist_overview(data: &Value) -> Option<BackendArtistPage> {
    let union = json_map(data.get("artistUnion"))?;
    let artist = parse_artist(union)?;
    let top_tracks = json_map(json_map(union.get("discography")).and_then(|d| d.get("topTracks")))
        .and_then(|t| t.get("items"))
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(|i| parse_track_item(i, None)).collect())
        .unwrap_or_default();
    Some(BackendArtistPage { artist, top_tracks })
}

/// 解析 Pathfinder `queryArtistDiscographyAll`：每个条目取 releases 的首个版本，缺艺人时回填。
pub fn parse_artist_discography_page(
    data: &Value,
    fallback_artist: Option<BackendArtist>,
    offset: i32,
    limit: i32,
) -> Result<BackendCatalogPage<BackendAlbum>, String> {
    let all = json_map(data.get("artistUnion"))
        .and_then(|u| json_map(u.get("discography")))
        .and_then(|d| d.get("all"));
    let fb_slice = fallback_artist.as_ref().map(std::slice::from_ref);
    parse_catalog_page(all, offset, limit, |item| {
        let releases = json_map(json_map(Some(item)).and_then(|i| i.get("releases")))
            .and_then(|r| r.get("items"))
            .and_then(Value::as_array)?;
        parse_album(releases.first()?, fb_slice)
    })
}

/// decorateContextTracks：按 URI 批量补全的曲目（服务端顺序，解析失败的条目跳过）。
pub fn parse_decorated_tracks(data: &Value) -> Vec<BackendTrack> {
    data.get("tracks")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(parse_track).collect())
        .unwrap_or_default()
}

#[derive(Clone, Debug)]
pub struct BackendLibraryTrack {
    pub track: BackendTrack,
    /// `addedAt.isoString`（或直接的字符串）；原样交给 Dart `DateTime.tryParse`，保留时区语义。
    pub added_at_iso: Option<String>,
}

#[derive(Clone, Debug)]
pub struct BackendLibraryTracksPage {
    pub items: Vec<BackendLibraryTrack>,
    pub total_count: i32,
}

/// fetchLibraryTracks：open.spotify.com「已点赞的歌曲」单页。
pub fn parse_library_tracks_page(data: &Value) -> BackendLibraryTracksPage {
    let page = json_map(data.get("me"))
        .and_then(|m| json_map(m.get("library")))
        .and_then(|l| json_map(l.get("tracks")));
    let Some(page) = page else {
        return BackendLibraryTracksPage {
            items: Vec::new(),
            total_count: 0,
        };
    };
    let total_count = dart_int(page.get("totalCount")).unwrap_or(0) as i32;
    let mut items = Vec::new();
    for item in page.get("items").and_then(Value::as_array).into_iter().flatten() {
        let Some(item) = json_map(Some(item)) else {
            continue;
        };
        let Some(wrapper) = json_map(item.get("track")) else {
            continue;
        };
        let inner = json_map(wrapper.get("data")).unwrap_or(wrapper);
        let uri = json_str(inner.get("uri")).or_else(|| json_str(wrapper.get("_uri")));
        let parsed = match uri {
            Some(uri) if non_null(inner.get("uri")).is_none() => {
                let mut normalized = inner.clone();
                if let Some(obj) = normalized.as_object_mut() {
                    obj.insert("uri".to_string(), Value::String(uri.to_string()));
                }
                parse_track(&normalized)
            }
            _ => parse_track(inner),
        };
        let Some(track) = parsed else {
            continue;
        };
        let added = item.get("addedAt");
        let added_raw = non_null(json_map(added).and_then(|a| a.get("isoString"))).or(added);
        items.push(BackendLibraryTrack {
            track,
            added_at_iso: json_str(added_raw).map(str::to_string),
        });
    }
    BackendLibraryTracksPage { items, total_count }
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

    // -----------------------------------------------------------------------
    // 以下移植自 Dart test/pathfinder_parsers_test.dart、home_parser_test.dart、
    // browse_page_parser_test.dart、desktop_catalog_pagination_test.dart（同一组合成夹具）。
    // -----------------------------------------------------------------------

    fn pf_track(id: &str, album_of_track: Option<Value>) -> Value {
        let mut t = json!({
            "uri": format!("spotify:track:{id}"),
            "name": format!("Song {id}"),
            "artists": { "items": [{ "uri": "spotify:artist:a1", "profile": { "name": "Artist One" } }] },
            "duration": { "totalMilliseconds": 201000 },
            "contentRating": { "label": "EXPLICIT" },
            "playability": { "playable": true },
        });
        if let Some(a) = album_of_track {
            t["albumOfTrack"] = a;
        }
        t
    }

    fn pf_cover() -> Value {
        json!({ "sources": [
            { "url": "https://i.scdn.co/image/small", "width": 64, "height": 64 },
            { "url": "https://i.scdn.co/image/large", "width": 640, "height": 640 },
        ]})
    }

    #[test]
    fn pf_common_helpers() {
        assert_eq!(id_from_uri("spotify:album:abc"), "abc");
        assert_eq!(id_from_uri(""), "");
        let list = parse_images(Some(&json!([
            { "url": "a", "maxWidth": 300 },
            { "url": "https://i.scdn.co/image/small", "width": 64, "height": 64 },
            { "url": "https://i.scdn.co/image/large", "width": 640, "height": 640 },
            { "url": "" },
        ])));
        let urls: Vec<_> = list.iter().map(|i| i.url.as_str()).collect();
        assert_eq!(urls, ["https://i.scdn.co/image/large", "a", "https://i.scdn.co/image/small"]);
        assert_eq!(strip_html("Hi <a href=\"x\">there</a> &amp; you"), "Hi there & you");
        assert_eq!(strip_html("a < b"), "a < b", "未闭合的 < 保留");
        assert_eq!(dart_int(Some(&json!(" 12 "))), Some(12));
        assert_eq!(dart_int(Some(&json!(3.9))), Some(3));
        assert_eq!(dart_int(Some(&json!("x"))), None);
        assert_eq!(dart_num_int(Some(&json!("12"))), None);
    }

    #[test]
    fn pf_album_page_backfills_album_into_tracks() {
        let q = parse_album_query(
            &json!({ "albumUnion": {
                "uri": "spotify:album:al1",
                "name": "Album",
                "type": "SINGLE",
                "date": { "isoString": "2024-05-01T00:00:00Z" },
                "coverArt": pf_cover(),
                "artists": { "items": [{ "id": "a1", "uri": "spotify:artist:a1", "profile": { "name": "Artist One" } }] },
                "tracksV2": { "totalCount": 2, "items": [
                    { "track": pf_track("t1", None), "uid": "u1" },
                    { "track": { "uri": "spotify:episode:x" }, "uid": "u2" },
                ]},
            }}),
            0,
            50,
        );
        let album = q.album.expect("album");
        assert_eq!(album.album_type, "single");
        assert_eq!(album.release_date, "2024-05-01");
        assert_eq!(album.total_tracks, 2);
        assert_eq!(q.tracks.len(), 1);
        assert!(q.tracks[0].explicit);
        assert_eq!(q.tracks[0].duration_ms, 201000);
        assert_eq!(
            q.tracks[0].album.as_ref().unwrap().images[0].url,
            "https://i.scdn.co/image/large"
        );
        assert_eq!(q.page_error, None);
        assert_eq!(q.next_offset, None, "2 条原始条目已到 totalCount");
    }

    #[test]
    fn pf_artist_overview_and_top_tracks() {
        let page = parse_artist_overview(&json!({ "artistUnion": {
            "id": "a1",
            "uri": "spotify:artist:a1",
            "profile": { "name": "Artist One" },
            "visuals": { "avatarImage": pf_cover() },
            "stats": { "followers": 1234 },
            "discography": { "topTracks": { "items": [
                { "track": pf_track("t1", Some(json!({ "uri": "spotify:album:al1", "coverArt": pf_cover() }))) },
            ]}},
        }}))
        .expect("artist");
        assert_eq!(page.artist.name, "Artist One");
        assert_eq!(page.artist.followers, Some(1234));
        assert_eq!(page.top_tracks[0].album.as_ref().unwrap().id, "al1");
    }

    #[test]
    fn pf_track_album_ref_without_uri_is_kept() {
        let t = parse_track(&pf_track("t1", Some(json!({ "name": "No uri" })))).unwrap();
        let album = t.album.expect("Dart _albumRef 不要求 uri");
        assert_eq!(album.uri, "");
        assert_eq!(album.name, "No uri");
    }

    #[test]
    fn pf_discography_takes_first_release_and_backfills_artist() {
        let artist = parse_artist(&json!({ "uri": "spotify:artist:a1", "profile": { "name": "Artist One" } }));
        let page = parse_artist_discography_page(
            &json!({ "artistUnion": { "discography": { "all": { "items": [
                { "releases": { "items": [{
                    "id": "al2",
                    "uri": "spotify:album:al2",
                    "name": "Second",
                    "type": "ALBUM",
                    "date": { "year": 2020 },
                    "coverArt": pf_cover(),
                    "tracks": { "totalCount": 9 },
                }]}},
                { "releases": { "items": [] } },
            ]}}}}),
            artist,
            0,
            20,
        )
        .unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].release_date, "2020");
        assert_eq!(page.items[0].total_tracks, 9);
        assert_eq!(page.items[0].artists[0].name, "Artist One");
    }

    #[test]
    fn pf_search_unwraps_response_wrappers() {
        let page = parse_search_page(
            &json!({ "searchV2": {
                "tracksV2": { "items": [{ "item": { "__typename": "TrackResponseWrapper", "data": pf_track("t1", None) } }] },
                "artists": { "items": [{ "__typename": "ArtistResponseWrapper", "data": { "uri": "spotify:artist:a1", "profile": { "name": "A" } } }] },
                "playlists": { "items": [{
                    "__typename": "PlaylistResponseWrapper",
                    "data": {
                        "uri": "spotify:playlist:p1",
                        "name": "Mix",
                        "description": "<b>Best</b>",
                        "images": { "items": [pf_cover()] },
                        "ownerV2": { "__typename": "UserResponseWrapper", "data": { "name": "Someone" } },
                    },
                }]},
            }}),
            0,
            10,
        )
        .unwrap();
        assert_eq!(page.tracks.items[0].id, "t1");
        assert_eq!(page.artists.items[0].name, "A");
        assert_eq!(page.playlists.items[0].description, "Best");
        assert_eq!(page.playlists.items[0].owner_name, "Someone");
    }

    #[test]
    fn pf_browse_all_categories() {
        let cats = parse_categories(&json!({ "browseStart": { "sections": { "items": [
            { "sectionItems": { "items": [{
                "uri": "spotify:page:0JQ5DAqbMKFQ00XGBls6ym",
                "content": {
                    "__typename": "BrowseSectionContainerWrapper",
                    "data": {
                        "__typename": "BrowseSectionContainer",
                        "data": { "cardRepresentation": {
                            "artwork": pf_cover(),
                            "backgroundColor": { "hex": "#8D67AB" },
                            "title": { "transformedLabel": "Pop" },
                        }},
                    },
                },
            }]}},
        ]}}}));
        assert_eq!(cats.len(), 1);
        assert_eq!(cats[0].name, "Pop");
        assert_eq!(cats[0].id, "spotify:page:0JQ5DAqbMKFQ00XGBls6ym");
        assert_eq!(cats[0].color_hex, "#8D67AB");
        assert_eq!(cats[0].icon_url, "https://i.scdn.co/image/large");
    }

    #[test]
    fn pf_playlist_attributes_cover_and_description() {
        let attrs = json!({
            "description": "Fresh &amp; new",
            "pictureSize": [
                { "targetName": "default", "url": "https://img/default" },
                { "targetName": "large", "url": "https://img/large" },
            ],
        });
        assert_eq!(playlist_images_from_attributes(&attrs)[0].url, "https://img/large");
        assert_eq!(strip_html(attrs["description"].as_str().unwrap()), "Fresh & new");
        // URL-safe、无填充的 picture 也能解码
        let pic = playlist_images_from_attributes(&json!({ "picture": "q83_" }));
        assert_eq!(pic[0].url, "https://i.scdn.co/image/abcdff");
        let (_, uris, ts) = extract_page_items(&json!({ "contents": { "items": [
            { "uri": "spotify:track:t1", "attributes": { "timestamp": "1700000000000" } },
            { "uri": "spotify:episode:e1" },
            { "uri": "spotify:track:t2", "attributes": {} },
        ]}}));
        assert_eq!(uris, ["spotify:track:t1", "spotify:track:t2"]);
        assert_eq!(ts, vec![("spotify:track:t1".to_string(), 1_700_000_000_000)]);
    }

    #[test]
    fn pf_decorated_tracks_skip_nulls() {
        let tracks = parse_decorated_tracks(&json!({ "tracks": [pf_track("t1", None), null, pf_track("t2", None)] }));
        let ids: Vec<_> = tracks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, ["t1", "t2"]);
    }

    #[test]
    fn pf_library_tracks_page_reads_wrappers_and_added_at() {
        let page = parse_library_tracks_page(&json!({ "me": { "library": { "tracks": {
            "totalCount": 3,
            "items": [
                { "addedAt": { "isoString": "2024-01-02T03:04:05Z" },
                  "track": { "_uri": "spotify:track:t1", "data": { "__typename": "Track", "name": "One" } } },
                { "addedAt": "2023-12-31T00:00:00Z", "track": { "data": pf_track("t2", None) } },
                { "track": { "_uri": "spotify:episode:e1", "data": {} } },
                null,
            ],
        }}}}));
        assert_eq!(page.total_count, 3);
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].track.uri, "spotify:track:t1");
        assert_eq!(page.items[0].track.name, "One");
        assert_eq!(page.items[0].added_at_iso.as_deref(), Some("2024-01-02T03:04:05Z"));
        assert_eq!(page.items[1].added_at_iso.as_deref(), Some("2023-12-31T00:00:00Z"));
        assert_eq!(parse_library_tracks_page(&json!({})).items.len(), 0);
    }

    fn label(text: &str) -> Value {
        json!({ "transformedLabel": text, "translatedBaseText": text })
    }

    fn home_playlist_item(id: &str, name: &str, description: &str) -> Value {
        json!({
            "uri": format!("spotify:playlist:{id}"),
            "data": null,
            "content": {
                "__typename": "PlaylistResponseWrapper",
                "data": {
                    "__typename": "Playlist",
                    "uri": format!("spotify:playlist:{id}"),
                    "name": name,
                    "description": description,
                    "images": { "items": [{ "sources": [{ "url": format!("https://example.invalid/{id}.jpg"), "width": 640, "height": 640 }] }] },
                    "ownerV2": { "data": { "__typename": "User", "name": "Owner" } },
                    "content": { "totalCount": 30 },
                },
            },
        })
    }

    fn home_artist_entity(id: &str, name: &str) -> Value {
        json!({
            "__typename": "ArtistResponseWrapper",
            "_uri": format!("spotify:artist:{id}"),
            "data": {
                "__typename": "Artist",
                "uri": format!("spotify:artist:{id}"),
                "profile": { "name": name },
                "visuals": { "avatarImage": { "sources": [{ "url": format!("https://example.invalid/{id}.jpg"), "width": 160, "height": 160 }] } },
            },
        })
    }

    fn home_section(typename: &str, uri: &str, items: Vec<Value>, extra: Value, total: Option<usize>) -> Value {
        let mut data = json!({ "__typename": typename });
        if let Some(obj) = extra.as_object() {
            for (k, v) in obj {
                data[k] = v.clone();
            }
        }
        let count = total.unwrap_or(items.len());
        json!({ "uri": uri, "data": data, "sectionItems": { "items": items, "totalCount": count } })
    }

    fn home_response() -> Value {
        let liked = json!({
            "uri": "spotify:user:@:collection",
            "data": null,
            "content": { "__typename": "UnknownType", "uri": "spotify:user:@:collection" },
        });
        let recents = json!({
            "uri": "spotify:list:recents",
            "content": { "__typename": "ListResponseWrapper", "data": { "__typename": "List", "items": { "items": [
                { "uid": "u1", "entity": { "_uri": "spotify:playlist:r1", "data": {
                    "identityTrait": {
                        "name": "Recent Mix",
                        "description": "A &amp; B",
                        "contributors": { "items": [{ "name": "Spotify", "uri": "spotify:user:spotify" }] },
                    },
                    "visualIdentityTrait": { "squareCoverImage": { "image": { "data": { "sources": [
                        { "url": "https://example.invalid/r1.jpg", "maxWidth": 640, "maxHeight": 640 },
                    ]}}}},
                    "entityTypeTrait": { "type": "ENTITY_TYPE_PLAYLIST" },
                }}},
                { "uid": "u2", "entity": { "_uri": "spotify:collection:tracks", "data": {} } },
                { "uid": "u3", "entity": { "_uri": "spotify:album:r3", "data": { "identityTrait": {
                    "name": "Recent Album",
                    "contributors": { "items": [{ "name": "Artist X", "uri": "spotify:artist:x" }] },
                }}}},
            ]}}},
        });
        let mut shorts = vec![liked];
        for i in 0..6 {
            shorts.push(home_playlist_item(&format!("s{i}"), "P", ""));
        }
        json!({ "home": {
            "greeting": label("早上好"),
            "homeChips": [
                { "id": "music-chip", "label": label("音乐"), "subChips": [{ "id": "sub-a", "label": label("关注中") }] },
                { "id": "podcasts-chip", "label": label("播客"), "subChips": [] },
            ],
            "sectionContainer": { "sections": { "items": [
                home_section("HomeShortsSectionData", "spotify:section:shorts", shorts, json!({}), None),
                home_section(
                    "HomeGenericSectionData",
                    "spotify:section:generic",
                    vec![home_playlist_item("g1", "Mix", "<a href=\"x\">Desc</a>"), home_playlist_item("g2", "P", "")],
                    json!({ "title": label("与 Artist Y 相似"), "subtitle": label(""), "headerEntity": home_artist_entity("y", "Artist Y") }),
                    Some(25),
                ),
                home_section("HomeRecentlyPlayedSectionData", "spotify:section:recents", vec![recents], json!({ "title": label("最近播放") }), None),
                home_section("HomeFeedBaselineSectionData", "spotify:section:f1", vec![home_playlist_item("f1", "P", "")], json!({ "title": label("为你推荐"), "iconName": "" }), None),
                home_section(
                    "HomeFeedBaselineSectionData",
                    "spotify:section:f2",
                    vec![json!({ "uri": "spotify:artist:z", "content": { "__typename": "ArtistResponseWrapper", "data": home_artist_entity("z", "Z")["data"] } })],
                    json!({ "title": label("ignored") }),
                    None,
                ),
                home_section(
                    "HomeFeedBaselineSectionData",
                    "spotify:section:f3",
                    vec![home_playlist_item("f3", "P", "")],
                    json!({ "title": label("与 Artist Y 相似"), "headerEntity": home_artist_entity("y", "Artist Y") }),
                    None,
                ),
                home_section("HomeNativeAdsSectionData", "spotify:section:ads", vec![home_playlist_item("ad", "P", "")], json!({}), None),
                home_section(
                    "HomeGenericSectionData",
                    "spotify:section:podcasts",
                    vec![json!({ "uri": "spotify:show:p1", "content": { "__typename": "PodcastOrAudiobookResponseWrapper", "data": {
                        "__typename": "Podcast",
                        "uri": "spotify:show:p1",
                        "name": "Show",
                        "publisher": { "name": "Publisher" },
                        "coverArt": { "sources": [{ "url": "https://example.invalid/p1.jpg", "width": 300, "height": 300 }] },
                    }}})],
                    json!({ "title": label("播客") }),
                    None,
                ),
            ]}},
        }})
    }

    #[test]
    fn home_greeting_chips_and_shortcuts() {
        let feed = parse_home_feed(&home_response());
        assert_eq!(feed.greeting, "早上好");
        let chip_ids: Vec<_> = feed.chips.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(chip_ids, ["music-chip", "podcasts-chip"]);
        assert_eq!(feed.chips[0].sub_chips[0].label, "关注中");
        assert_eq!(feed.shortcuts.len(), 6, "7 个（奇数）去掉最后一个");
        assert_eq!(feed.shortcuts[0].kind, 3);
        assert_eq!(feed.shortcuts[1].kind, 0);
    }

    #[test]
    fn home_sections_keep_order_and_merge_feed() {
        let feed = parse_home_feed(&home_response());
        let kinds: Vec<_> = feed.sections.iter().map(|s| s.kind).collect();
        assert_eq!(kinds, [0, 1, 2, 0]);
        let generic = &feed.sections[0];
        assert_eq!(generic.title, "与 Artist Y 相似");
        assert_eq!(generic.header_artist.as_ref().unwrap().name, "Artist Y");
        assert!(generic.total_count > generic.items.len() as i32);
        assert_eq!(generic.items[0].subtitle, "Desc");
        assert_eq!(generic.items[0].images[0].url, "https://example.invalid/g1.jpg");
        assert_eq!(generic.items[1].subtitle, "Spotify", "ownerV2 无包装类型时取不到名字");

        let grid = &feed.sections[2];
        let uris: Vec<_> = grid.items.iter().map(|i| i.uri.as_str()).collect();
        assert_eq!(uris, ["spotify:playlist:f1", "spotify:playlist:f3"]);
        assert_eq!(grid.items[0].reason, "为你推荐");
        assert_eq!(grid.items[1].reason_artist.as_ref().unwrap().name, "Artist Y");

        let podcast = &feed.sections[3].items[0];
        assert_eq!(podcast.kind, 4);
        assert_eq!(podcast.subtitle, "Publisher");
    }

    #[test]
    fn home_recently_played_reads_trait_entities() {
        let feed = parse_home_feed(&home_response());
        let recents = &feed.sections[1];
        assert_eq!(recents.title, "最近播放");
        let kinds: Vec<_> = recents.items.iter().map(|i| i.kind).collect();
        assert_eq!(kinds, [0, 3, 1]);
        let mix = &recents.items[0];
        assert_eq!(mix.title, "Recent Mix");
        assert_eq!(mix.subtitle, "A & B");
        assert_eq!(mix.images[0].url, "https://example.invalid/r1.jpg");
        assert_eq!(mix.playlist.as_ref().unwrap().id, "r1");
        assert_eq!(recents.items[2].album.as_ref().unwrap().artists[0].name, "Artist X");
        assert_eq!(recents.total_count, 3);
    }

    #[test]
    fn home_empty_and_liked_uris() {
        assert!(parse_home_feed(&json!({})).sections.is_empty());
        assert!(is_liked_songs_uri("spotify:user:someone:collection"));
        assert!(is_liked_songs_uri("spotify:collection:tracks"));
        assert!(!is_liked_songs_uri("spotify:user:someone"));
    }

    fn browse_section(uri: &str, title: &str, items: Vec<Value>) -> Value {
        let n = items.len();
        json!({
            "uri": uri,
            "data": { "__typename": "BrowseGenericSectionData", "title": label(title), "subtitle": label("") },
            "sectionItems": { "items": items, "totalCount": n },
        })
    }

    #[test]
    fn browse_sections_roots_and_fallbacks() {
        let sections = parse_browse_sections(&json!({ "browse": { "uri": "spotify:page:mood", "sections": { "items": [
            browse_section("spotify:section:mood-1", "热门歌单", vec![home_playlist_item("p1", "歌单一", ""), home_playlist_item("p2", "P", "")]),
            browse_section("spotify:section:mood-2", "为你推荐", vec![home_playlist_item("p3", "P", "")]),
        ]}}}));
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].title, "热门歌单");
        let titles: Vec<_> = sections[0].items.iter().map(|i| i.title.as_str()).collect();
        assert_eq!(titles, ["歌单一", "P"]);
        assert_eq!(sections[0].kind, 0);
        assert_eq!(sections[0].total_count, 2);

        let alt = json!({ "browsePage": { "sections": { "items": [
            browse_section("spotify:section:s", "标题", vec![home_playlist_item("p1", "P", "")]),
        ]}}});
        assert_eq!(parse_browse_sections(&alt).len(), 1);

        let nested = json!({ "data": { "unknownRoot": { "sections": { "items": [
            browse_section("spotify:section:empty", "空分区", vec![json!({ "uri": "spotify:unknown:x", "content": null })]),
            browse_section("spotify:section:ok", "正常", vec![home_playlist_item("p1", "P", "")]),
        ]}}}});
        let found = parse_browse_sections(&nested);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].title, "正常");

        assert!(parse_browse_sections(&json!({})).is_empty());
        assert!(parse_browse_sections(&json!({ "browse": null })).is_empty());
        assert!(parse_browse_sections(&json!({ "browse": { "sections": { "items": [] } } })).is_empty());
    }

    fn wrapped_track(id: usize) -> Value {
        json!({ "item": { "__typename": "TrackResponseWrapper", "data": { "uri": format!("spotify:track:{id}"), "name": format!("Track {id}") } } })
    }

    fn search_with_tracks(tracks: Value) -> Value {
        json!({ "searchV2": {
            "tracksV2": tracks,
            "artists": { "totalCount": 0, "items": [] },
            "playlists": { "totalCount": 0, "items": [] },
        }})
    }

    #[test]
    fn catalog_search_follows_raw_offsets() {
        let items: Vec<Value> = (0..10)
            .map(|i| if i == 2 { json!({ "item": null }) } else { wrapped_track(i) })
            .collect();
        let first = parse_search_page(&search_with_tracks(json!({ "totalCount": 23, "items": items })), 0, 10).unwrap();
        assert_eq!(first.tracks.items.len(), 9);
        assert_eq!(first.tracks.total, Some(23));
        assert_eq!(first.tracks.next_offset, Some(10));
        assert_eq!(first.artists.next_offset, None);
        let last_items: Vec<Value> = (20..23).map(wrapped_track).collect();
        let last = parse_search_page(&search_with_tracks(json!({ "totalCount": 23, "items": last_items })), 20, 10).unwrap();
        assert_eq!(last.tracks.items.last().unwrap().id, "22");
        assert_eq!(last.tracks.next_offset, None);
    }

    #[test]
    fn catalog_metadata_keeps_filtered_pages_traversable() {
        let page = parse_search_page(
            &search_with_tracks(json!({ "totalCount": 6, "items": [null, null], "pagingInfo": { "nextOffset": 4 } })),
            0,
            20,
        )
        .unwrap();
        assert!(page.tracks.items.is_empty());
        assert_eq!(page.tracks.next_offset, Some(4));
    }

    #[test]
    fn catalog_discography_beyond_twenty() {
        let artist = parse_artist(&json!({ "uri": "spotify:artist:artist", "profile": { "name": "Artist" } }));
        let page_at = |offset: usize| {
            let items: Vec<Value> = (offset..(offset + 20).min(25))
                .map(|i| {
                    if i == 3 {
                        json!({ "releases": { "items": [] } })
                    } else {
                        json!({ "releases": { "items": [{ "uri": format!("spotify:album:{i}"), "name": format!("Album {i}"), "date": { "year": 2026 } }] } })
                    }
                })
                .collect();
            json!({ "artistUnion": { "discography": { "all": { "totalCount": 25, "items": items } } } })
        };
        let first = parse_artist_discography_page(&page_at(0), artist.clone(), 0, 20).unwrap();
        assert_eq!(first.items.len(), 19);
        assert_eq!(first.next_offset, Some(20));
        let last = parse_artist_discography_page(&page_at(20), artist, 20, 20).unwrap();
        assert_eq!(last.items.last().unwrap().id, "24");
        assert_eq!(last.items.last().unwrap().artists[0].name, "Artist");
        assert_eq!(last.next_offset, None);
    }

    #[test]
    fn catalog_album_tracks_beyond_fifty() {
        let page_at = |offset: usize| {
            let items: Vec<Value> = (offset..(offset + 50).min(53))
                .map(|i| json!({ "track": { "uri": format!("spotify:track:{i}") } }))
                .collect();
            json!({ "albumUnion": {
                "uri": "spotify:album:album",
                "name": "Large album",
                "date": { "year": 2024 },
                "coverArt": { "sources": [{ "url": "https://example.test/cover.jpg" }] },
                "tracksV2": { "totalCount": 53, "items": items },
            }})
        };
        let first = parse_album_query(&page_at(0), 0, 50);
        assert_eq!(first.tracks.len(), 50);
        assert_eq!(first.next_offset, Some(50));
        let last = parse_album_query(&page_at(50), 50, 50);
        assert_eq!(last.tracks.len(), 3);
        let album = last.tracks.last().unwrap().album.as_ref().unwrap();
        assert_eq!(album.release_date, "2024");
        assert_eq!(album.images[0].url, "https://example.test/cover.jpg");
        assert_eq!(last.next_offset, None);
    }

    #[test]
    fn catalog_protocol_errors() {
        assert_eq!(
            parse_search_page(&json!({}), 0, 20).err().as_deref(),
            Some("format:Missing search results")
        );
        let malformed = parse_album_query(&json!({ "albumUnion": { "uri": "spotify:album:album" } }), 0, 50);
        assert!(malformed.album.is_some());
        assert_eq!(malformed.page_error.as_deref(), Some("format:Missing catalog items"));
        assert_eq!(
            parse_album_query(&json!({}), 0, 50).page_error.as_deref(),
            Some("format:Missing album")
        );
        let stuck = json!({ "searchV2": {
            "tracksV2": { "totalCount": 10, "items": [wrapped_track(3)], "pagingInfo": { "nextOffset": 3 } },
            "artists": { "items": [] },
            "playlists": { "items": [] },
        }});
        assert_eq!(
            parse_search_page(&stuck, 3, 20).err().as_deref(),
            Some("format:Catalog page did not advance")
        );
    }
}
