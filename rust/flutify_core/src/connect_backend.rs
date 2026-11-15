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
