//! Spotify 会话与令牌生命周期管理（Rust 统一网络核心）。
//!
//! 集中维护 `sp_dc`、Web `access_token`、`client-token` 与当前代理地址：
//! - 单飞互斥锁（`tokio::sync::Mutex`）防止并发请求同时触发重复铸造；
//! - `authorized_get` / `authorized_post` / `pathfinder_query` 自动附带鉴权头与代理，
//!   遇到 401 时自动单飞续期并重试一次，遇到 429/503 时按退避策略重试。

use std::sync::{OnceLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::Mutex;

use crate::http_client;
use crate::web_totp;

const TOKEN_ENDPOINT: &str = "https://open.spotify.com/api/token";
const SERVER_TIME_ENDPOINT: &str = "https://open.spotify.com/api/server-time";
const CLIENT_TOKEN_ENDPOINT: &str = "https://clienttoken.spotify.com/v1/clienttoken";
const PATHFINDER_ENDPOINT: &str = "https://api-partner.spotify.com/pathfinder/v2/query";

const WEB_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36";
const WEB_CLIENT_ID: &str = "d8a5ed958d274c2e8ee717e6a4b0971d";
/// 与 Dart `SpotifyAuthConstants.webClientVersion` 保持一致：client-token 与业务请求头须同一身份。
const WEB_CLIENT_VERSION: &str = "1.3.8.509.g26b6eac7300d";
const TOTP_VERSION: u32 = 61;
const OBFUSCATED_SECRET_V61: &str = r#",7/*F("rLJ2oxaKL^f+E1xvP@N"#;

/// 提前 60 秒视为过期，避免临界点发出 401 请求。
const EXPIRY_LEEWAY_MS: i64 = 60_000;

#[derive(Clone, Debug, Default)]
pub struct SessionState {
    pub sp_dc: String,
    pub access_token: String,
    pub access_token_expiry_ms: i64,
    pub client_token: String,
    pub client_token_expiry_ms: i64,
    pub device_id: String,
    pub proxy: String,
    pub epoch: u64,
}

#[derive(Clone, Debug)]
pub struct MintedToken {
    pub token: String,
    pub expiry_ms: i64,
}

#[derive(Clone, Debug)]
pub struct GrantedClientToken {
    pub token: String,
    pub expiry_ms: i64,
}

struct SessionRuntime {
    state: RwLock<SessionState>,
    access_refresh_lock: Mutex<()>,
    client_refresh_lock: Mutex<()>,
}

fn runtime_state() -> &'static SessionRuntime {
    static INSTANCE: OnceLock<SessionRuntime> = OnceLock::new();
    INSTANCE.get_or_init(|| SessionRuntime {
        state: RwLock::new(SessionState::default()),
        access_refresh_lock: Mutex::new(()),
        client_refresh_lock: Mutex::new(()),
    })
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn is_fresh(expiry_ms: i64) -> bool {
    expiry_ms > now_ms() + EXPIRY_LEEWAY_MS
}

/// 更新或初始化 Rust 会话状态（Dart 登录 / 启动恢复 / 刷新后同步）。
pub fn configure_session(next: SessionState) {
    let mut guard = runtime_state()
        .state
        .write()
        .unwrap_or_else(|e| e.into_inner());
    *guard = next;
}

/// 仅更新代理地址。
pub fn set_proxy(proxy: String) {
    let mut guard = runtime_state()
        .state
        .write()
        .unwrap_or_else(|e| e.into_inner());
    guard.proxy = proxy;
}

/// 清空会话凭证（保留代理配置）。
pub fn clear_session() {
    let mut guard = runtime_state()
        .state
        .write()
        .unwrap_or_else(|e| e.into_inner());
    let proxy = guard.proxy.clone();
    let epoch = guard.epoch.wrapping_add(1);
    *guard = SessionState {
        proxy,
        epoch,
        ..SessionState::default()
    };
}

pub fn snapshot() -> SessionState {
    runtime_state()
        .state
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

tokio::task_local! {
    static REQUEST_PROXY: String;
}

pub(crate) async fn with_request_proxy<F, T>(proxy: String, f: F) -> T
where
    F: std::future::Future<Output = T>,
{
    REQUEST_PROXY.scope(proxy, f).await
}

pub(crate) fn effective_proxy() -> String {
    REQUEST_PROXY
        .try_with(|p| p.clone())
        .unwrap_or_else(|_| snapshot().proxy)
}

pub(crate) fn client_for_proxy(proxy: &str) -> Result<reqwest::Client, String> {
    http_client::client_for(proxy)
}

pub(crate) fn client_for_url(_url: &str) -> Result<reqwest::Client, String> {
    let proxy = effective_proxy();
    http_client::client_for(&proxy)
}

/// 使用给定的 `sp_dc` 与 `proxy` 独立铸造 Web `access_token`（供登录与多账号备份复用）。
pub async fn mint_web_token(sp_dc: &str, proxy: &str) -> Result<MintedToken, String> {
    if sp_dc.is_empty() {
        return Err("auth:missing sp_dc".to_string());
    }
    let client = http_client::client_for(proxy)?;
    let secret = web_totp::deobfuscate_secret(OBFUSCATED_SECRET_V61);
    let local_now = now_ms();
    let totp_now = web_totp::totp(&secret, local_now, 30, 6);

    let mut totp_server = "unavailable".to_string();
    if let Ok(Ok(st_res)) = tokio::time::timeout(
        Duration::from_secs(4),
        client.get(SERVER_TIME_ENDPOINT).send(),
    )
    .await
    {
        if let Ok(bytes) = st_res.bytes().await {
            if let Ok(val) = serde_json::from_slice::<Value>(&bytes) {
                if let Some(st) = val.get("serverTime").and_then(|v| v.as_i64()) {
                    totp_server = web_totp::totp(&secret, st * 1000, 30, 6);
                }
            }
        }
    }

    let res = tokio::time::timeout(
        Duration::from_secs(10),
        client
            .get(TOKEN_ENDPOINT)
            .query(&[
                ("reason", "transport"),
                ("productType", "web-player"),
                ("totp", totp_now.as_str()),
                ("totpVer", &TOTP_VERSION.to_string()),
                ("totpServer", totp_server.as_str()),
            ])
            .header("Cookie", format!("sp_dc={sp_dc}"))
            .header("User-Agent", WEB_USER_AGENT)
            .header("Accept", "application/json")
            .send(),
    )
    .await
    .map_err(|_| "timeout:/api/token timed out".to_string())?
    .map_err(|e| format!("request:/api/token failed: {e}"))?;

    let status = res.status().as_u16();
    let body = res
        .bytes()
        .await
        .map_err(|e| format!("request:read /api/token body failed: {e}"))?;
    if status != 200 {
        return Err(format!("http:{status}:/api/token"));
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct TokenPayload {
        access_token: Option<String>,
        access_token_expiration_timestamp_ms: Option<i64>,
    }

    let parsed: TokenPayload = serde_json::from_slice(&body)
        .map_err(|e| format!("decode:/api/token invalid json: {e}"))?;
    let token = parsed
        .access_token
        .filter(|t| !t.is_empty())
        .ok_or_else(|| "decode:/api/token missing accessToken".to_string())?;
    let expiry_ms = parsed
        .access_token_expiration_timestamp_ms
        .unwrap_or(now_ms() + 3_600_000);
    Ok(MintedToken { token, expiry_ms })
}

/// 单飞获取有效 `access_token`；若缓存有效直接返回，否则加锁用 `sp_dc` 刷新。
pub async fn ensure_web_access_token(force_refresh: bool) -> Result<MintedToken, String> {
    if !force_refresh {
        let s = snapshot();
        if !s.access_token.is_empty() && is_fresh(s.access_token_expiry_ms) {
            return Ok(MintedToken {
                token: s.access_token,
                expiry_ms: s.access_token_expiry_ms,
            });
        }
    }

    let _lock = runtime_state().access_refresh_lock.lock().await;
    let s = snapshot();
    if !force_refresh && !s.access_token.is_empty() && is_fresh(s.access_token_expiry_ms) {
        return Ok(MintedToken {
            token: s.access_token,
            expiry_ms: s.access_token_expiry_ms,
        });
    }
    let proxy = effective_proxy();
    let minted = mint_web_token(&s.sp_dc, &proxy).await?;
    let mut guard = runtime_state().state.write().unwrap();
    if guard.epoch == s.epoch {
        guard.access_token = minted.token.clone();
        guard.access_token_expiry_ms = minted.expiry_ms;
    }
    Ok(minted)
}

/// 申请 Web `client-token`（对齐 `open.spotify.com`）。
pub async fn request_web_client_token(
    device_id: &str,
    proxy: &str,
) -> Result<GrantedClientToken, String> {
    let client = http_client::client_for(proxy)?;
    let payload = json!({
        "client_data": {
            "client_version": WEB_CLIENT_VERSION,
            "client_id": WEB_CLIENT_ID,
            "js_sdk_data": {
                "device_brand": "unknown",
                "device_model": "unknown",
                "os": "windows",
                "os_version": "NT 10.0",
                "device_id": device_id,
                "device_type": "computer",
            }
        }
    });
    let res = tokio::time::timeout(
        Duration::from_secs(10),
        client
            .post(CLIENT_TOKEN_ENDPOINT)
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .header("User-Agent", WEB_USER_AGENT)
            .body(payload.to_string())
            .send(),
    )
    .await
    .map_err(|_| "timeout:clienttoken timed out".to_string())?
    .map_err(|e| format!("request:clienttoken failed: {e}"))?;

    let status = res.status().as_u16();
    if status != 200 {
        return Err(format!("http:{status}:clienttoken"));
    }
    let bytes = res
        .bytes()
        .await
        .map_err(|e| format!("request:read clienttoken failed: {e}"))?;
    let val: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("decode:clienttoken: {e}"))?;
    let granted = val
        .get("granted_token")
        .ok_or_else(|| "decode:clienttoken missing granted_token".to_string())?;
    let token = granted
        .get("token")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "decode:clienttoken missing token".to_string())?
        .to_string();
    let refresh_after = granted
        .get("refresh_after_seconds")
        .and_then(|v| v.as_i64())
        .unwrap_or(1_209_600);
    let expires_after = granted
        .get("expires_after_seconds")
        .and_then(|v| v.as_i64())
        .unwrap_or(refresh_after);
    let ttl_sec = refresh_after.min(expires_after).max(60);
    Ok(GrantedClientToken {
        token,
        expiry_ms: now_ms() + ttl_sec * 1000,
    })
}

/// 单飞获取有效 `client-token`。
pub async fn ensure_client_token(force_refresh: bool) -> Result<GrantedClientToken, String> {
    if !force_refresh {
        let s = snapshot();
        if !s.client_token.is_empty() && is_fresh(s.client_token_expiry_ms) {
            return Ok(GrantedClientToken {
                token: s.client_token,
                expiry_ms: s.client_token_expiry_ms,
            });
        }
    }

    let _lock = runtime_state().client_refresh_lock.lock().await;
    let s = snapshot();
    if !force_refresh && !s.client_token.is_empty() && is_fresh(s.client_token_expiry_ms) {
        return Ok(GrantedClientToken {
            token: s.client_token,
            expiry_ms: s.client_token_expiry_ms,
        });
    }
    if s.device_id.is_empty() {
        return Err("auth:missing device_id".to_string());
    }
    let proxy = effective_proxy();
    let granted = request_web_client_token(&s.device_id, &proxy).await?;
    let mut guard = runtime_state().state.write().unwrap();
    if guard.epoch == s.epoch {
        guard.client_token = granted.token.clone();
        guard.client_token_expiry_ms = granted.expiry_ms;
    }
    Ok(granted)
}

/// 发送带鉴权的 HTTP 请求，自动处理 401 单飞续期与 429/503 退避重试。
pub async fn authorized_request(
    method: reqwest::Method,
    url: &str,
    extra_headers: &[(&str, &str)],
    body: Option<Vec<u8>>,
) -> Result<(u16, Vec<u8>), String> {
    let mut refreshed_auth = false;
    let mut backoff_ms = 400u64;

    for attempt in 0..4 {
        let access = ensure_web_access_token(false).await?;
        let client_tok = ensure_client_token(false).await.ok().map(|g| g.token);
        let proxy = effective_proxy();
        let client = http_client::client_for(&proxy)?;

        let mut req = client
            .request(method.clone(), url)
            .header("Authorization", format!("Bearer {}", access.token))
            .header("User-Agent", WEB_USER_AGENT)
            .header("app-platform", "WebPlayer")
            .header("spotify-app-version", WEB_CLIENT_VERSION);
        if let Some(ct) = client_tok.as_deref().filter(|v| !v.is_empty()) {
            req = req.header("client-token", ct);
        }
        for (k, v) in extra_headers {
            req = req.header(*k, *v);
        }
        if let Some(ref bytes) = body {
            req = req.body(bytes.clone());
        }

        let res = tokio::time::timeout(Duration::from_secs(20), req.send())
            .await
            .map_err(|_| format!("timeout:{url}"))?
            .map_err(|e| format!("request:{e}"))?;
        let status = res.status().as_u16();
        let retry_after = res
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok());
        let resp_bytes = res
            .bytes()
            .await
            .map_err(|e| format!("request:read body failed: {e}"))?
            .to_vec();

        if status == 401
            && attempt < 3
            && !refreshed_auth
            && !snapshot().sp_dc.is_empty()
            && ensure_web_access_token(true).await.is_ok()
        {
            refreshed_auth = true;
            continue;
        }
        if (status == 429 || status == 503) && attempt < 3 {
            let wait_ms = retry_after
                .map(|sec| sec.clamp(1, 10) * 1000)
                .unwrap_or(backoff_ms);
            tokio::time::sleep(Duration::from_millis(wait_ms)).await;
            backoff_ms = (backoff_ms * 2).min(4000);
            continue;
        }
        return Ok((status, resp_bytes));
    }
    Err(format!("http:429:{url}"))
}

/// 执行 Pathfinder GraphQL POST 查询并返回原始 JSON `data` 对象。
pub async fn pathfinder_query(
    operation_name: &str,
    sha256_hash: &str,
    variables: Value,
) -> Result<Value, String> {
    let payload = json!({
        "variables": variables,
        "operationName": operation_name,
        "extensions": {
            "persistedQuery": {
                "version": 1,
                "sha256Hash": sha256_hash,
            }
        }
    });
    let (status, bytes) = authorized_request(
        reqwest::Method::POST,
        PATHFINDER_ENDPOINT,
        &[
            ("Accept", "application/json"),
            ("Content-Type", "application/json;charset=UTF-8"),
        ],
        Some(payload.to_string().into_bytes()),
    )
    .await?;

    let val: Value = serde_json::from_slice(&bytes)
        .map_err(|e| format!("decode:pathfinder {operation_name}: {e}"))?;
    if status != 200 {
        return Err(format!("http:{status}:pathfinder {operation_name}"));
    }
    val.get("data")
        .cloned()
        .filter(|d| d.is_object())
        .ok_or_else(|| format!("pathfinder:{operation_name}:missing data"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configure_and_clear_session_preserves_proxy_and_bumps_epoch() {
        configure_session(SessionState {
            sp_dc: "dc-1".to_string(),
            access_token: "at-1".to_string(),
            access_token_expiry_ms: now_ms() + 120_000,
            client_token: "ct-1".to_string(),
            client_token_expiry_ms: now_ms() + 120_000,
            device_id: "dev-1".to_string(),
            proxy: "http://127.0.0.1:7890".to_string(),
            epoch: 7,
        });
        let snap = snapshot();
        assert_eq!(snap.sp_dc, "dc-1");
        assert_eq!(snap.proxy, "http://127.0.0.1:7890");

        clear_session();
        let cleared = snapshot();
        assert!(cleared.sp_dc.is_empty());
        assert!(cleared.access_token.is_empty());
        assert_eq!(cleared.proxy, "http://127.0.0.1:7890");
        assert_eq!(cleared.epoch, 8);
    }
}
