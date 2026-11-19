//! Spotify 会话与令牌生命周期管理（Rust 统一网络核心）。
//!
//! 集中维护 `sp_dc`、Web `access_token`、`client-token` 与当前代理地址：
//! - 单飞互斥锁（`tokio::sync::Mutex`）防止并发请求同时触发重复铸造；
//! - `authorized_get` / `authorized_post` / `pathfinder_query` 自动附带鉴权头与代理，
//!   遇到 401 时自动单飞续期并重试一次，遇到 429/503 时按退避策略重试。

use std::sync::{Arc, OnceLock, RwLock};
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
///
/// 代理的唯一来源是 `net_config`（Dart 经 `rust_net_configure` 推送）：[next] 的 `proxy` 为空时
/// 保留当前代理，不会把已推送的配置冲掉。
pub fn configure_session(mut next: SessionState) {
    let mut guard = runtime_state()
        .state
        .write()
        .unwrap_or_else(|e| e.into_inner());
    if next.proxy.is_empty() {
        next.proxy = guard.proxy.clone();
    }
    *guard = next;
}

/// 仅更新代理地址（由 `net_config::set` 调用）。
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

tokio::task_local! {
    /// 任务级会话覆盖（多账号备份）：作用域内的鉴权请求改用这份凭据，续期结果也只写回这里，不影响主会话。
    static REQUEST_SESSION: Arc<std::sync::Mutex<SessionState>>;
}

/// 在 [state] 这份会话凭据下执行 [f]（见 [`REQUEST_SESSION`]）。
/// `access_token_expiry_ms` 为 0 时视为已过期，首个请求前用 `sp_dc` 铸造。
pub(crate) async fn with_session<F, T>(state: SessionState, f: F) -> T
where
    F: std::future::Future<Output = T>,
{
    REQUEST_SESSION
        .scope(Arc::new(std::sync::Mutex::new(state)), f)
        .await
}

fn session_override() -> Option<Arc<std::sync::Mutex<SessionState>>> {
    REQUEST_SESSION.try_with(Arc::clone).ok()
}

/// 当前生效的会话（任务级覆盖优先）。
fn current_session() -> SessionState {
    match session_override() {
        Some(s) => s.lock().unwrap_or_else(|e| e.into_inner()).clone(),
        None => snapshot(),
    }
}

/// `tokio::spawn`，但把当前任务的请求级代理与会话覆盖带进新任务（task-local 不会自动继承）。
pub(crate) fn spawn_scoped<F, T>(f: F) -> tokio::task::JoinHandle<T>
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let proxy = REQUEST_PROXY.try_with(Clone::clone).ok();
    let session = session_override();
    tokio::spawn(async move {
        match (proxy, session) {
            (Some(p), Some(s)) => REQUEST_PROXY.scope(p, REQUEST_SESSION.scope(s, f)).await,
            (Some(p), None) => REQUEST_PROXY.scope(p, f).await,
            (None, Some(s)) => REQUEST_SESSION.scope(s, f).await,
            (None, None) => f.await,
        }
    })
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
    if let Some(ov) = session_override() {
        return ensure_override_access_token(&ov, force_refresh).await;
    }
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
    if let Some(ov) = session_override() {
        return ensure_override_client_token(&ov, force_refresh).await;
    }
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

/// 任务级会话的 access_token：未过期直接用，否则用它自己的 `sp_dc` 铸造并写回覆盖（备份任务串行执行，不需要单飞）。
async fn ensure_override_access_token(
    ov: &Arc<std::sync::Mutex<SessionState>>,
    force_refresh: bool,
) -> Result<MintedToken, String> {
    let s = ov.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if !force_refresh && !s.access_token.is_empty() && is_fresh(s.access_token_expiry_ms) {
        return Ok(MintedToken {
            token: s.access_token,
            expiry_ms: s.access_token_expiry_ms,
        });
    }
    let minted = mint_web_token(&s.sp_dc, &effective_proxy()).await?;
    let mut guard = ov.lock().unwrap_or_else(|e| e.into_inner());
    guard.access_token = minted.token.clone();
    guard.access_token_expiry_ms = minted.expiry_ms;
    Ok(minted)
}

/// 任务级会话的 client-token：有就用；没有且给了 device_id 时申请一次。
async fn ensure_override_client_token(
    ov: &Arc<std::sync::Mutex<SessionState>>,
    force_refresh: bool,
) -> Result<GrantedClientToken, String> {
    let s = ov.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if !force_refresh && !s.client_token.is_empty() && is_fresh(s.client_token_expiry_ms) {
        return Ok(GrantedClientToken {
            token: s.client_token,
            expiry_ms: s.client_token_expiry_ms,
        });
    }
    if s.device_id.is_empty() {
        return Err("auth:missing device_id".to_string());
    }
    let granted = request_web_client_token(&s.device_id, &effective_proxy()).await?;
    let mut guard = ov.lock().unwrap_or_else(|e| e.into_inner());
    guard.client_token = granted.token.clone();
    guard.client_token_expiry_ms = granted.expiry_ms;
    Ok(granted)
}

/// 鉴权请求的请求头：默认以 Web 播放器身份发出，[extra] 中的同名头（不分大小写）**覆盖**默认值。
///
/// 不能用 `RequestBuilder::header` 逐个追加：同名头会变成两份（如 `app-platform: WebPlayer` 与
/// `app-platform: Android` 并存），服务端按 WebPlayer 处理，Android 身份的 Watch Feed 接口因此返回空内容。
fn request_headers(
    access_token: &str,
    client_token: Option<&str>,
    extra: &[(&str, &str)],
) -> Result<reqwest::header::HeaderMap, String> {
    use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
    let mut map = HeaderMap::new();
    let mut set = |name: &str, value: &str| -> Result<(), String> {
        let name = HeaderName::from_bytes(name.as_bytes()).map_err(|e| format!("request:header {name}: {e}"))?;
        let value = HeaderValue::from_str(value).map_err(|e| format!("request:header value: {e}"))?;
        map.insert(name, value);
        Ok(())
    };
    set("authorization", &format!("Bearer {access_token}"))?;
    set("user-agent", WEB_USER_AGENT)?;
    set("app-platform", "WebPlayer")?;
    set("spotify-app-version", WEB_CLIENT_VERSION)?;
    if let Some(ct) = client_token.filter(|v| !v.is_empty()) {
        set("client-token", ct)?;
    }
    for (k, v) in extra {
        set(k, v)?;
    }
    Ok(map)
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

        let headers = request_headers(&access.token, client_tok.as_deref(), extra_headers)?;
        let mut req = client.request(method.clone(), url).headers(headers);
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
            && !current_session().sp_dc.is_empty()
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

    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(f)
    }

    #[test]
    fn session_override_is_task_scoped_and_inherited_by_spawn_scoped() {
        let far = now_ms() + 3_600_000;
        let state = SessionState {
            sp_dc: "backup-dc".to_string(),
            access_token: "backup-at".to_string(),
            access_token_expiry_ms: far,
            client_token: "backup-ct".to_string(),
            client_token_expiry_ms: far,
            ..SessionState::default()
        };
        let (direct, spawned, outside) = block_on(async {
            let inside = with_session(state, async {
                let direct = ensure_web_access_token(false).await.unwrap().token;
                let spawned = spawn_scoped(async {
                    (
                        ensure_web_access_token(false).await.unwrap().token,
                        ensure_client_token(false).await.unwrap().token,
                        current_session().sp_dc,
                    )
                })
                .await
                .unwrap();
                (direct, spawned)
            })
            .await;
            (inside.0, inside.1, session_override().is_none())
        });
        assert_eq!(direct, "backup-at");
        assert_eq!(
            spawned,
            ("backup-at".to_string(), "backup-ct".to_string(), "backup-dc".to_string())
        );
        // 作用域外不受影响
        assert!(outside);
    }

    #[test]
    fn extra_headers_override_defaults_instead_of_duplicating() {
        let h = request_headers(
            "tok",
            Some("ct"),
            &[("App-Platform", "Android"), ("user-agent", "Spotify/9 Android"), ("accept", "application/protobuf")],
        )
        .unwrap();
        let all = |n: &str| h.get_all(n).iter().map(|v| v.to_str().unwrap().to_string()).collect::<Vec<_>>();
        assert_eq!(all("app-platform"), ["Android"]);
        assert_eq!(all("user-agent"), ["Spotify/9 Android"]);
        assert_eq!(all("spotify-app-version"), [WEB_CLIENT_VERSION]);
        assert_eq!(all("authorization"), ["Bearer tok"]);
        assert_eq!(all("client-token"), ["ct"]);
        assert_eq!(all("accept"), ["application/protobuf"]);
        let no_ct = request_headers("tok", Some(""), &[]).unwrap();
        assert!(no_ct.get("client-token").is_none());
    }

    #[test]
    fn spawn_scoped_keeps_request_proxy() {
        let proxy = block_on(with_request_proxy("socks5h://127.0.0.1:1".to_string(), async {
            spawn_scoped(async { effective_proxy() }).await.unwrap()
        }));
        assert_eq!(proxy, "socks5h://127.0.0.1:1");
    }

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
