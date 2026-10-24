//! HTTP/2 客户端（reqwest + rustls）：Spotify API 这类同时发十几个请求的场景，
//! 在一条连接上多路复用，省掉 dart:io（仅 HTTP/1.1）为每个并发请求各建一次连接 / 握手。
//!
//! 只负责「直连」的请求；网关、代理（含 PAC / 认证代理）、证书诊断仍由 Dart 网络层处理，
//! 是否交给这里由 Dart 侧决定（见 lib/services/network/http2_client.dart）。
//! 证书同时信任系统证书库与 Mozilla 根证书（公司网络的 HTTPS 检查代理照常可用）。

use std::sync::OnceLock;
use std::time::Duration;

use tokio::runtime::Runtime;

pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<HttpHeader>,
    pub body: Vec<u8>,
    /// 实际协商到的协议（`HTTP/2.0` / `HTTP/1.1`），诊断用。
    pub version: String,
}

/// 错误前缀：`connect:` 表示请求还没发出（建连 / TLS 失败），调用方可以安全地改用其他通道重试；
/// `timeout:` / `request:` 表示请求可能已发出，不应自动重试。
pub type HttpResult = Result<HttpResponse, String>;

/// 网络任务共用的 tokio 运行时（HTTP / 下载 / WebSocket）。
pub fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("flutify-http")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// 共享的 reqwest 客户端（同一连接池；HTTP/2 下同主机共用一条连接）。
pub fn shared_client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            // 代理由 Dart 侧判断：交到这里的都是直连，不读环境变量里的代理
            .no_proxy()
            .connect_timeout(Duration::from_secs(15))
            .pool_idle_timeout(Duration::from_secs(90))
            // 与 dart:io 一致：不自动跟随重定向，交给上层处理
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("http client")
    })
}

fn classify(error: &reqwest::Error) -> String {
    if error.is_connect() {
        format!("connect:{error}")
    } else if error.is_timeout() {
        format!("timeout:{error}")
    } else {
        format!("request:{error}")
    }
}

async fn execute(
    method: String,
    url: String,
    headers: Vec<HttpHeader>,
    body: Vec<u8>,
    timeout_ms: u64,
) -> HttpResult {
    let method = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|e| format!("connect:bad method: {e}"))?;
    let mut request = shared_client()
        .request(method, &url)
        .timeout(Duration::from_millis(timeout_ms.max(1)));
    for header in headers {
        // HTTP/2 禁止连接级头部；host 由 :authority 表达
        let lower = header.name.to_ascii_lowercase();
        if matches!(
            lower.as_str(),
            "host" | "connection" | "keep-alive" | "transfer-encoding" | "upgrade" | "content-length"
        ) {
            continue;
        }
        request = request.header(header.name, header.value);
    }
    if !body.is_empty() {
        request = request.body(body);
    }
    let response = request.send().await.map_err(|e| classify(&e))?;
    let status = response.status().as_u16();
    let version = format!("{:?}", response.version());
    let headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| {
            Some(HttpHeader {
                name: name.as_str().to_string(),
                value: value.to_str().ok()?.to_string(),
            })
        })
        .collect();
    let body = response
        .bytes()
        .await
        .map_err(|e| format!("request:{e}"))?
        .to_vec();
    Ok(HttpResponse {
        status,
        headers,
        body,
        version,
    })
}

/// 发一个请求并读完整个响应体。在独立的 tokio 运行时上执行，调用方（frb 线程）只等待结果，
/// 多个并发调用共享同一个连接池（HTTP/2 下即同一条连接）。
pub async fn send(
    method: String,
    url: String,
    headers: Vec<HttpHeader>,
    body: Vec<u8>,
    timeout_ms: u64,
) -> HttpResult {
    runtime()
        .spawn(execute(method, url, headers, body, timeout_ms))
        .await
        .map_err(|e| format!("request:task failed: {e}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block<F: std::future::Future>(f: F) -> F::Output {
        // 测试里用独立的 current-thread 运行时驱动（模拟 frb 的非 tokio 执行器）
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(f)
    }

    #[test]
    fn unreachable_host_is_a_connect_error() {
        // 127.0.0.1:1 没有监听：建连失败，属于可以安全改走其他通道的错误
        let result = block(send("GET".into(), "https://127.0.0.1:1/".into(), vec![], vec![], 3000));
        let error = result.err().expect("should fail");
        assert!(error.starts_with("connect:"), "{error}");
    }

    #[test]
    fn invalid_method_is_rejected_before_sending() {
        let result = block(send("BAD METHOD".into(), "https://example.com/".into(), vec![], vec![], 3000));
        assert!(result.err().unwrap().starts_with("connect:"));
    }

    /// 真实网络：确认能与 Spotify 协商出 HTTP/2。默认忽略（CI 无网络），本地 `cargo test -- --ignored` 跑。
    #[test]
    #[ignore]
    fn negotiates_http2_with_spotify() {
        let response = block(send(
            "GET".into(),
            "https://spclient.wg.spotify.com/".into(),
            vec![],
            vec![],
            15000,
        ))
        .expect("request");
        assert_eq!(response.version, "HTTP/2.0");
    }
}
