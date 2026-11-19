//! Rust 网络的统一路由配置（单一事实来源）。
//!
//! Dart 只负责需要平台能力的部分（读系统代理 / PAC 求值、设置页、网关地区检测），把**解析后**的结果
//! 在启动时与每次变化时经 `rust_net_configure` 推送到这里；Rust 内所有不带逐请求代理的网络调用
//! （会话令牌续期、AP 长连接等）都按这里的配置选路：
//! - [NetConfig::proxy]：Spotify 主机应走的代理（`''` 直连，`http://[user:pass@]h:p` / `socks5h://h:p`），
//!   同时写入会话状态（`spotify_session::set_proxy`），作为 `effective_proxy()` 的默认值；
//! - [NetConfig::gateway]：用户自建的 Spotify 网关（HTTPS 反向代理 + `/__tunnel/` WebSocket 隧道）。
//!   启用时 AP 连接经网关隧道建立，apresolve 也经网关请求。

use std::sync::{OnceLock, RwLock};

use crate::spotify_session;

/// 自建网关（对照 Dart `SpotifyGateway`）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GatewayConfig {
    /// 已校验的网关前缀，如 `https://gateway.example/assets`（无结尾斜杠）。
    pub base: String,
    pub username: String,
    pub password: String,
    /// 连接**网关主机**时使用的代理（按网关主机选取，可能与 [NetConfig::proxy] 不同）。
    pub proxy: String,
}

impl GatewayConfig {
    fn prefix(&self) -> &str {
        self.base.trim_end_matches('/')
    }

    /// 网关凭据头（`X-Proxy-User` / `X-Proxy-Pass`）。
    pub fn headers(&self) -> Vec<(String, String)> {
        vec![
            ("X-Proxy-User".to_string(), self.username.clone()),
            ("X-Proxy-Pass".to_string(), self.password.clone()),
        ]
    }

    /// 与 Dart `SpotifyGateway.route` 一致：`{base}/{host}{path}?{query}`。
    pub fn route(&self, host: &str, path_and_query: &str) -> String {
        let rest = if path_and_query.is_empty() { "/" } else { path_and_query };
        format!("{}/{host}{rest}", self.prefix())
    }

    /// 与 Dart `SpotifyGateway.tunnel` 一致：`wss://…/__tunnel/{host}:{port}`。
    pub fn tunnel_url(&self, host: &str, port: u16) -> Result<String, String> {
        if !gateway_supports_ap(host, port) {
            return Err(format!("gateway:unsupported access point {host}:{port}"));
        }
        let prefix = self.prefix();
        let rest = prefix
            .strip_prefix("https://")
            .ok_or_else(|| "gateway:invalid base".to_string())?;
        Ok(format!("wss://{rest}/__tunnel/{host}:{port}"))
    }
}

/// 网关隧道只接受 Spotify 接入点（与 Dart `SpotifyGateway.tunnel` 的白名单一致）：
/// `ap.spotify.com` / `ap-xxx.spotify.com` / `*accesspoint*.spotify.com` / `*.ap.spotify.com`，端口 80 / 443 / 4070。
pub fn gateway_supports_ap(host: &str, port: u16) -> bool {
    if ![80, 443, 4070].contains(&port) {
        return false;
    }
    let Some(prefix) = host.strip_suffix(".spotify.com") else {
        return false;
    };
    let label = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit());
    let dotted = |s: &str| {
        !s.is_empty() && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'.')
    };
    if !dotted(prefix) {
        return false;
    }
    prefix == "ap"
        || prefix.strip_prefix("ap-").is_some_and(label)
        || prefix.contains("accesspoint")
        || prefix.strip_suffix(".ap").is_some_and(|s| !s.is_empty())
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NetConfig {
    pub proxy: String,
    pub gateway: Option<GatewayConfig>,
}

fn store() -> &'static RwLock<NetConfig> {
    static CONFIG: OnceLock<RwLock<NetConfig>> = OnceLock::new();
    CONFIG.get_or_init(|| RwLock::new(NetConfig::default()))
}

/// 替换当前配置（同时更新会话默认代理）。
pub fn set(config: NetConfig) {
    spotify_session::set_proxy(config.proxy.clone());
    *store().write().unwrap_or_else(|e| e.into_inner()) = config;
}

pub fn get() -> NetConfig {
    store().read().unwrap_or_else(|e| e.into_inner()).clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gateway() -> GatewayConfig {
        GatewayConfig {
            base: "https://gateway.example/assets-test".into(),
            username: "test-user".into(),
            password: "pw".into(),
            proxy: String::new(),
        }
    }

    #[test]
    fn tunnel_and_route_match_dart_gateway() {
        let g = gateway();
        assert_eq!(
            g.tunnel_url("ap-gew4.spotify.com", 4070).unwrap(),
            "wss://gateway.example/assets-test/__tunnel/ap-gew4.spotify.com:4070"
        );
        assert_eq!(
            g.route("apresolve.spotify.com", "/?type=accesspoint"),
            "https://gateway.example/assets-test/apresolve.spotify.com/?type=accesspoint"
        );
        assert_eq!(g.headers()[0], ("X-Proxy-User".to_string(), "test-user".to_string()));
    }

    #[test]
    fn tunnel_only_accepts_access_points() {
        assert!(gateway_supports_ap("ap.spotify.com", 443));
        assert!(gateway_supports_ap("ap-gue1.spotify.com", 80));
        assert!(gateway_supports_ap("gew4-accesspoint-b-abcd.ap.spotify.com", 4070));
        assert!(gateway_supports_ap("foo.ap.spotify.com", 4070));
        assert!(!gateway_supports_ap("ap.spotify.com", 8080));
        assert!(!gateway_supports_ap("api.spotify.com", 443));
        assert!(!gateway_supports_ap("ap-.spotify.com", 443));
        assert!(!gateway_supports_ap("ap.spotify.com.evil.com", 443));
        assert!(!gateway_supports_ap("AP.spotify.com", 443));
        assert!(gateway().tunnel_url("evil.example", 443).is_err());
    }
}
