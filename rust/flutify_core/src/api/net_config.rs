//! 统一网络配置的 Dart 接口：Dart 解析系统代理 / PAC / 手动代理 / 自建网关后，启动时与变化时推送一次，
//! Rust 内的网络（会话令牌续期、AP 长连接等）按它选路（见 `crate::net_config`）。

use crate::ap_client;
use crate::http_client;
use crate::net_config::{self, GatewayConfig, NetConfig};

/// 解析后的网络配置。
pub struct RustNetConfig {
    /// Spotify 主机应走的代理：`''` 直连，否则 `http://[user:pass@]host:port` / `socks5h://host:port`。
    pub proxy: String,
    /// 自建网关前缀（已校验的 `https://host/prefix`）；空表示未启用网关。
    pub gateway_base: String,
    pub gateway_username: String,
    pub gateway_password: String,
    /// 连接网关主机所用的代理（格式同 [proxy]）。
    pub gateway_proxy: String,
}

/// 替换当前网络配置（同时作为 Rust 会话的默认代理）。
#[flutter_rust_bridge::frb(sync)]
pub fn rust_net_configure(config: RustNetConfig) {
    let gateway = (!config.gateway_base.is_empty()).then(|| GatewayConfig {
        base: config.gateway_base,
        username: config.gateway_username,
        password: config.gateway_password,
        proxy: config.gateway_proxy,
    });
    net_config::set(NetConfig {
        proxy: config.proxy,
        gateway,
    });
}

/// AP 登录结果（会话 id 供后续取密钥 / Mercury 使用）。
pub struct RustApSessionDto {
    pub session_id: u64,
    pub canonical_username: String,
    pub reusable_auth_type: i32,
    pub reusable_auth: Vec<u8>,
}

/// 按当前网络配置（代理 / 自建网关隧道）连接接入点并登录。[host] 与 [port] 都给出时只连该接入点，
/// 否则经 apresolve 解析并依次尝试。
///
/// 错误：`ap_login:{code}[:{desc}]`（服务端拒绝登录）、`gateway:…`（网关不支持该接入点）、
/// `connect:…` / `ap:…`（网络 / 协议）。
pub async fn rust_ap_open(
    host: Option<String>,
    port: Option<u16>,
    username: String,
    auth_type: i32,
    auth_data: Vec<u8>,
    device_id: String,
) -> Result<RustApSessionDto, String> {
    http_client::runtime()
        .spawn(async move {
            let w = ap_client::ap_connect_configured(host, port, &username, auth_type, &auth_data, &device_id)
                .await?;
            Ok(RustApSessionDto {
                session_id: w.session_id,
                canonical_username: w.canonical_username,
                reusable_auth_type: w.reusable_auth_type,
                reusable_auth: w.reusable_auth,
            })
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}
