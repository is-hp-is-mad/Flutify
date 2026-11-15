//! LRCLIB / 网易云 / QQ 音乐公开歌词接口（reqwest + 代理路由 + 429/503 退避）。

use std::time::Duration;

use serde_json::Value;

use crate::spotify_session;

#[derive(Debug, Clone)]
pub struct BackendLrclibCandidate {
    pub id: i64,
    pub track_name: String,
    pub artist_name: String,
    pub album_name: String,
    pub duration_sec: f64,
    pub instrumental: bool,
    pub plain_lyrics: String,
    pub synced_lyrics: String,
}

#[derive(Debug, Clone)]
pub struct BackendLrclibResponse {
    pub candidates: Vec<BackendLrclibCandidate>,
    pub network_error: bool,
}

fn parse_lrclib_candidate(v: &Value) -> Option<BackendLrclibCandidate> {
    let obj = v.as_object()?;
    let id = obj.get("id").and_then(|x| x.as_i64()).unwrap_or(0);
    let track_name = obj
        .get("trackName")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let artist_name = obj
        .get("artistName")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let album_name = obj
        .get("albumName")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let duration_sec = obj
        .get("duration")
        .and_then(|x| x.as_f64())
        .unwrap_or(0.0);
    let instrumental = obj
        .get("instrumental")
        .and_then(|x| x.as_bool())
        .unwrap_or(false);
    let plain_lyrics = obj
        .get("plainLyrics")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let synced_lyrics = obj
        .get("syncedLyrics")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    Some(BackendLrclibCandidate {
        id,
        track_name,
        artist_name,
        album_name,
        duration_sec,
        instrumental,
        plain_lyrics,
        synced_lyrics,
    })
}

async fn lrclib_request(path: &str, params: &[(&str, &str)]) -> BackendLrclibResponse {
    let Ok(mut url) = reqwest::Url::parse(&format!("https://lrclib.net/api{path}")) else {
        return BackendLrclibResponse {
            candidates: Vec::new(),
            network_error: true,
        };
    };
    {
        let mut qp = url.query_pairs_mut();
        for (k, v) in params {
            if !v.is_empty() {
                qp.append_pair(k, v);
            }
        }
    }
    let client = match spotify_session::client_for_url(url.as_str()) {
        Ok(c) => c,
        Err(_) => {
            return BackendLrclibResponse {
                candidates: Vec::new(),
                network_error: true,
            }
        }
    };

    for attempt in 0..3 {
        let req = client
            .get(url.clone())
            .header("User-Agent", "Flutify (lyrics fallback)")
            .header("Accept", "application/json");
        if let Ok(Ok(res)) = tokio::time::timeout(Duration::from_secs(12), req.send()).await {
            let code = res.status().as_u16();
            if code == 404 {
                return BackendLrclibResponse {
                    candidates: Vec::new(),
                    network_error: false,
                };
            }
            if code == 200 {
                let Ok(bytes) = res.bytes().await else {
                    return BackendLrclibResponse {
                        candidates: Vec::new(),
                        network_error: true,
                    };
                };
                let Ok(val) = serde_json::from_slice::<Value>(&bytes) else {
                    return BackendLrclibResponse {
                        candidates: Vec::new(),
                        network_error: false,
                    };
                };
                let candidates = match val {
                    Value::Array(arr) => {
                        arr.iter().filter_map(parse_lrclib_candidate).collect()
                    }
                    Value::Object(_) => parse_lrclib_candidate(&val).into_iter().collect(),
                    _ => Vec::new(),
                };
                return BackendLrclibResponse {
                    candidates,
                    network_error: false,
                };
            }
            if code == 429 || (code == 503 && attempt == 2) {
                return BackendLrclibResponse {
                    candidates: Vec::new(),
                    network_error: true,
                };
            }
        }
        if attempt < 2 {
            tokio::time::sleep(Duration::from_millis(250 * (attempt as u64 + 1))).await;
        }
    }
    BackendLrclibResponse {
        candidates: Vec::new(),
        network_error: true,
    }
}

pub async fn lrclib_get(
    track: &str,
    artist: &str,
    album: &str,
    duration_sec: i32,
) -> BackendLrclibResponse {
    let dur_str = if duration_sec > 0 {
        duration_sec.to_string()
    } else {
        String::new()
    };
    lrclib_request(
        "/get",
        &[
            ("track_name", track),
            ("artist_name", artist),
            ("album_name", album),
            ("duration", &dur_str),
        ],
    )
    .await
}

pub async fn lrclib_search(track: &str, artist: &str, q: &str) -> BackendLrclibResponse {
    lrclib_request(
        "/search",
        &[("track_name", track), ("artist_name", artist), ("q", q)],
    )
    .await
}

/// 通用带代理的歌词第三方 HTTP 请求（供网易云 / QQ 音乐使用）。
pub async fn lyrics_http_request(
    method: &str,
    url: &str,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
) -> Result<(u16, Vec<u8>), String> {
    let client = spotify_session::client_for_url(url)?;
    let m = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|e| format!("invalid method:{e}"))?;
    let mut req = client.request(m, url);
    for (k, v) in headers {
        req = req.header(&k, &v);
    }
    if let Some(b) = body {
        req = req.body(b);
    }
    let res = tokio::time::timeout(Duration::from_secs(12), req.send())
        .await
        .map_err(|_| "lyrics:timeout".to_string())?
        .map_err(|e| format!("lyrics:{e}"))?;
    let status = res.status().as_u16();
    let bytes = res
        .bytes()
        .await
        .map_err(|e| format!("lyrics_body:{e}"))?
        .to_vec();
    Ok((status, bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_lrclib_candidate_reads_fields() {
        let v = json!({
            "id": 99,
            "trackName": "Song",
            "artistName": "Artist",
            "albumName": "Album",
            "duration": 180.5,
            "instrumental": false,
            "plainLyrics": "a\nb",
            "syncedLyrics": "[00:01.00]a"
        });
        let c = parse_lrclib_candidate(&v).unwrap();
        assert_eq!(c.id, 99);
        assert_eq!(c.track_name, "Song");
        assert_eq!(c.synced_lyrics, "[00:01.00]a");
    }
}
