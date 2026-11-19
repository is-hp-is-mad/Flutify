//! HTTP/2 客户端（reqwest + rustls）：Spotify API 这类同时发十几个请求的场景，
//! 在一条连接上多路复用，省掉 dart:io（仅 HTTP/1.1）为每个并发请求各建一次连接 / 握手。
//!
//! 代理地址由 Dart 按系统 / PAC / 手动设置算好后传入（[client_for]）；Spotify 请求经统一出口 [send]，
//! 启用自建网关时在这里改写到网关（配置由 `net_config` 推送）。证书诊断仍在 Dart 网络层。
//! 证书同时信任系统证书库与 Mozilla 根证书（公司网络的 HTTPS 检查代理照常可用）。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
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

/// 按代理地址缓存的 reqwest 客户端（同一代理共用连接池；HTTP/2 下同主机共用一条连接）。
/// [proxy] 为空表示直连；否则为 `http://[user:pass@]host:port` 或 `socks5h://…`（由 Dart 侧按系统 /
/// PAC / 手动设置算出）。代理地址无效时返回错误（以 `connect:` 开头，调用方可改走 Dart）。
pub fn client_for(proxy: &str) -> Result<reqwest::Client, String> {
    static CLIENTS: OnceLock<Mutex<HashMap<String, reqwest::Client>>> = OnceLock::new();
    let clients = CLIENTS.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(client) = clients.lock().unwrap().get(proxy) {
        return Ok(client.clone());
    }
    let mut builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .pool_idle_timeout(Duration::from_secs(90))
        // 与 dart:io 一致：不自动跟随重定向，交给上层处理
        .redirect(reqwest::redirect::Policy::none());
    builder = if proxy.is_empty() {
        // 直连：不读环境变量里的代理（选路由 Dart 决定）
        builder.no_proxy()
    } else {
        builder.proxy(reqwest::Proxy::all(proxy).map_err(|e| format!("connect:bad proxy: {e}"))?)
    };
    let client = builder.build().map_err(|e| format!("connect:{e}"))?;
    clients.lock().unwrap().insert(proxy.to_string(), client.clone());
    Ok(client)
}

/// [send] 的错误：保留 reqwest 错误（调用方可能要区分建连 / 超时），其余为说明文字。
#[derive(Debug)]
pub enum SendError {
    Http(reqwest::Error),
    Other(String),
}

impl std::fmt::Display for SendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SendError::Http(e) => write!(f, "{e}"),
            SendError::Other(s) => f.write_str(s),
        }
    }
}

/// `RequestBuilder::send` 的替代：经 [send] 发出（自建网关改写 / 重定向在这里处理）。
pub trait RoutedSend {
    fn send_routed(self) -> impl std::future::Future<Output = Result<reqwest::Response, SendError>> + Send;
}

impl RoutedSend for reqwest::RequestBuilder {
    fn send_routed(self) -> impl std::future::Future<Output = Result<reqwest::Response, SendError>> + Send {
        send(self)
    }
}

/// 网关模式下最多跟随的重定向次数（与 Dart `GatewayHttpClient.maxRedirects` 一致）。
const GATEWAY_MAX_REDIRECTS: usize = 5;

/// Spotify 请求的统一出口：未启用自建网关时原样发出（不跟随重定向，行为与以前一致）；
/// 启用网关且目标属于 [crate::net_config::gateway_supports] 时，改写为 `{网关}/{host}{path}?{query}`、
/// 带上网关凭据头、经**网关主机**的代理发出，并像 Dart `GatewayHttpClient` 一样逐跳经网关跟随
/// GET / HEAD（及 POST 的 303）重定向，禁止 HTTPS 降级。
///
/// 已由 Dart 改写成网关地址的请求（下载、HTTP/2 通道）也可以经过这里：网关主机本身不在支持列表里，不会二次改写。
pub async fn send(builder: reqwest::RequestBuilder) -> Result<reqwest::Response, SendError> {
    let (client, request) = builder.build_split();
    let request = request.map_err(SendError::Http)?;
    match crate::net_config::get().gateway {
        Some(gateway) if crate::net_config::gateway_supports(request.url()) => {
            send_via_gateway(request, &gateway).await
        }
        _ => client.execute(request).await.map_err(SendError::Http),
    }
}

async fn send_via_gateway(
    request: reqwest::Request,
    gateway: &crate::net_config::GatewayConfig,
) -> Result<reqwest::Response, SendError> {
    use reqwest::header::{HeaderName, HeaderValue, CONTENT_LENGTH, CONTENT_TYPE, LOCATION};

    let gateway_client = client_for(&gateway.proxy).map_err(SendError::Other)?;
    let mut target = request.url().clone();
    let mut method = request.method().clone();
    let mut headers = request.headers().clone();
    let timeout = request.timeout().copied();
    let mut body = request.body().and_then(|b| b.as_bytes()).map(<[u8]>::to_vec);

    for hop in 0..=GATEWAY_MAX_REDIRECTS {
        let supported = crate::net_config::gateway_supports(&target);
        let url = if supported {
            let mut path = target.path().to_string();
            if let Some(q) = target.query() {
                path.push('?');
                path.push_str(q);
            }
            let routed = gateway.route(target.host_str().unwrap_or_default(), &path);
            reqwest::Url::parse(&routed).map_err(|e| SendError::Other(format!("gateway:bad url: {e}")))?
        } else {
            target.clone()
        };
        let mut req = reqwest::Request::new(method.clone(), url);
        *req.headers_mut() = headers.clone();
        if supported {
            for (k, v) in gateway.headers() {
                let name = HeaderName::from_bytes(k.as_bytes()).map_err(|e| SendError::Other(e.to_string()))?;
                let value = HeaderValue::from_str(&v).map_err(|e| SendError::Other(e.to_string()))?;
                req.headers_mut().insert(name, value);
            }
        }
        *req.timeout_mut() = timeout;
        if let Some(ref b) = body {
            *req.body_mut() = Some(b.clone().into());
        }
        // 重定向到网关之外的主机（少见）按 Spotify 主机的代理直连，不带网关凭据
        let client = if supported {
            gateway_client.clone()
        } else {
            client_for(&crate::net_config::get().proxy).map_err(SendError::Other)?
        };
        let response = client.execute(req).await.map_err(SendError::Http)?;

        let status = response.status();
        let location = response.headers().get(LOCATION).and_then(|v| v.to_str().ok()).map(str::to_string);
        let next_method = match (method.as_str(), status.as_u16()) {
            ("GET" | "HEAD", _) => Some(method.clone()),
            ("POST", 303) => Some(reqwest::Method::GET),
            _ => None,
        };
        let (Some(location), Some(next_method)) = (location, next_method) else {
            return Ok(response);
        };
        if !status.is_redirection() {
            return Ok(response);
        }
        if hop == GATEWAY_MAX_REDIRECTS {
            return Err(SendError::Other("request:Redirect limit exceeded".into()));
        }
        let next = target
            .join(&location)
            .map_err(|e| SendError::Other(format!("request:bad redirect: {e}")))?;
        if target.scheme() == "https" && next.scheme() != "https" {
            return Err(SendError::Other("request:Insecure redirect".into()));
        }
        if next_method != method {
            body = None;
            headers.remove(CONTENT_TYPE);
            headers.remove(CONTENT_LENGTH);
        }
        method = next_method;
        target = next;
    }
    Err(SendError::Other("request:Redirect limit exceeded".into()))
}

/// 直连客户端（测试与不需要代理的调用）。
pub fn shared_client() -> reqwest::Client {
    client_for("").expect("direct client")
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
    proxy: String,
    method: String,
    url: String,
    headers: Vec<HttpHeader>,
    body: Vec<u8>,
    timeout_ms: u64,
) -> HttpResult {
    let method = reqwest::Method::from_bytes(method.as_bytes())
        .map_err(|e| format!("connect:bad method: {e}"))?;
    let mut request = client_for(&proxy)?
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
    proxy: String,
    method: String,
    url: String,
    headers: Vec<HttpHeader>,
    body: Vec<u8>,
    timeout_ms: u64,
) -> HttpResult {
    runtime()
        .spawn(execute(proxy, method, url, headers, body, timeout_ms))
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
        let result = block(send(String::new(), "GET".into(), "https://127.0.0.1:1/".into(), vec![], vec![], 3000));
        let error = result.err().expect("should fail");
        assert!(error.starts_with("connect:"), "{error}");
    }

    #[test]
    fn invalid_method_is_rejected_before_sending() {
        let result = block(send(String::new(), "BAD METHOD".into(), "https://example.com/".into(), vec![], vec![], 3000));
        assert!(result.err().unwrap().starts_with("connect:"));
    }

    /// 真实网络：确认能与 Spotify 协商出 HTTP/2。默认忽略（CI 无网络），本地 `cargo test -- --ignored` 跑。
    #[test]
    #[ignore]
    fn negotiates_http2_with_spotify() {
        let response = block(send(
            String::new(),
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

#[cfg(test)]
mod gateway_tests {
    use super::*;
    use crate::net_config::GatewayConfig;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// 本地「网关」：按顺序给每个连接回一条预设响应，记下请求行与请求头。
    async fn fake_gateway(responses: Vec<&'static str>) -> (String, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/gw", listener.local_addr().unwrap());
        let handle = tokio::spawn(async move {
            let mut seen = Vec::new();
            for resp in responses {
                let (mut sock, _) = listener.accept().await.unwrap();
                let mut buf = Vec::new();
                let mut chunk = [0u8; 1024];
                while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = sock.read(&mut chunk).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
                seen.push(String::from_utf8_lossy(&buf).to_lowercase());
                sock.write_all(resp.as_bytes()).await.unwrap();
                sock.shutdown().await.ok();
            }
            seen
        });
        (base, handle)
    }

    #[test]
    fn gateway_rewrites_url_adds_credentials_and_follows_redirects() {
        runtime().block_on(async {
            let (base, server) = fake_gateway(vec![
                "HTTP/1.1 302 Found\r\nLocation: https://api.spotify.com/v1/next?x=1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
            ])
            .await;
            let gateway = GatewayConfig {
                base,
                username: "u1".into(),
                password: "p1".into(),
                proxy: String::new(),
            };
            let request = shared_client()
                .get("https://api.spotify.com/v1/me?market=from_token")
                .header("Authorization", "Bearer t")
                .build()
                .unwrap();
            let response = send_via_gateway(request, &gateway).await.unwrap();
            assert_eq!(response.status().as_u16(), 200);
            assert_eq!(response.text().await.unwrap(), "ok");
            let seen = server.await.unwrap();
            assert!(seen[0].starts_with("get /gw/api.spotify.com/v1/me?market=from_token http/1.1"), "{}", seen[0]);
            assert!(seen[0].contains("x-proxy-user: u1") && seen[0].contains("x-proxy-pass: p1"));
            assert!(seen[0].contains("authorization: bearer t"));
            assert!(seen[1].starts_with("get /gw/api.spotify.com/v1/next?x=1 http/1.1"), "{}", seen[1]);
            assert!(seen[1].contains("x-proxy-user: u1"));
        });
    }

    #[test]
    fn gateway_refuses_https_downgrade_and_keeps_post_redirects() {
        runtime().block_on(async {
            let (base, server) = fake_gateway(vec![
                "HTTP/1.1 302 Found\r\nLocation: http://api.spotify.com/v1/x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                "HTTP/1.1 307 Temporary Redirect\r\nLocation: /v1/y\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            ])
            .await;
            let gateway = GatewayConfig { base, username: "u".into(), password: "p".into(), proxy: String::new() };
            let get = shared_client().get("https://api.spotify.com/v1/me").build().unwrap();
            let err = send_via_gateway(get, &gateway).await.unwrap_err();
            assert!(err.to_string().contains("Insecure redirect"));
            // POST + 307：不跟随，原样交回调用方
            let post = shared_client().post("https://api.spotify.com/v1/me").body("b").build().unwrap();
            let response = send_via_gateway(post, &gateway).await.unwrap();
            assert_eq!(response.status().as_u16(), 307);
            server.await.unwrap();
        });
    }
}
