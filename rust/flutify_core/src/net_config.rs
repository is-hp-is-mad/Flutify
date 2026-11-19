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

/// 与 Dart `SpotifyGateway.supports` 一致：哪些 HTTP(S) 地址经网关转发。
///
/// 只认默认端口、无用户信息；`accounts.spotify.com` 只转 `/api/token`，`open.spotify.com` 只转
/// `/api/token` 与 `/api/server-time`（浏览器登录流程不经网关）；另含 Widevine provisioning、
/// Spotify API / CDN 主机与 `*spotify*.*akamaized.net`。
pub fn gateway_supports(url: &reqwest::Url) -> bool {
    let scheme = url.scheme();
    if !matches!(scheme, "http" | "https") || !url.username().is_empty() || url.password().is_some() {
        return false;
    }
    if let Some(port) = url.port() {
        if port != if scheme == "http" { 80 } else { 443 } {
            return false;
        }
    }
    let Some(host) = url.host_str() else {
        return false;
    };
    let host = host.to_ascii_lowercase();
    let path = url.path();
    match host.as_str() {
        "accounts.spotify.com" => return path == "/api/token",
        "open.spotify.com" => return path == "/api/token" || path == "/api/server-time",
        _ => {}
    }
    if is_widevine_provisioning(url, &host) {
        return true;
    }
    if [
        "api.spotify.com",
        "apresolve.spotify.com",
        "api-partner.spotify.com",
        "clienttoken.spotify.com",
        "spclient.wg.spotify.com",
        "betamax.akamaized.net",
    ]
    .contains(&host.as_str())
    {
        return true;
    }
    if ["spclient.spotify.com", "scdn.co", "spotifycdn.com"]
        .iter()
        .any(|d| host == *d || host.ends_with(&format!(".{d}")))
    {
        return true;
    }
    spotify_service_host(&host) || spotify_akamai_host(&host)
}

fn is_widevine_provisioning(url: &reqwest::Url, host: &str) -> bool {
    url.scheme() == "https"
        && url.port().is_none()
        && ((host == "www.googleapis.com" && url.path() == "/certificateprovisioning/v1/devicecertificates/create")
            || (host == "provisioning.googleapis.com" && url.path() == "/v1/devicecertificates/create"))
}

fn label_chars(s: &str) -> bool {
    s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// `^[a-z0-9-]*(spclient|dealer|audio|video)[a-z0-9-]*(\.[a-z0-9-]+)*\.spotify\.com$`
fn spotify_service_host(host: &str) -> bool {
    let Some(prefix) = host.strip_suffix(".spotify.com") else {
        return false;
    };
    let mut labels = prefix.split('.');
    let Some(first) = labels.next() else {
        return false;
    };
    label_chars(first)
        && ["spclient", "dealer", "audio", "video"].iter().any(|k| first.contains(k))
        && labels.all(|l| !l.is_empty() && label_chars(l))
}

/// `^[a-z0-9-]*spotify[a-z0-9-]*\.[a-z0-9.-]*akamaized\.net$`
fn spotify_akamai_host(host: &str) -> bool {
    let Some((first, rest)) = host.split_once('.') else {
        return false;
    };
    label_chars(first)
        && first.contains("spotify")
        && rest.ends_with("akamaized.net")
        && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'.')
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
    fn gateway_supports_matches_dart_rules() {
        let ok = |u: &str| gateway_supports(&reqwest::Url::parse(u).unwrap());
        assert!(ok("https://accounts.spotify.com/api/token"));
        assert!(!ok("https://accounts.spotify.com/login"));
        assert!(ok("https://open.spotify.com/api/server-time"));
        assert!(!ok("https://open.spotify.com/show/x"));
        assert!(ok("https://api-partner.spotify.com/pathfinder/v2/query"));
        assert!(ok("https://spclient.wg.spotify.com/x"));
        assert!(ok("https://gew4-spclient.spotify.com/x"));
        assert!(!ok("https://audio-ak.spotify.com.edgesuite.net/x"));
        assert!(ok("https://audio4-ak-spotify-com.akamaized.net/x"));
        assert!(ok("https://gew1-dealer.spotify.com/"));
        assert!(ok("https://i.scdn.co/image/x"));
        assert!(ok("https://scdn.co/x"));
        assert!(ok("https://foo.spotifycdn.com/x"));
        assert!(ok("https://www.googleapis.com/certificateprovisioning/v1/devicecertificates/create"));
        assert!(!ok("https://www.googleapis.com/other"));
        assert!(!ok("https://api.spotify.com:8443/v1/me"));
        assert!(!ok("https://user:pw@api.spotify.com/v1/me"));
        assert!(!ok("https://gateway.example/assets/api.spotify.com/v1/me"));
        assert!(!ok("https://evilspotify.com/x"));
        assert!(!ok("https://spclient.spotify.com.evil.com/x"));
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
