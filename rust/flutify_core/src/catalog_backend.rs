//! 播客 `initialState` 解析、Canvas 媒体下载及歌单备份文件原子落盘。

use std::fs;
use std::io::Write;
use std::path::Path;
use std::time::Duration;

use base64::Engine as _;
use futures_util::StreamExt;
use serde_json::{json, Value};

use crate::spotify_backend::BackendImage;
use crate::spotify_session;

const PODCAST_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";
const CANVAS_LIMIT_BYTES: usize = 12 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct BackendPodcastEpisode {
    pub id: String,
    pub uri: String,
    pub name: String,
    pub description: String,
    pub duration_ms: i32,
    pub release_date: String,
    pub images: Vec<BackendImage>,
    pub show_uri: String,
    pub show_name: String,
    pub preview_url: String,
    pub resume_ms: i32,
    pub played: bool,
}

#[derive(Clone, Debug)]
pub struct BackendPodcastShow {
    pub id: String,
    pub uri: String,
    pub name: String,
    pub publisher: String,
    pub description: String,
    pub images: Vec<BackendImage>,
    pub episodes: Vec<BackendPodcastEpisode>,
}

#[derive(Clone, Debug)]
pub struct BackendCanvasMedia {
    pub url: String,
    pub is_video: bool,
    pub bytes: Vec<u8>,
}

fn parse_cover_art(cover_art: Option<&Value>) -> Vec<BackendImage> {
    let Some(sources) = cover_art
        .and_then(|c| c.get("sources"))
        .and_then(|s| s.as_array())
    else {
        return Vec::new();
    };
    let mut images = Vec::with_capacity(sources.len());
    for s in sources {
        let Some(url) = s.get("url").and_then(|v| v.as_str()).filter(|u| !u.is_empty()) else {
            continue;
        };
        let width = s.get("width").and_then(|v| v.as_i64()).map(|v| v as i32);
        let height = s.get("height").and_then(|v| v.as_i64()).map(|v| v as i32);
        images.push(BackendImage {
            url: url.to_string(),
            width,
            height,
        });
    }
    images.sort_by_key(|a| std::cmp::Reverse(a.width.unwrap_or(0)));
    images
}

fn extract_initial_state_json(html: &str) -> Result<Value, String> {
    let marker = r#"<script id="initialState""#;
    let Some(start_tag) = html.find(marker) else {
        return Err("页面结构已变化，无法解析".to_string());
    };
    let after_marker = &html[start_tag + marker.len()..];
    let Some(gt) = after_marker.find('>') else {
        return Err("页面结构已变化，无法解析".to_string());
    };
    let content_start = &after_marker[gt + 1..];
    let Some(end_script) = content_start.find("</script>") else {
        return Err("页面结构已变化，无法解析".to_string());
    };
    let b64 = content_start[..end_script].trim();
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|_| "页面数据无法解析".to_string())?;
    serde_json::from_slice::<Value>(&decoded).map_err(|_| "页面数据无法解析".to_string())
}

fn parse_episode_from_data(
    raw: Option<&Value>,
    show_uri: &str,
    show_name: &str,
) -> Option<BackendPodcastEpisode> {
    let data = raw?.as_object()?;
    if data.get("__typename").and_then(|v| v.as_str()) != Some("Episode") {
        return None;
    }
    let uri = data.get("uri").and_then(|v| v.as_str()).unwrap_or("");
    let id = if let Some(rest) = uri.strip_prefix("spotify:episode:") {
        rest.to_string()
    } else {
        data.get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    if id.is_empty() {
        return None;
    }

    let played_state = data.get("playedState").and_then(|v| v.as_object());
    let resume_ms = played_state
        .and_then(|p| p.get("playPositionMilliseconds"))
        .and_then(|v| v.as_i64())
        .unwrap_or(0) as i32;
    let played = played_state
        .and_then(|p| p.get("state"))
        .and_then(|v| v.as_str())
        == Some("FINISHED");

    let mut preview_url = String::new();
    if let Some(items) = data
        .get("audio")
        .and_then(|a| a.get("items"))
        .and_then(|i| i.as_array())
    {
        for a in items {
            if let Some(u) = a.get("url").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
                preview_url = u.to_string();
                break;
            }
        }
    }

    let release_date = match data.get("releaseDate") {
        Some(Value::Object(m)) => m
            .get("isoString")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    };

    let duration_ms = match data.get("duration") {
        Some(Value::Object(m)) => m
            .get("totalMilliseconds")
            .and_then(|v| v.as_i64())
            .unwrap_or(0) as i32,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) as i32,
        _ => 0,
    };

    Some(BackendPodcastEpisode {
        id,
        uri: uri.to_string(),
        name: data
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        description: data
            .get("description")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        duration_ms,
        release_date,
        images: parse_cover_art(data.get("coverArt")),
        show_uri: show_uri.to_string(),
        show_name: show_name.to_string(),
        preview_url,
        resume_ms: if played { 0 } else { resume_ms },
        played,
    })
}

/// 从节目页 HTML 解析 `BackendPodcastShow`。
pub fn parse_podcast_show_html(show_id: &str, html: &str) -> Result<BackendPodcastShow, String> {
    let state = extract_initial_state_json(html)?;
    let key = format!("spotify:show:{show_id}");
    let show = state
        .get("entities")
        .and_then(|e| e.get("items"))
        .and_then(|i| i.get(&key))
        .and_then(|s| s.as_object())
        .ok_or_else(|| "没有找到对应的节目".to_string())?;

    let uri = show
        .get("uri")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or(key);
    let name = show
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let publisher = match show.get("publisher") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Object(m)) => m
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        _ => String::new(),
    };
    let description = show
        .get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let images = parse_cover_art(show.get("coverArt"));

    let mut episodes = Vec::new();
    if let Some(items) = show
        .get("pages")
        .and_then(|p| p.get("items"))
        .and_then(|i| i.as_array())
    {
        for item in items {
            let entity_data = item.get("entity").and_then(|e| e.get("data"));
            if let Some(ep) = parse_episode_from_data(entity_data, &uri, &name) {
                episodes.push(ep);
            }
        }
    }

    Ok(BackendPodcastShow {
        id: show_id.to_string(),
        uri,
        name,
        publisher,
        description,
        images,
        episodes,
    })
}

/// 从单集页 HTML 解析 `BackendPodcastEpisode`。
pub fn parse_podcast_episode_html(
    episode_id: &str,
    html: &str,
) -> Result<BackendPodcastEpisode, String> {
    let state = extract_initial_state_json(html)?;
    let key = format!("spotify:episode:{episode_id}");
    let data = state
        .get("entities")
        .and_then(|e| e.get("items"))
        .and_then(|i| i.get(&key))
        .ok_or_else(|| "没有找到对应的单集".to_string())?;

    if data.get("__typename").and_then(|v| v.as_str()) != Some("Episode") {
        return Err("没有找到对应的单集".to_string());
    }

    let wrapper = data
        .get("showOrAudiobook")
        .or_else(|| data.get("podcastV2"));
    let show_data = wrapper.and_then(|w| w.get("data")).or(wrapper);
    let show_uri = show_data
        .and_then(|s| s.get("uri"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let show_name = show_data
        .and_then(|s| s.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let mut episode = parse_episode_from_data(Some(data), show_uri, show_name)
        .ok_or_else(|| "单集数据无法解析".to_string())?;
    if episode.images.is_empty() {
        let show_covers = parse_cover_art(show_data.and_then(|s| s.get("coverArt")));
        if !show_covers.is_empty() {
            episode.images = show_covers;
        }
    }
    Ok(episode)
}

async fn fetch_podcast_html(url: &str) -> Result<String, String> {
    let client = spotify_session::client_for_url(url)?;
    let res = tokio::time::timeout(
        Duration::from_secs(15),
        client
            .get(url)
            .header("User-Agent", PODCAST_USER_AGENT)
            .header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
            .send(),
    )
    .await
    .map_err(|_| "网络请求失败，请检查网络：timeout".to_string())?
    .map_err(|e| format!("网络请求失败，请检查网络：{e}"))?;

    let status = res.status().as_u16();
    if status != 200 {
        return Err(format!("http:{status}:加载失败"));
    }
    let bytes = res
        .bytes()
        .await
        .map_err(|e| format!("网络请求失败，请检查网络：{e}"))?;
    String::from_utf8(bytes.to_vec()).map_err(|_| "页面数据无法解析".to_string())
}

pub async fn fetch_podcast_show(show_id: &str) -> Result<BackendPodcastShow, String> {
    let html = fetch_podcast_html(&format!("https://open.spotify.com/show/{show_id}")).await?;
    parse_podcast_show_html(show_id, &html)
}

pub async fn fetch_podcast_episode(episode_id: &str) -> Result<BackendPodcastEpisode, String> {
    let html =
        fetch_podcast_html(&format!("https://open.spotify.com/episode/{episode_id}")).await?;
    parse_podcast_episode_html(episode_id, &html)
}

/// 查询 Pathfinder `canvas` 并下载媒体字节（限制 12 MB）。
pub async fn fetch_canvas(hash: &str, track_uri: &str) -> Result<Option<BackendCanvasMedia>, String> {
    let data = spotify_session::pathfinder_query(
        "canvas",
        hash,
        json!({ "trackUri": track_uri }),
    )
    .await?;

    let Some(track) = data.get("trackUnion").and_then(|v| v.as_object()) else {
        return Ok(None);
    };
    if track.get("__typename").and_then(|v| v.as_str()) != Some("Track") {
        return Ok(None);
    }
    let Some(canvas) = track.get("canvas").and_then(|v| v.as_object()) else {
        return Ok(None);
    };
    let Some(url_str) = canvas.get("url").and_then(|v| v.as_str()) else {
        return Ok(None);
    };
    let Ok(parsed_url) = reqwest::Url::parse(url_str) else {
        return Ok(None);
    };
    if parsed_url.scheme() != "https" || parsed_url.host_str().unwrap_or("").is_empty() {
        return Ok(None);
    }
    let Some(kind) = canvas.get("type").and_then(|v| v.as_str()) else {
        return Ok(None);
    };
    if !matches!(
        kind,
        "VIDEO" | "VIDEO_LOOPING" | "VIDEO_LOOPING_RANDOM" | "IMAGE" | "GIF"
    ) {
        return Ok(None);
    }
    let is_video = kind != "IMAGE" && kind != "GIF";

    let client = spotify_session::client_for_url(url_str)?;
    let res = tokio::time::timeout(Duration::from_secs(12), client.get(url_str).send())
        .await
        .map_err(|_| "canvas timeout".to_string())?
        .map_err(|e| format!("canvas:{e}"))?;
    if res.status().as_u16() != 200 {
        return Err(format!("Canvas HTTP {}", res.status().as_u16()));
    }
    if res.content_length().unwrap_or(0) as usize > CANVAS_LIMIT_BYTES {
        return Err("Canvas exceeds size limit".to_string());
    }

    let mut stream = res.bytes_stream();
    let mut bytes = Vec::new();
    while let Some(chunk_res) = tokio::time::timeout(Duration::from_secs(12), stream.next())
        .await
        .map_err(|_| "canvas stream timeout".to_string())?
    {
        let chunk = chunk_res.map_err(|e| format!("canvas chunk:{e}"))?;
        if bytes.len() + chunk.len() > CANVAS_LIMIT_BYTES {
            return Err("Canvas exceeds size limit".to_string());
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Ok(None);
    }

    Ok(Some(BackendCanvasMedia {
        url: url_str.to_string(),
        is_video,
        bytes,
    }))
}

/// 原子写入歌单备份文件（先写 `.tmp` 并 flush，再原子替换为目标文件）。
pub fn write_backup_file_atomic(file_path: &str, content: &str) -> Result<(), String> {
    let target = Path::new(file_path);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("mkdir:{e}"))?;
    }
    let tmp_path = format!("{file_path}.tmp");
    {
        let mut f = fs::File::create(&tmp_path).map_err(|e| format!("create tmp:{e}"))?;
        f.write_all(content.as_bytes())
            .map_err(|e| format!("write tmp:{e}"))?;
        f.sync_all().map_err(|e| format!("sync tmp:{e}"))?;
    }
    if fs::rename(&tmp_path, target).is_err() {
        let mut f = fs::File::create(target).map_err(|e| format!("create target:{e}"))?;
        f.write_all(content.as_bytes())
            .map_err(|e| format!("write target:{e}"))?;
        f.sync_all().map_err(|e| format!("sync target:{e}"))?;
        let _ = fs::remove_file(&tmp_path);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_podcast_show_and_episode_from_initial_state_html() {
        let state = json!({
            "entities": {
                "items": {
                    "spotify:show:show123": {
                        "uri": "spotify:show:show123",
                        "name": "Tech Show",
                        "publisher": { "name": "Publisher Inc" },
                        "description": "Show desc",
                        "coverArt": { "sources": [{ "url": "https://img/show.jpg", "width": 640, "height": 640 }] },
                        "pages": {
                            "items": [
                                {
                                    "entity": {
                                        "data": {
                                            "__typename": "Episode",
                                            "uri": "spotify:episode:ep1",
                                            "name": "Ep 1",
                                            "description": "Ep desc",
                                            "duration": { "totalMilliseconds": 60000 },
                                            "releaseDate": { "isoString": "2026-10-01" },
                                            "audio": { "items": [{ "url": "https://cdn/p.mp3" }] }
                                        }
                                    }
                                }
                            ]
                        }
                    }
                }
            }
        });
        let b64 = base64::engine::general_purpose::STANDARD.encode(state.to_string());
        let html = format!("<html><body><script id=\"initialState\" type=\"text/plain\">{b64}</script></body></html>");
        let show = parse_podcast_show_html("show123", &html).unwrap();
        assert_eq!(show.name, "Tech Show");
        assert_eq!(show.publisher, "Publisher Inc");
        assert_eq!(show.episodes.len(), 1);
        assert_eq!(show.episodes[0].id, "ep1");
        assert_eq!(show.episodes[0].preview_url, "https://cdn/p.mp3");
    }
}
