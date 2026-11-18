//! Spotify Connect 状态接口（connect-state/v1 HTTP）与 Dealer 控制面消息辅助。

use crate::spotify_session;

/// 通过 Rust 会话通道发送 `connect-state/v1` 请求（自动带 Bearer、client-token、401 刷新及代理）。
pub async fn connect_state_request(
    spclient_host: &str,
    method: &str,
    path: &str,
    connection_id: &str,
    body_json: Option<String>,
) -> Result<(u16, Vec<u8>), String> {
    let m = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|e| format!("invalid method:{e}"))?;
    let host = spclient_host.trim().trim_end_matches('/');
    let url = format!("https://{host}{path}");
    let headers = [
        ("Content-Type", "application/json"),
        ("X-Spotify-Connection-Id", connection_id),
    ];
    let body = body_json.map(|s| s.into_bytes());
    spotify_session::authorized_request(m, &url, &headers, body).await
}

/// 通过 Rust HTTP/2 客户端发送 `track-playback/v1/devices` 请求（保留调用方按 `deviceId` 绑定的凭据与版本头）。
pub async fn track_playback_request(
    spclient_host: &str,
    method: &str,
    path: &str,
    bearer_token: &str,
    client_token: &str,
    app_version: &str,
    proxy: &str,
    body_json: Option<String>,
) -> Result<(u16, Vec<u8>), String> {
    let m = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|e| format!("invalid method:{e}"))?;
    let host = spclient_host.trim().trim_end_matches('/');
    let url = format!("https://{host}{path}");
    let client = spotify_session::client_for_proxy(proxy)?;
    let mut req = client
        .request(m, &url)
        .header("Authorization", format!("Bearer {bearer_token}"))
        .header("client-token", client_token)
        .header(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36",
        )
        .header("Origin", "https://open.spotify.com")
        .header("Referer", "https://open.spotify.com/")
        .header("app-platform", "WebPlayer")
        .header("spotify-app-version", app_version)
        .header("Content-Type", "application/json");
    if let Some(body) = body_json {
        req = req.body(body);
    }
    let res = tokio::time::timeout(std::time::Duration::from_secs(10), req.send())
        .await
        .map_err(|_| "track-playback timeout".to_string())?
        .map_err(|e| format!("track-playback:{e}"))?;
    let status = res.status().as_u16();
    let bytes = res
        .bytes()
        .await
        .map_err(|e| format!("track-playback body:{e}"))?
        .to_vec();
    Ok((status, bytes))
}
