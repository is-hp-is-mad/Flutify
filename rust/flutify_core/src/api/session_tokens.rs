//! 会话令牌续期（Web `access_token` / `client-token`），按本次请求的代理发出。
//!
//! 与 `backend::rust_ensure_*` 相同的单飞与 epoch 语义（结果只在会话 epoch 未变时写回 Rust 会话），
//! 区别是代理由 Dart 按目标地址选路后传入：Rust 会话里的全局代理不随 Dart 的代理设置同步。

use crate::api::backend::RustTokenResult;
use crate::http_client;
use crate::spotify_session;

/// 单飞获取 Web `access_token`；`force_refresh` 为 true 时忽略缓存，用会话里的 `sp_dc` 重新铸造。
pub async fn rust_session_ensure_web_access_token(
    force_refresh: bool,
    proxy: String,
) -> Result<RustTokenResult, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let minted = spotify_session::ensure_web_access_token(force_refresh).await?;
            Ok(RustTokenResult {
                token: minted.token,
                expiry_ms: minted.expiry_ms,
            })
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

/// 单飞获取 Web 播放器 `client-token`；`force_refresh` 为 true 时忽略缓存重新申请。
pub async fn rust_session_ensure_client_token(
    force_refresh: bool,
    proxy: String,
) -> Result<RustTokenResult, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let granted = spotify_session::ensure_client_token(force_refresh).await?;
            Ok(RustTokenResult {
                token: granted.token,
                expiry_ms: granted.expiry_ms,
            })
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}
