//! DRM / EME 播放媒体清单、HLS 清单本地化、多入口 License/证书请求及曲目/单集 Protobuf 元数据解析。

use std::time::Duration;

use serde_json::Value;

use crate::proto_lite::{self, ProtoMsg};
use crate::spotify_session;

const WIDEVINE_KEY_FORMAT_UUID: &str = "urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed";
const FAIRPLAY_KEY_FORMAT: &str = "com.apple.streamingkeydelivery";
const WEB_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36";

/// PlayPlay 固定请求常量（桌面端 `Spotify.dll` 硬编码）。
const PLAYPLAY_REQK: [u8; 16] = [
    0x02, 0x5e, 0xe5, 0x0f, 0x4d, 0x14, 0x89, 0xd0, 0x24, 0x01, 0x28, 0x6d, 0xf8, 0x3f, 0x03, 0x32,
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendPlaybackFile {
    pub file_id_hex: String,
    pub format: i32,
    pub bitrate: i32,
    pub format_key: String,
    pub encoding_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendTrackPlaybackMedia {
    pub name: String,
    pub duration_ms: i32,
    pub mp4_files: Vec<BackendPlaybackFile>,
    pub external_urls: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendDrmRelayResult {
    pub host: String,
    pub status: u16,
    pub body: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendProtoAudioFile {
    pub file_id: Vec<u8>,
    pub format: i32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendProtoTrackMetadata {
    pub gid: Vec<u8>,
    pub name: String,
    pub album_name: String,
    pub artist_names: Vec<String>,
    pub duration_ms: i32,
    pub explicit: bool,
    pub files: Vec<BackendProtoAudioFile>,
    pub alternatives: Vec<BackendProtoTrackMetadata>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendProtoEpisodeMetadata {
    pub gid: Vec<u8>,
    pub name: String,
    pub show_name: String,
    pub duration_ms: i32,
    pub description: String,
    pub files: Vec<BackendProtoAudioFile>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendPlayplayKey {
    pub r1: Vec<u8>,
    pub r2: Vec<u8>,
}

fn to_i32_loose(v: Option<&Value>) -> i32 {
    match v {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) as i32,
        Some(Value::String(s)) => s.parse::<i32>().unwrap_or(0),
        _ => 0,
    }
}

fn normalize_media_uri(track_id_or_uri: &str) -> (String, bool) {
    let is_episode =
        track_id_or_uri.starts_with("spotify:episode:") || track_id_or_uri.contains("/episode/");
    let last_colon = track_id_or_uri.rsplit(':').next().unwrap_or(track_id_or_uri);
    let no_query = last_colon.split('?').next().unwrap_or(last_colon);
    let id = no_query.rsplit('/').next().unwrap_or(no_query);
    let kind = if is_episode { "episode" } else { "track" };
    (format!("spotify:{kind}:{id}"), is_episode)
}

fn select_media_item<'a>(media: &'a Value, requested_uri: &str) -> Option<&'a serde_json::Map<String, Value>> {
    let map = media.as_object()?;
    let item_of = |entry: &'a Value| -> Option<&'a serde_json::Map<String, Value>> {
        entry.as_object()?.get("item")?.as_object()
    };
    if let Some(entry) = map.get(requested_uri) {
        if let Some(item) = item_of(entry) {
            return Some(item);
        }
    }
    for entry in map.values() {
        if let Some(item) = item_of(entry) {
            return Some(item);
        }
    }
    None
}

/// 解析 `track-playback/v1/media` JSON 响应体。
pub fn parse_track_playback_media_json(
    body: &[u8],
    track_id_or_uri: &str,
) -> Result<BackendTrackPlaybackMedia, String> {
    let (uri, _) = normalize_media_uri(track_id_or_uri);
    let root: Value =
        serde_json::from_slice(body).map_err(|e| format!("track-playback invalid json:{e}"))?;
    let media = root
        .get("media")
        .ok_or_else(|| "track-playback 响应缺 item".to_string())?;
    let item = select_media_item(media, &uri)
        .ok_or_else(|| "track-playback 响应缺 item".to_string())?;

    let metadata = item.get("metadata").and_then(|v| v.as_object());
    let name = metadata
        .and_then(|m| m.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let duration_ms = to_i32_loose(metadata.and_then(|m| m.get("duration")));

    let mut mp4_files = Vec::new();
    let mut external_urls = Vec::new();

    if let Some(manifest) = item.get("manifest").and_then(|v| v.as_object()) {
        for (key, val) in manifest {
            if key == "file_urls_external" || key == "file_urls_mp3" {
                if let Some(arr) = val.as_array() {
                    for entry in arr {
                        if let Some(url_str) = entry.get("file_url").and_then(|v| v.as_str()) {
                            if let Ok(parsed) = reqwest::Url::parse(url_str) {
                                if parsed.scheme() == "https" && parsed.host_str().is_some_and(|h| !h.is_empty()) {
                                    external_urls.push(url_str.to_string());
                                }
                            }
                        }
                    }
                }
            }
            if !key.starts_with("file_ids_mp4") {
                continue;
            }
            if let Some(arr) = val.as_array() {
                for f in arr {
                    let Some(obj) = f.as_object() else {
                        continue;
                    };
                    let Some(fid) = obj.get("file_id").and_then(|v| v.as_str()) else {
                        continue;
                    };
                    let encoding_id = obj.get("encoding_id").and_then(|v| match v {
                        Value::Null => None,
                        Value::String(s) => Some(s.clone()),
                        other => Some(other.to_string()),
                    });
                    mp4_files.push(BackendPlaybackFile {
                        file_id_hex: fid.to_string(),
                        format: to_i32_loose(obj.get("format")),
                        bitrate: to_i32_loose(obj.get("bitrate")),
                        format_key: key.clone(),
                        encoding_id,
                    });
                }
            }
        }
    }

    Ok(BackendTrackPlaybackMedia {
        name,
        duration_ms,
        mp4_files,
        external_urls,
    })
}

/// 请求 `track-playback/v1/media` 并解析 MP4 与外部流列表。
pub async fn fetch_track_playback_media(
    spclient_base: &str,
    track_id_or_uri: &str,
) -> Result<BackendTrackPlaybackMedia, String> {
    let (uri, is_episode) = normalize_media_uri(track_id_or_uri);
    let base = spclient_base.trim_end_matches('/');
    let extra = if is_episode {
        "&manifestFileFormat=file_urls_external&manifestFileFormat=file_urls_mp3"
    } else {
        ""
    };
    let url = format!(
        "{base}/track-playback/v1/media/{uri}?manifestFileFormat=file_ids_mp4&manifestFileFormat=file_ids_mp4_cbcs{extra}"
    );
    let (status, body) = spotify_session::authorized_request(
        reqwest::Method::GET,
        &url,
        &[("Accept", "application/json")],
        None,
    )
    .await?;
    if status != 200 {
        return Err(format!("track-playback 失败：HTTP {status}"));
    }
    parse_track_playback_media_json(&body, &uri)
}

/// 拉取 `sneaktables/v2/hls/1/{fileIdHex}/audio.m3u8` 原始 HLS 清单。
pub async fn fetch_hls_manifest(spclient_base: &str, file_id_hex: &str) -> Result<String, String> {
    let base = spclient_base.trim_end_matches('/');
    let url = format!("{base}/sneaktables/v2/hls/1/{file_id_hex}/audio.m3u8");
    let (status, body) = spotify_session::authorized_request(
        reqwest::Method::GET,
        &url,
        &[("Accept", "application/vnd.apple.mpegurl")],
        None,
    )
    .await?;
    if status != 200 {
        return Err(format!("sneaktables HLS 清单失败：HTTP {status}"));
    }
    String::from_utf8(body).map_err(|e| format!("invalid m3u8 utf8:{e}"))
}

fn with_widevine_key_format(line: &str) -> String {
    let target = format!("KEYFORMAT=\"{WIDEVINE_KEY_FORMAT_UUID}\"");
    if line.contains(&target) {
        return line.to_string();
    }
    if let Some(start) = line.find("KEYFORMAT=\"") {
        let after = &line[start + "KEYFORMAT=\"".len()..];
        if let Some(end_quote) = after.find('"') {
            let mut out = String::with_capacity(line.len() + 32);
            out.push_str(&line[..start]);
            out.push_str(&target);
            out.push_str(&after[end_quote + 1..]);
            return out;
        }
    }
    format!("{line},{target}")
}

fn replace_quoted_uri(line: &str, replacement_uri: &str) -> String {
    let Some(start) = line.find("URI=\"") else {
        return line.to_string();
    };
    let after = &line[start + "URI=\"".len()..];
    let Some(end_quote) = after.find('"') else {
        return line.to_string();
    };
    let mut out = String::with_capacity(line.len() + replacement_uri.len());
    out.push_str(&line[..start]);
    out.push_str("URI=\"");
    out.push_str(replacement_uri);
    out.push('"');
    out.push_str(&after[end_quote + 1..]);
    out
}

/// 将 Spotify HLS 清单改写为指向本地回环 `{origin}/audio/current.m4a`。
pub fn localize_hls_manifest(
    m3u8: &str,
    origin: &str,
    widevine_key_format: bool,
    fair_play: bool,
    file_id_hex: Option<&str>,
) -> Result<String, String> {
    let local = format!("{}/audio/current.m4a", origin.trim_end_matches('/'));
    let mut out = Vec::new();
    for line in m3u8.split('\n') {
        if line.starts_with("#EXT-X-MAP:") {
            out.push(replace_quoted_uri(line, &local));
        } else if line.starts_with("#EXT-X-KEY:") && fair_play {
            let fid = file_id_hex
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| "FairPlay 清单生成失败：缺 file_id（FPS content ID）".to_string())?;
            out.push(format!(
                "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://{fid}\",KEYFORMATVERSIONS=\"1\",KEYFORMAT=\"{FAIRPLAY_KEY_FORMAT}\""
            ));
        } else if line.starts_with("#EXT-X-KEY:") && widevine_key_format {
            out.push(with_widevine_key_format(line));
        } else if line.starts_with("http") {
            out.push(local.clone());
        } else {
            out.push(line.to_string());
        }
    }
    Ok(out.join("\n"))
}

/// 多入口 DRM 请求转发（自动按 `hosts` 顺序在握手/网络失败时轮换，HTTP 响应则立即返回状态码与字节）。
pub async fn relay_drm_request(
    hosts: Vec<String>,
    method: &str,
    path_and_query: &str,
    bearer_token: Option<String>,
    client_token: &str,
    request_body: Option<Vec<u8>>,
    timeout_ms: u64,
) -> Result<BackendDrmRelayResult, String> {
    let m = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|e| format!("invalid method:{e}"))?;
    let client = spotify_session::client_for_url("https://spclient.wg.spotify.com")?;
    let timeout = Duration::from_millis(timeout_ms.max(1000));
    let mut last_err = "no hosts provided".to_string();

    for raw_host in hosts {
        let host = raw_host.trim().trim_end_matches('/');
        if host.is_empty() {
            continue;
        }
        let path = if path_and_query.starts_with('/') {
            path_and_query.to_string()
        } else {
            format!("/{path_and_query}")
        };
        let url = format!("https://{host}{path}");
        let mut req = client
            .request(m.clone(), &url)
            .header("client-token", client_token)
            .header("User-Agent", WEB_USER_AGENT)
            .header("Referer", "https://open.spotify.com/");
        if let Some(ref token) = bearer_token {
            if !token.is_empty() {
                req = req.header("Authorization", format!("Bearer {token}"));
            }
        }
        if let Some(ref b) = request_body {
            req = req
                .header("Content-Type", "application/octet-stream")
                .body(b.clone());
        }

        match tokio::time::timeout(timeout, req.send()).await {
            Ok(Ok(res)) => {
                let status = res.status().as_u16();
                let body = res
                    .bytes()
                    .await
                    .map_err(|e| format!("read body @ {host}:{e}"))?
                    .to_vec();
                return Ok(BackendDrmRelayResult { host: raw_host, status, body });
            }
            Ok(Err(e)) => {
                last_err = format!("{host}: {e}");
            }
            Err(_) => {
                last_err = format!("{host}: timeout");
            }
        }
    }

    Err(format!("license 失败（所有入口均不可达）：{last_err}"))
}

// ---------------------------------------------------------------------------
// Protobuf 元数据与 PlayPlay 密钥编解码
// ---------------------------------------------------------------------------

fn zigzag32(v: u64) -> i32 {
    let n = v as u32;
    ((n >> 1) as i32) ^ -((n & 1) as i32)
}

fn is_supported_audio_format(wire: i32) -> bool {
    matches!(
        wire,
        0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 16 | 18 | 19 | 20 | 22
    )
}

fn parse_audio_files(msg: &ProtoMsg<'_>) -> Vec<BackendProtoAudioFile> {
    let mut files = Vec::new();
    for f_msg in msg.msgs(12) {
        let Some(raw_id) = f_msg.bytes(1) else {
            continue;
        };
        if raw_id.len() != 20 || raw_id.iter().all(|&b| b == 0) {
            continue;
        }
        let fmt = if f_msg.has(2) {
            f_msg.integer(2) as i32
        } else {
            -1
        };
        if is_supported_audio_format(fmt) {
            files.push(BackendProtoAudioFile {
                file_id: raw_id.to_vec(),
                format: fmt,
            });
        }
    }
    files
}

/// 解析 `metadata.proto.Track`（含递归 `alternatives`）。
pub fn parse_track_metadata_proto(data: &[u8]) -> BackendProtoTrackMetadata {
    parse_track_msg(&ProtoMsg::parse(data))
}

fn parse_track_msg(msg: &ProtoMsg<'_>) -> BackendProtoTrackMetadata {
    let mut gid = vec![0u8; 16];
    if let Some(raw) = msg.bytes(1) {
        if raw.len() == 16 {
            gid.copy_from_slice(raw);
        }
    }
    let name = msg.str(2).to_string();
    let album_name = if msg.has(3) {
        msg.msg(3).str(2).to_string()
    } else {
        String::new()
    };
    let artist_names = msg
        .msgs(4)
        .into_iter()
        .filter(|a| a.has(2))
        .map(|a| a.str(2).to_string())
        .collect();
    let duration_ms = if msg.has(7) {
        zigzag32(msg.u64_val(7))
    } else {
        0
    };
    let explicit = msg.flag(9);
    let files = parse_audio_files(msg);
    let alternatives = msg
        .msgs(13)
        .iter()
        .map(parse_track_msg)
        .collect();

    BackendProtoTrackMetadata {
        gid,
        name,
        album_name,
        artist_names,
        duration_ms,
        explicit,
        files,
        alternatives,
    }
}

/// 解析 `metadata.proto.Episode`。
pub fn parse_episode_metadata_proto(data: &[u8]) -> BackendProtoEpisodeMetadata {
    let msg = ProtoMsg::parse(data);
    let mut gid = vec![0u8; 16];
    if let Some(raw) = msg.bytes(1) {
        if raw.len() == 16 {
            gid.copy_from_slice(raw);
        }
    }
    let name = msg.str(2).to_string();
    let duration_ms = if msg.has(7) {
        msg.integer(7) as i32
    } else {
        0
    };
    let files = parse_audio_files(&msg);
    let description = msg.str(64).to_string();
    let show_name = if msg.has(71) {
        msg.msg(71).str(2).to_string()
    } else {
        String::new()
    };
    BackendProtoEpisodeMetadata {
        gid,
        name,
        show_name,
        duration_ms,
        description,
        files,
    }
}

/// 构造 PlayPlay 密钥请求体。
pub fn encode_playplay_key_request(now_sec: i64) -> Vec<u8> {
    let mut w = Vec::with_capacity(64);
    proto_lite::write_varint(&mut w, (1 << 3) | 0);
    proto_lite::write_varint(&mut w, 5);
    proto_lite::write_bytes(&mut w, 2, &PLAYPLAY_REQK);
    proto_lite::write_varint(&mut w, (4 << 3) | 0);
    proto_lite::write_varint(&mut w, 1);
    proto_lite::write_varint(&mut w, (5 << 3) | 0);
    proto_lite::write_varint(&mut w, 1);
    proto_lite::write_varint(&mut w, (6 << 3) | 0);
    proto_lite::write_varint(&mut w, now_sec as u64);
    w
}

/// 解析 PlayPlay 密钥响应体（`0a10 <R1:16B> 1204 <R2:4B>`）。
pub fn parse_playplay_key_proto(data: &[u8]) -> Result<BackendPlayplayKey, String> {
    let msg = ProtoMsg::parse(data);
    let r1 = msg
        .all_bytes(1)
        .into_iter()
        .rfind(|b| b.len() == 16)
        .map(|b| b.to_vec());
    let r2 = msg
        .all_bytes(2)
        .into_iter()
        .rfind(|b| b.len() == 4)
        .map(|b| b.to_vec());
    match (r1, r2) {
        (Some(r1), Some(r2)) => Ok(BackendPlayplayKey { r1, r2 }),
        _ => Err(format!("playplay 响应缺 R1/R2（{}B）", data.len())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_track_playback_media_and_relinked_item() {
        let json = br#"{
            "media": {
                "spotify:track:relinked": {
                    "item": {
                        "metadata": { "name": "Song A", "duration": "215000" },
                        "manifest": {
                            "file_ids_mp4": [
                                { "file_id": "aaaa", "format": 10, "bitrate": 128000 }
                            ],
                            "file_ids_mp4_cbcs": [
                                { "file_id": "bbbb", "format": "11", "bitrate": "256000", "encoding_id": "enc1" }
                            ],
                            "file_urls_external": [
                                { "file_url": "https://cdn.example.com/ep.mp3" }
                            ]
                        }
                    }
                }
            }
        }"#;
        let media = parse_track_playback_media_json(json, "spotify:track:original").unwrap();
        assert_eq!(media.name, "Song A");
        assert_eq!(media.duration_ms, 215_000);
        assert_eq!(media.mp4_files.len(), 2);
        assert_eq!(media.mp4_files[0].file_id_hex, "aaaa");
        assert_eq!(media.mp4_files[1].encoding_id.as_deref(), Some("enc1"));
        assert_eq!(media.external_urls, vec!["https://cdn.example.com/ep.mp3"]);
    }

    #[test]
    fn localizes_hls_manifest_for_widevine_and_fairplay() {
        let m3u8 = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"data:text/plain;base64,AAA\"\n#EXT-X-MAP:URI=\"https://cdn.spotify.com/init.mp4\",BYTERANGE=\"720@0\"\nhttps://cdn.spotify.com/seg1.mp4";
        let wv = localize_hls_manifest(m3u8, "http://127.0.0.1:9999", true, false, None).unwrap();
        assert!(wv.contains("KEYFORMAT=\"urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed\""));
        assert!(wv.contains("#EXT-X-MAP:URI=\"http://127.0.0.1:9999/audio/current.m4a\",BYTERANGE=\"720@0\""));
        assert!(wv.ends_with("http://127.0.0.1:9999/audio/current.m4a"));

        let fp = localize_hls_manifest(m3u8, "http://127.0.0.1:9999", false, true, Some("0123456789abcdef")).unwrap();
        assert!(fp.contains("URI=\"skd://0123456789abcdef\""));
        assert!(fp.contains("KEYFORMAT=\"com.apple.streamingkeydelivery\""));
    }

    #[test]
    fn parses_track_and_playplay_protobuf() {
        let mut w = Vec::new();
        proto_lite::write_bytes(&mut w, 1, &[1u8; 16]);
        proto_lite::write_string(&mut w, 2, "Track Title");
        proto_lite::write_varint(&mut w, (7 << 3) | 0);
        proto_lite::write_varint(&mut w, 360_000); // zigzag(360_000) = 180_000
        proto_lite::write_bool(&mut w, 9, true);

        let mut file_w = Vec::new();
        proto_lite::write_bytes(&mut file_w, 1, &[0xab; 20]);
        proto_lite::write_varint(&mut file_w, (2 << 3) | 0);
        proto_lite::write_varint(&mut file_w, 1); // oggVorbis160
        proto_lite::write_bytes(&mut w, 12, &file_w);

        let parsed = parse_track_metadata_proto(&w);
        assert_eq!(parsed.name, "Track Title");
        assert_eq!(parsed.duration_ms, 180_000);
        assert!(parsed.explicit);
        assert_eq!(parsed.files.len(), 1);
        assert_eq!(parsed.files[0].format, 1);

        let mut pp = Vec::new();
        proto_lite::write_bytes(&mut pp, 1, &[0x11; 16]);
        proto_lite::write_bytes(&mut pp, 2, &[0x22; 4]);
        let key = parse_playplay_key_proto(&pp).unwrap();
        assert_eq!(key.r1, vec![0x11; 16]);
        assert_eq!(key.r2, vec![0x22; 4]);
    }
}
