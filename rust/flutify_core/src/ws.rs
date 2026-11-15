//! WebSocket 客户端（tokio-tungstenite + rustls），Connect 的 dealer 长连接用。
//!
//! 连接由 Dart 侧分配的 id 标识：[connect] 建立并开始上报事件，[send] / [close] 按 id 操作。
//! 代理（HTTP CONNECT / SOCKS5）由 Dart 侧算出地址后传入，这里自建隧道；网关仍走 dart:io WebSocket。
//! 证书：系统证书库 + Mozilla 根证书（与 HTTP 客户端一致）。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::Connector;

/// WebSocket 事件。`kind`：0 = 已连接，1 = 文本帧（text），2 = 已关闭（code / text 为原因），
/// 3 = 出错（text；以 `connect:` 开头表示握手没成功，可安全改用其他通道）。
#[derive(Debug, Clone, Default)]
pub struct WsEvent {
    pub kind: u8,
    pub text: String,
    pub code: u16,
}

pub const WS_OPEN: u8 = 0;
pub const WS_TEXT: u8 = 1;
pub const WS_CLOSED: u8 = 2;
pub const WS_ERROR: u8 = 3;

pub type WsEmit = Arc<dyn Fn(WsEvent) -> bool + Send + Sync>;

enum Command {
    Text(String),
    Close,
}

fn connections() -> &'static Mutex<HashMap<u64, mpsc::UnboundedSender<Command>>> {
    static MAP: OnceLock<Mutex<HashMap<u64, mpsc::UnboundedSender<Command>>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

/// rustls 配置：显式用 ring（不依赖全局默认 provider），信任 Mozilla 根证书 + 系统证书库。
pub fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            for cert in rustls_native_certs::load_native_certs().certs {
                let _ = roots.add(cert);
            }
            let provider = Arc::new(rustls::crypto::ring::default_provider());
            Arc::new(
                rustls::ClientConfig::builder_with_provider(provider)
                    .with_safe_default_protocol_versions()
                    .expect("tls versions")
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            )
        })
        .clone()
}

/// 到 [host]:[port] 的 TCP 连接：直连，或经 [proxy]（`http://[user:pass@]h:p` 发 CONNECT 建隧道；
/// `socks5://` / `socks5h://` 走 SOCKS5，可带用户名密码）。失败以 `connect:` 开头。
pub(crate) async fn open_tcp(proxy: &str, host: &str, port: u16) -> Result<TcpStream, String> {
    if proxy.is_empty() {
        return TcpStream::connect((host, port)).await.map_err(|e| format!("connect:{e}"));
    }
    let proxy_url = reqwest::Url::parse(proxy).map_err(|e| format!("connect:bad proxy: {e}"))?;
    let proxy_host = proxy_url.host_str().ok_or("connect:bad proxy host")?.trim_matches(['[', ']']).to_string();
    let proxy_port = proxy_url.port_or_known_default().ok_or("connect:bad proxy port")?;
    let user = urlencoding_decode(proxy_url.username());
    let pass = urlencoding_decode(proxy_url.password().unwrap_or(""));
    match proxy_url.scheme() {
        "socks5" | "socks5h" => {
            let stream = if user.is_empty() {
                tokio_socks::tcp::Socks5Stream::connect((proxy_host.as_str(), proxy_port), (host, port)).await
            } else {
                tokio_socks::tcp::Socks5Stream::connect_with_password(
                    (proxy_host.as_str(), proxy_port),
                    (host, port),
                    &user,
                    &pass,
                )
                .await
            };
            stream.map(|s| s.into_inner()).map_err(|e| format!("connect:socks5: {e}"))
        }
        _ => {
            let mut stream = TcpStream::connect((proxy_host.as_str(), proxy_port))
                .await
                .map_err(|e| format!("connect:proxy: {e}"))?;
            let authority = if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") };
            let mut request = format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n");
            if !user.is_empty() || !pass.is_empty() {
                let token = base64::engine::general_purpose::STANDARD.encode(format!("{user}:{pass}"));
                request.push_str(&format!("Proxy-Authorization: Basic {token}\r\n"));
            }
            request.push_str("\r\n");
            stream.write_all(request.as_bytes()).await.map_err(|e| format!("connect:proxy: {e}"))?;
            // 读到响应头结束（\r\n\r\n）；隧道建立前代理不会发送多余数据
            let mut head = Vec::with_capacity(256);
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                if head.len() > 16 * 1024 {
                    return Err("connect:proxy: response too large".into());
                }
                let n = stream.read(&mut byte).await.map_err(|e| format!("connect:proxy: {e}"))?;
                if n == 0 {
                    return Err("connect:proxy closed during CONNECT".into());
                }
                head.push(byte[0]);
            }
            let status_line = String::from_utf8_lossy(&head);
            let status_line = status_line.lines().next().unwrap_or("");
            if status_line.split_whitespace().nth(1) != Some("200") {
                return Err(format!("connect:proxy CONNECT failed: {status_line}"));
            }
            Ok(stream)
        }
    }
}

/// 代理地址里的用户名 / 密码是百分号编码的。
fn urlencoding_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(v) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 建立连接并持续上报事件，直到连接关闭（本函数在连接结束后才返回）。
pub async fn connect(id: u64, proxy: String, url: String, headers: Vec<(String, String)>, emit: WsEmit) {
    let mut request = match url.as_str().into_client_request() {
        Ok(r) => r,
        Err(e) => {
            emit(WsEvent { kind: WS_ERROR, text: format!("connect:{e}"), code: 0 });
            return;
        }
    };
    for (name, value) in &headers {
        if let (Ok(name), Ok(value)) = (
            tokio_tungstenite::tungstenite::http::HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            request.headers_mut().insert(name, value);
        }
    }
    let uri = request.uri().clone();
    let host = uri.host().unwrap_or("").trim_matches(['[', ']']).to_string();
    let port = uri.port_u16().unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
    let tcp = match open_tcp(&proxy, &host, port).await {
        Ok(tcp) => tcp,
        Err(text) => {
            emit(WsEvent { kind: WS_ERROR, text, code: 0 });
            return;
        }
    };
    let connected = tokio_tungstenite::client_async_tls_with_config(
        request,
        tcp,
        None,
        Some(Connector::Rustls(tls_config())),
    )
    .await;
    let (stream, _) = match connected {
        Ok(s) => s,
        Err(e) => {
            // 服务端回了 HTTP 错误（如令牌过期 401）：已连上服务器，换通道重试也是同样结果
            let text = match &e {
                tokio_tungstenite::tungstenite::Error::Http(response) => {
                    format!("request:HTTP {}", response.status())
                }
                _ => format!("connect:{e}"),
            };
            emit(WsEvent { kind: WS_ERROR, text, code: 0 });
            return;
        }
    };
    let (mut writer, mut reader) = stream.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Command>();
    connections().lock().unwrap().insert(id, tx);
    if !emit(WsEvent { kind: WS_OPEN, ..Default::default() }) {
        connections().lock().unwrap().remove(&id);
        let _ = writer.close().await;
        return;
    }

    let writer_task = tokio::spawn(async move {
        while let Some(command) = rx.recv().await {
            let result = match command {
                Command::Text(text) => writer.send(Message::Text(text)).await,
                Command::Close => {
                    let _ = writer.close().await;
                    break;
                }
            };
            if result.is_err() {
                break;
            }
        }
    });

    let mut closed = WsEvent { kind: WS_CLOSED, ..Default::default() };
    while let Some(message) = reader.next().await {
        match message {
            Ok(Message::Text(text)) => {
                if !emit(WsEvent { kind: WS_TEXT, text, code: 0 }) {
                    break; // 调用方已不再接收
                }
            }
            // dealer 只发文本帧；万一收到二进制帧按 UTF-8 解成文本，交给上层 JSON 解析判断
            Ok(Message::Binary(data)) => {
                let text = String::from_utf8_lossy(&data).into_owned();
                if !emit(WsEvent { kind: WS_TEXT, text, code: 0 }) {
                    break;
                }
            }
            Ok(Message::Close(frame)) => {
                if let Some(frame) = frame {
                    closed.code = frame.code.into();
                    closed.text = frame.reason.into_owned();
                }
                break;
            }
            Ok(_) => {} // ping / pong 由 tungstenite 处理
            Err(e) => {
                closed = WsEvent { kind: WS_ERROR, text: format!("request:{e}"), code: 0 };
                break;
            }
        }
    }
    if let Some(tx) = connections().lock().unwrap().remove(&id) {
        let _ = tx.send(Command::Close);
    }
    let _ = writer_task.await;
    emit(closed);
}

/// 发送文本帧；连接不存在（已关闭）时返回错误。
pub fn send(id: u64, text: String) -> Result<(), String> {
    let map = connections().lock().unwrap();
    let tx = map.get(&id).ok_or_else(|| "WebSocket 已关闭".to_string())?;
    tx.send(Command::Text(text)).map_err(|_| "WebSocket 已关闭".to_string())
}

/// 主动关闭（发送 Close 帧）；连接不存在时忽略。
pub fn close(id: u64) {
    if let Some(tx) = connections().lock().unwrap().get(&id) {
        let _ = tx.send(Command::Close);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::net::TcpListener;

    /// 本地明文 WebSocket 回显服务：把收到的文本加前缀 `echo:` 发回，收到 `bye` 时主动关闭。
    async fn echo_server() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut ws = tokio_tungstenite::accept_async(socket).await.unwrap();
                    while let Some(Ok(message)) = ws.next().await {
                        if let Message::Text(text) = message {
                            if text == "bye" {
                                let _ = ws.close(None).await;
                                break;
                            }
                            ws.send(Message::Text(format!("echo:{text}"))).await.unwrap();
                        }
                    }
                });
            }
        });
        format!("ws://{addr}/")
    }

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap()
    }

    #[test]
    fn open_send_receive_and_server_close() {
        runtime().block_on(async {
            let url = echo_server().await;
            let events = Arc::new(Mutex::new(Vec::<WsEvent>::new()));
            let sink = events.clone();
            let emit: WsEmit = Arc::new(move |e| {
                sink.lock().unwrap().push(e);
                true
            });
            let task = tokio::spawn(connect(42, String::new(), url, vec![("User-Agent".into(), "test".into())], emit));
            // 等连接建立
            for _ in 0..100 {
                if events.lock().unwrap().iter().any(|e| e.kind == WS_OPEN) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            send(42, "hello".into()).unwrap();
            send(42, "bye".into()).unwrap();
            tokio::time::timeout(Duration::from_secs(5), task).await.unwrap().unwrap();
            let kinds: Vec<(u8, String)> = events.lock().unwrap().iter().map(|e| (e.kind, e.text.clone())).collect();
            assert_eq!(kinds[0].0, WS_OPEN);
            assert_eq!(kinds[1], (WS_TEXT, "echo:hello".to_string()));
            assert_eq!(kinds.last().unwrap().0, WS_CLOSED);
            assert!(send(42, "late".into()).is_err(), "关闭后 send 应报错");
        });
    }

    #[test]
    fn client_close_ends_the_connection() {
        runtime().block_on(async {
            let url = echo_server().await;
            let events = Arc::new(Mutex::new(Vec::<WsEvent>::new()));
            let sink = events.clone();
            let emit: WsEmit = Arc::new(move |e| {
                sink.lock().unwrap().push(e);
                true
            });
            let task = tokio::spawn(connect(7, String::new(), url, vec![], emit));
            for _ in 0..100 {
                if events.lock().unwrap().iter().any(|e| e.kind == WS_OPEN) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            close(7);
            tokio::time::timeout(Duration::from_secs(5), task).await.unwrap().unwrap();
            assert_eq!(events.lock().unwrap().last().unwrap().kind, WS_CLOSED);
        });
    }

    /// 本地 HTTP CONNECT 代理（测试用）：记录 CONNECT 目标与认证头，建隧道后双向转发。
    async fn connect_proxy(seen: Arc<Mutex<Vec<String>>>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut client, _)) = listener.accept().await {
                let seen = seen.clone();
                tokio::spawn(async move {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        if client.read(&mut byte).await.unwrap() == 0 {
                            return;
                        }
                        head.push(byte[0]);
                    }
                    let text = String::from_utf8_lossy(&head).to_string();
                    seen.lock().unwrap().push(text.clone());
                    let target = text.split_whitespace().nth(1).unwrap().to_string();
                    let mut upstream = TcpStream::connect(target).await.unwrap();
                    client.write_all(b"HTTP/1.1 200 Connection established\r\n\r\n").await.unwrap();
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
                });
            }
        });
        format!("http://user%40x:p%3Ass@{addr}")
    }

    #[test]
    fn connects_through_http_connect_proxy_with_credentials() {
        runtime().block_on(async {
            let url = echo_server().await;
            let seen = Arc::new(Mutex::new(Vec::new()));
            let proxy = connect_proxy(seen.clone()).await;
            let events = Arc::new(Mutex::new(Vec::<WsEvent>::new()));
            let sink = events.clone();
            let emit: WsEmit = Arc::new(move |e| {
                sink.lock().unwrap().push(e);
                true
            });
            let task = tokio::spawn(connect(77, proxy, url.clone(), vec![], emit));
            for _ in 0..200 {
                if events.lock().unwrap().iter().any(|e| e.kind == WS_OPEN || e.kind == WS_ERROR) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            send(77, "via proxy".into()).unwrap();
            send(77, "bye".into()).unwrap();
            tokio::time::timeout(Duration::from_secs(5), task).await.unwrap().unwrap();
            let texts: Vec<String> = events.lock().unwrap().iter().filter(|e| e.kind == WS_TEXT).map(|e| e.text.clone()).collect();
            assert_eq!(texts, vec!["echo:via proxy".to_string()]);
            let request = seen.lock().unwrap()[0].clone();
            let target = url.trim_start_matches("ws://").trim_end_matches('/');
            assert!(request.starts_with(&format!("CONNECT {target} HTTP/1.1")), "{request}");
            // user@x : p:ss 的 Basic 认证
            let token = base64::engine::general_purpose::STANDARD.encode("user@x:p:ss");
            assert!(request.contains(&format!("Proxy-Authorization: Basic {token}")), "{request}");
        });
    }

    #[test]
    fn proxy_refusing_connect_is_a_connect_error() {
        runtime().block_on(async {
            let events = Arc::new(Mutex::new(Vec::<WsEvent>::new()));
            let sink = events.clone();
            let emit: WsEmit = Arc::new(move |e| {
                sink.lock().unwrap().push(e);
                true
            });
            connect(2, "http://127.0.0.1:1".into(), "wss://dealer.spotify.com/".into(), vec![], emit).await;
            let events = events.lock().unwrap();
            assert!(events[0].text.starts_with("connect:"), "{:?}", events[0]);
        });
    }

    #[test]
    fn handshake_failure_is_a_connect_error() {
        runtime().block_on(async {
            let events = Arc::new(Mutex::new(Vec::<WsEvent>::new()));
            let sink = events.clone();
            let emit: WsEmit = Arc::new(move |e| {
                sink.lock().unwrap().push(e);
                true
            });
            connect(1, String::new(), "ws://127.0.0.1:1/".into(), vec![], emit).await;
            let events = events.lock().unwrap();
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].kind, WS_ERROR);
            assert!(events[0].text.starts_with("connect:"));
        });
    }

    #[test]
    fn tls_config_builds_with_roots() {
        assert!(!tls_config().alpn_protocols.iter().any(|p| p == b"h2"));
    }
}
