//! 音频下载（边下边播）：
//! - [download_to_file]：EME 主链路。多连接分段 Range 下载直接写文件，按「从 0 起连续可用字节」汇报进度，
//!   语义与 `lib/services/eme/segmented_download.dart` 一致；CDN 支持 HTTP/2 时多段共用一条连接。
//! - [download_progressive]：AP 链路。下载同时 AES-128-CTR 解密，断线续传 / CDN 轮换 / 重试也在这里，
//!   明文块按文件偏移逐个交给调用方（Dart 只负责放进播放缓冲区）。
//!
//! 结果通过回调逐个上报（api 层把它接到 frb 的 StreamSink）；回调返回 false 表示调用方已取消，立即停止下载。
//! 代理 / 网关路线由 Dart 侧按网络设置选好后传入。

use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;

use crate::aes::AesCtr;
use crate::http_client;

/// 下载事件。`kind`：0 = 元信息（status / total），1 = 数据块（data），2 = 进度（bytes / total），
/// 3 = 完成（total），4 = 失败（message；以 `connect:` 开头表示一个字节都还没收到）。
#[derive(Debug, Clone, Default)]
pub struct DownloadEvent {
    pub kind: u8,
    pub status: u16,
    pub total: u64,
    pub bytes: u64,
    pub data: Vec<u8>,
    pub message: String,
}

pub const EVENT_META: u8 = 0;
pub const EVENT_DATA: u8 = 1;
pub const EVENT_PROGRESS: u8 = 2;
pub const EVENT_DONE: u8 = 3;
pub const EVENT_ERROR: u8 = 4;

/// 事件回调：返回 false 表示调用方已不再接收（取消）。
pub type Emit = Arc<dyn Fn(DownloadEvent) -> bool + Send + Sync>;

fn request(
    proxy: &str,
    url: &str,
    headers: &[(String, String)],
    range: Option<(u64, Option<u64>)>,
) -> Result<reqwest::RequestBuilder, String> {
    let mut builder = http_client::client_for(proxy)?
        .get(url)
        .timeout(Duration::from_secs(120));
    for (name, value) in headers {
        builder = builder.header(name.as_str(), value.as_str());
    }
    if let Some((start, end)) = range {
        let value = match end {
            Some(end) => format!("bytes={start}-{end}"),
            None => format!("bytes={start}-"),
        };
        builder = builder.header("Range", value);
    }
    Ok(builder)
}

fn error_text(e: &reqwest::Error) -> String {
    if e.is_connect() {
        format!("connect:{e}")
    } else {
        format!("request:{e}")
    }
}

/// `Content-Range: bytes a-b/total` 的 total。
fn total_from_content_range(response: &reqwest::Response) -> Option<u64> {
    let value = response.headers().get("content-range")?.to_str().ok()?;
    value.rsplit('/').next()?.trim().parse().ok()
}

// ---------------------------------------------------------------------------
// 边下边播 + 解密（AP 链路）
// ---------------------------------------------------------------------------

/// 一个 CDN 地址及其路线（代理 / 额外请求头由 Dart 侧按网络设置选好）。
#[derive(Debug, Clone, Default)]
pub struct DownloadTarget {
    pub proxy: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
}

/// 单个音频文件的长度上限：Dart 侧按声明长度预分配播放缓冲区，不接受离谱的声明。
const MAX_PROGRESSIVE_BYTES: u64 = 1024 * 1024 * 1024;

/// 跨重试保留的下载状态（文件坐标）。
#[derive(Debug, Default)]
struct Progressive {
    /// 文件总长（第一次拿到有效声明后固定）；未知时无法续传，每次都从头下载。
    total: Option<u64>,
    /// 从 0 起已连续收到的字节数。
    received: u64,
}

enum Attempt {
    Done,
    Cancelled,
}

/// 去掉 `connect:` / `request:` 前缀，得到给用户看的原因。
fn detail(message: &str) -> &str {
    message
        .strip_prefix("connect:")
        .or_else(|| message.strip_prefix("request:"))
        .unwrap_or(message)
}

/// 下载 + AES-128-CTR 解密（[key] 为空时不解密）整个文件，供边下边播：
/// - 每次请求先报元信息（`status`、`total` = 文件总长或 0 = 未知、`bytes` = 本次数据的起始偏移），
///   随后逐块报数据（`bytes` = 该块在文件中的偏移，`data` = 明文），最后报完成（`total`）或失败；
/// - 中途断线时用 HTTP Range 从已收到的位置续传，依次轮换 [targets]，累计失败 [max_attempts] 次才放弃；
///   服务器忽略 Range（回 200）时从头重新下载（内容相同，调用方按偏移覆盖写即可）；
/// - 总长未知（无 Content-Length）时无法续传，重试从头开始（元信息的 `bytes` 为 0，调用方丢弃已收数据）。
///
/// 回调返回 false（Dart 取消订阅）时立即停止并关闭连接，不再上报任何事件。
pub async fn download_progressive(
    targets: Vec<DownloadTarget>,
    key: Vec<u8>,
    iv: Vec<u8>,
    max_attempts: u32,
    emit: Emit,
) {
    if targets.is_empty() {
        emit(DownloadEvent {
            kind: EVENT_ERROR,
            message: "request:没有可用的 CDN 地址".into(),
            ..Default::default()
        });
        return;
    }
    let mut state = Progressive::default();
    let mut last = String::from("request:下载失败");
    for attempt in 0..max_attempts.max(1) as usize {
        let target = &targets[attempt % targets.len()];
        match progressive_attempt(target, &key, &iv, &mut state, &emit).await {
            Ok(Attempt::Done) => {
                let total = state.total.unwrap_or(state.received);
                emit(DownloadEvent { kind: EVENT_DONE, total, ..Default::default() });
                return;
            }
            Ok(Attempt::Cancelled) => return,
            Err(e) => last = e,
        }
    }
    emit(DownloadEvent {
        kind: EVENT_ERROR,
        message: format!("request:所有 CDN 地址下载失败：{}", detail(&last)),
        ..Default::default()
    });
}

/// 一次请求：从 `state.received` 处（总长已知时）续传到结尾。
async fn progressive_attempt(
    target: &DownloadTarget,
    key: &[u8],
    iv: &[u8],
    state: &mut Progressive,
    emit: &Emit,
) -> Result<Attempt, String> {
    let offset = if state.total.is_some() { state.received } else { 0 };
    let range = (offset > 0).then_some((offset, None));
    let response = request(&target.proxy, &target.url, &target.headers, range)?
        .send()
        .await
        .map_err(|e| error_text(&e))?;
    let status = response.status().as_u16();
    if status != 200 && status != 206 {
        return Err(format!("request:CDN 返回 HTTP {status}"));
    }
    let declared = if status == 206 {
        total_from_content_range(&response)
    } else {
        response.content_length()
    };
    if let Some(t) = declared.filter(|t| *t > 0) {
        if t > MAX_PROGRESSIVE_BYTES {
            return Err("request:CDN 声明的文件长度超出上限".into());
        }
        state.total.get_or_insert(t);
    }
    // 206 才从续传位置开始；200（含忽略 Range）从头写
    let mut pos = if status == 206 { offset } else { 0 };
    if state.total.is_none() {
        state.received = 0;
    }
    if !emit(DownloadEvent {
        kind: EVENT_META,
        status,
        total: state.total.unwrap_or(0),
        bytes: pos,
        ..Default::default()
    }) {
        return Ok(Attempt::Cancelled);
    }
    let mut ctr = if key.is_empty() {
        None
    } else {
        Some(AesCtr::at_offset(key, iv, pos as usize).map_err(|e| format!("request:{e}"))?)
    };
    let limit = state.total.unwrap_or(MAX_PROGRESSIVE_BYTES);
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let mut data = chunk.map_err(|e| format!("request:{e}"))?.to_vec();
        if data.is_empty() {
            continue;
        }
        let end = pos + data.len() as u64;
        if end > limit {
            return Err("request:CDN 返回的数据超出声明长度".into());
        }
        if let Some(ctr) = ctr.as_mut() {
            ctr.process(&mut data);
        }
        if !emit(DownloadEvent { kind: EVENT_DATA, bytes: pos, data, ..Default::default() }) {
            return Ok(Attempt::Cancelled); // 丢弃响应即关闭连接
        }
        pos = end;
        state.received = state.received.max(pos);
    }
    match state.total {
        Some(total) if state.received < total => {
            Err(format!("request:下载中断（{}/{total}）", state.received))
        }
        None if pos == 0 => Err("request:CDN 返回空文件".into()),
        _ => Ok(Attempt::Done),
    }
}

// ---------------------------------------------------------------------------
// 分段下载写文件（EME 链路）
// ---------------------------------------------------------------------------

pub struct FileDownloadOptions {
    /// 代理地址（空 = 直连），见 [http_client::client_for]。
    pub proxy: String,
    pub urls: Vec<String>,
    pub headers: Vec<(String, String)>,
    pub path: String,
    pub segment_bytes: u64,
    pub connections: u32,
    pub max_attempts_per_segment: u32,
}

struct Segments {
    /// 各段已顺序写入的字节数 / 各段长度。
    got: Vec<u64>,
    len: Vec<u64>,
    total: u64,
}

impl Segments {
    /// 从 0 开始连续写完的字节数：前面完整的段 + 第一个未完成段已写入的部分。
    fn contiguous(&self) -> u64 {
        let mut sum = 0;
        for (got, len) in self.got.iter().zip(&self.len) {
            sum += got;
            if got < len {
                break;
            }
        }
        sum
    }
}

struct Shared {
    options: FileDownloadOptions,
    file: Mutex<File>,
    segments: Mutex<Segments>,
    cursor: Mutex<usize>,
    cancelled: AtomicBool,
    emit: Emit,
}

impl Shared {
    fn next_url(&self) -> String {
        let mut cursor = self.cursor.lock().unwrap();
        let url = self.options.urls[*cursor % self.options.urls.len()].clone();
        *cursor += 1;
        url
    }

    fn report(&self) {
        let (bytes, total) = {
            let segments = self.segments.lock().unwrap();
            (segments.contiguous(), segments.total)
        };
        if !(self.emit)(DownloadEvent { kind: EVENT_PROGRESS, bytes, total, ..Default::default() }) {
            self.cancelled.store(true, Ordering::SeqCst);
        }
    }

    fn write(&self, index: usize, data: &[u8]) -> Result<(), String> {
        let offset = index as u64 * self.options.segment_bytes;
        {
            let mut segments = self.segments.lock().unwrap();
            let position = offset + segments.got[index];
            let mut file = self.file.lock().unwrap();
            file.seek(SeekFrom::Start(position)).map_err(|e| format!("request:写文件失败：{e}"))?;
            file.write_all(data).map_err(|e| format!("request:写文件失败：{e}"))?;
            segments.got[index] += data.len() as u64;
        }
        self.report();
        Ok(())
    }

    /// 把响应体顺序写到第 [index] 段的当前位置。
    async fn consume(&self, response: reqwest::Response, index: usize) -> Result<(), String> {
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            if self.cancelled.load(Ordering::SeqCst) {
                return Err("request:下载已取消".into());
            }
            let chunk = chunk.map_err(|e| format!("request:{e}"))?;
            self.write(index, &chunk)?;
        }
        Ok(())
    }

    /// 拉取第 [index] 段；失败时从已收到的位置续传并轮换 CDN。
    async fn fetch_segment(&self, index: usize) -> Result<(), String> {
        let mut last = String::from("request:分段下载失败");
        for _ in 0..self.options.max_attempts_per_segment.max(1) {
            if self.cancelled.load(Ordering::SeqCst) {
                return Err("request:下载已取消".into());
            }
            let (start, end) = {
                let segments = self.segments.lock().unwrap();
                let base = index as u64 * self.options.segment_bytes;
                (base + segments.got[index], base + segments.len[index] - 1)
            };
            if start > end {
                return Ok(());
            }
            let url = self.next_url();
            let builder = match request(&self.options.proxy, &url, &self.options.headers, Some((start, Some(end)))) {
                Ok(b) => b,
                Err(e) => return Err(e),
            };
            match builder.send().await {
                Ok(response) if response.status().as_u16() == 206 => {
                    match self.consume(response, index).await {
                        Ok(()) => {
                            let segments = self.segments.lock().unwrap();
                            if segments.got[index] >= segments.len[index] {
                                return Ok(());
                            }
                            last = "request:分段响应提前结束".into();
                        }
                        Err(e) => last = e,
                    }
                }
                Ok(response) => last = format!("request:分段请求 HTTP {}", response.status().as_u16()),
                Err(e) => last = error_text(&e),
            }
        }
        Err(last)
    }
}

/// 下载整个文件到 [FileDownloadOptions::path]；完成时上报总字节数。
pub async fn download_to_file(options: FileDownloadOptions, emit: Emit) {
    if let Err(message) = run_file(options, emit.clone()).await {
        emit(DownloadEvent { kind: EVENT_ERROR, message, ..Default::default() });
    }
}

async fn run_file(options: FileDownloadOptions, emit: Emit) -> Result<(), String> {
    if options.urls.is_empty() {
        return Err("request:没有可用的 CDN 地址".into());
    }
    if let Some(parent) = std::path::Path::new(&options.path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("request:创建目录失败：{e}"))?;
    }
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&options.path)
        .map_err(|e| format!("request:打开文件失败：{e}"))?;
    let segment_bytes = options.segment_bytes.max(1);
    let shared = Arc::new(Shared {
        file: Mutex::new(file),
        segments: Mutex::new(Segments { got: vec![0], len: vec![u64::MAX], total: 0 }),
        cursor: Mutex::new(0),
        cancelled: AtomicBool::new(false),
        emit,
        options: FileDownloadOptions { segment_bytes, ..options },
    });

    let url = shared.next_url();
    let first = request(&shared.options.proxy, &url, &shared.options.headers, Some((0, Some(segment_bytes - 1))))?
        .send()
        .await
        .map_err(|e| error_text(&e))?;
    let status = first.status().as_u16();
    if status == 200 {
        // 不支持 Range：整份在这一个响应里顺序写完
        let total = first.content_length().unwrap_or(0);
        *shared.segments.lock().unwrap() = Segments { got: vec![0], len: vec![u64::MAX], total };
        shared.consume(first, 0).await?;
        let written = shared.segments.lock().unwrap().got[0];
        (shared.emit)(DownloadEvent { kind: EVENT_DONE, total: written, ..Default::default() });
        return Ok(());
    }
    if status != 206 {
        return Err(format!("request:CDN 返回 HTTP {status}"));
    }
    const MAX_DOWNLOAD_BYTES: u64 = 4 * 1024 * 1024 * 1024;
    const MAX_SEGMENTS: u64 = 65_536;
    let total = total_from_content_range(&first)
        .filter(|t| *t > 0 && *t <= MAX_DOWNLOAD_BYTES)
        .ok_or_else(|| "request:CDN 返回无效的 Content-Range 总长".to_string())?;
    let raw_count = total.div_ceil(segment_bytes);
    if raw_count == 0 || raw_count > MAX_SEGMENTS {
        return Err("request:CDN 分片数量超出上限".to_string());
    }
    let count = raw_count as usize;
    *shared.segments.lock().unwrap() = Segments {
        got: vec![0; count],
        len: (0..count)
            .map(|i| segment_bytes.min(total - i as u64 * segment_bytes))
            .collect(),
        total,
    };
    (shared.emit)(DownloadEvent { kind: EVENT_META, status, total, ..Default::default() });

    let next = Arc::new(Mutex::new(1usize));
    let mut tasks = Vec::new();
    // 首段与其余连接同时进行
    {
        let shared = shared.clone();
        tasks.push(tokio::spawn(async move {
            if shared.consume(first, 0).await.is_err() {
                return shared.fetch_segment(0).await;
            }
            let incomplete = {
                let s = shared.segments.lock().unwrap();
                s.got[0] < s.len[0]
            };
            if incomplete { shared.fetch_segment(0).await } else { Ok(()) }
        }));
    }
    for _ in 0..shared.options.connections.saturating_sub(1).max(1) {
        let shared = shared.clone();
        let next = next.clone();
        tasks.push(tokio::spawn(async move {
            loop {
                let index = {
                    let mut n = next.lock().unwrap();
                    if *n >= count {
                        return Ok(());
                    }
                    let i = *n;
                    *n += 1;
                    i
                };
                shared.fetch_segment(index).await?;
            }
        }));
    }
    let mut first_error = None;
    for task in tasks {
        let result = task.await.map_err(|e| format!("request:task failed: {e}")).and_then(|r| r);
        if let Err(e) = result {
            shared.cancelled.store(true, Ordering::SeqCst);
            first_error.get_or_insert(e);
        }
    }
    if let Some(e) = first_error {
        return Err(e);
    }
    shared.file.lock().unwrap().flush().map_err(|e| format!("request:{e}"))?;
    (shared.emit)(DownloadEvent { kind: EVENT_DONE, total, ..Default::default() });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::net::TcpListener;
    use std::sync::atomic::AtomicUsize;

    /// 极简 HTTP/1.1 Range 服务器（测试用），返回 [body] 的对应区间；`support_range=false` 时总回 200 全量。
    fn serve(body: Vec<u8>, support_range: bool, requests: Arc<AtomicUsize>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = match stream { Ok(s) => s, Err(_) => break };
                let body = body.clone();
                let requests = requests.clone();
                std::thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = stream.read(&mut buf).unwrap_or(0);
                    requests.fetch_add(1, Ordering::SeqCst);
                    let text = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                    let range = text.lines().find_map(|l| l.strip_prefix("range: bytes=")).map(|r| {
                        let (a, b) = r.trim().split_once('-').unwrap();
                        let a: usize = a.parse().unwrap();
                        let b = if b.is_empty() { body.len() - 1 } else { b.parse::<usize>().unwrap().min(body.len() - 1) };
                        (a, b)
                    });
                    let response = match (support_range, range) {
                        (true, Some((a, b))) => {
                            let mut r = format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {a}-{b}/{}\r\nConnection: close\r\n\r\n",
                                b - a + 1,
                                body.len()
                            )
                            .into_bytes();
                            r.extend_from_slice(&body[a..=b]);
                            r
                        }
                        _ => {
                            let mut r = format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                body.len()
                            )
                            .into_bytes();
                            r.extend_from_slice(&body);
                            r
                        }
                    };
                    let _ = stream.write_all(&response);
                });
            }
        });
        format!("http://{addr}/audio")
    }

    fn block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap().block_on(f)
    }

    fn collect() -> (Emit, Arc<Mutex<Vec<DownloadEvent>>>) {
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        (Arc::new(move |e| { sink.lock().unwrap().push(e); true }), events)
    }

    fn body(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 31 % 251) as u8).collect()
    }

    #[test]
    fn segmented_file_download_matches_and_reports_contiguous_progress() {
        let data = body(10_000);
        let url = serve(data.clone(), true, Arc::new(AtomicUsize::new(0)));
        let path = std::env::temp_dir().join(format!("flutify_seg_{}.bin", std::process::id()));
        let (emit, events) = collect();
        block(download_to_file(
            FileDownloadOptions {
                proxy: String::new(),
                urls: vec![url],
                headers: vec![],
                path: path.to_string_lossy().into(),
                segment_bytes: 1024,
                connections: 3,
                max_attempts_per_segment: 2,
            },
            emit,
        ));
        let written = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(written, data);
        let events = events.lock().unwrap();
        assert_eq!(events.last().unwrap().kind, EVENT_DONE, "{:?}", events.last());
        // 连续可用字节单调不减，最终等于总长
        let progress: Vec<u64> = events.iter().filter(|e| e.kind == EVENT_PROGRESS).map(|e| e.bytes).collect();
        assert!(progress.windows(2).all(|w| w[0] <= w[1]));
        assert_eq!(*progress.last().unwrap(), 10_000);
    }

    #[test]
    fn file_download_without_range_support_falls_back_to_single_stream() {
        let data = body(5000);
        let url = serve(data.clone(), false, Arc::new(AtomicUsize::new(0)));
        let path = std::env::temp_dir().join(format!("flutify_full_{}.bin", std::process::id()));
        let (emit, events) = collect();
        block(download_to_file(
            FileDownloadOptions {
                proxy: String::new(),
                urls: vec![url],
                headers: vec![],
                path: path.to_string_lossy().into(),
                segment_bytes: 1024,
                connections: 3,
                max_attempts_per_segment: 2,
            },
            emit,
        ));
        assert_eq!(std::fs::read(&path).unwrap(), data);
        std::fs::remove_file(&path).ok();
        assert_eq!(events.lock().unwrap().last().unwrap().kind, EVENT_DONE);
    }

    /// 可编程的测试服务器：每个请求交给 [respond]（请求序号、Range 起点），返回要写回的原始 HTTP 响应，写完即断开。
    /// 返回地址与记录下来的各请求 Range 起点。
    #[allow(clippy::type_complexity)]
    fn serve_with(
        respond: impl Fn(usize, Option<usize>) -> Vec<u8> + Send + Sync + 'static,
    ) -> (String, Arc<Mutex<Vec<Option<usize>>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let ranges = Arc::new(Mutex::new(Vec::new()));
        let seen = ranges.clone();
        let respond = Arc::new(respond);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = match stream { Ok(s) => s, Err(_) => break };
                let respond = respond.clone();
                let seen = seen.clone();
                std::thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let n = stream.read(&mut buf).unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                    let start = text
                        .lines()
                        .find_map(|l| l.strip_prefix("range: bytes="))
                        .and_then(|r| r.trim().split_once('-'))
                        .and_then(|(a, _)| a.parse::<usize>().ok());
                    let index = {
                        let mut seen = seen.lock().unwrap();
                        seen.push(start);
                        seen.len() - 1
                    };
                    let _ = stream.write_all(&respond(index, start));
                    let _ = stream.flush();
                });
            }
        });
        (format!("http://{addr}/audio"), ranges)
    }

    fn ok_full(body: &[u8]) -> Vec<u8> {
        let mut r = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).into_bytes();
        r.extend_from_slice(body);
        r
    }

    fn partial_from(body: &[u8], start: usize) -> Vec<u8> {
        let mut r = format!(
            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{}/{}\r\nConnection: close\r\n\r\n",
            body.len() - start,
            body.len() - 1,
            body.len()
        )
        .into_bytes();
        r.extend_from_slice(&body[start..]);
        r
    }

    /// 声明完整长度但只发前 [cut] 字节就断开（模拟中途断线）。
    fn broken_full(body: &[u8], cut: usize) -> Vec<u8> {
        let mut r = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).into_bytes();
        r.extend_from_slice(&body[..cut]);
        r
    }

    fn targets(urls: &[&str]) -> Vec<DownloadTarget> {
        urls.iter().map(|u| DownloadTarget { url: u.to_string(), ..Default::default() }).collect()
    }

    /// 按数据块的文件偏移拼回整个文件（与 Dart 侧写播放缓冲区的方式一致）。
    fn assemble(events: &[DownloadEvent]) -> Vec<u8> {
        let mut out = Vec::new();
        for e in events.iter().filter(|e| e.kind == EVENT_DATA) {
            let start = e.bytes as usize;
            let end = start + e.data.len();
            if out.len() < end {
                out.resize(end, 0);
            }
            out[start..end].copy_from_slice(&e.data);
        }
        out
    }

    fn encrypted(plain: &[u8], key: &[u8], iv: &[u8]) -> Vec<u8> {
        let mut data = plain.to_vec();
        AesCtr::at_offset(key, iv, 0).unwrap().process(&mut data);
        data
    }

    const KEY: [u8; 16] = [7u8; 16];
    const IV: [u8; 16] = [9u8; 16];

    #[test]
    fn progressive_download_decrypts_whole_file_in_order() {
        let plain = body(40_000);
        let cipher = encrypted(&plain, &KEY, &IV);
        let (url, ranges) = serve_with(move |_, _| ok_full(&cipher));
        let (emit, events) = collect();
        block(download_progressive(targets(&[&url]), KEY.to_vec(), IV.to_vec(), 3, emit));
        let events = events.lock().unwrap();
        assert_eq!(events[0].kind, EVENT_META);
        assert_eq!((events[0].status, events[0].total, events[0].bytes), (200, 40_000, 0));
        // 数据块首尾相接
        let mut next = 0;
        for e in events.iter().filter(|e| e.kind == EVENT_DATA) {
            assert_eq!(e.bytes, next);
            next += e.data.len() as u64;
        }
        assert_eq!(assemble(&events), plain);
        let last = events.last().unwrap();
        assert_eq!((last.kind, last.total), (EVENT_DONE, 40_000));
        assert_eq!(ranges.lock().unwrap().as_slice(), &[None]);
    }

    #[test]
    fn progressive_download_resumes_with_range_on_next_cdn() {
        let plain = body(60_000);
        let cipher = Arc::new(encrypted(&plain, &KEY, &IV));
        let first = cipher.clone();
        let (url1, ranges1) = serve_with(move |_, _| broken_full(&first, 20_000));
        let second = cipher.clone();
        let (url2, ranges2) = serve_with(move |_, start| partial_from(&second, start.unwrap_or(0)));
        let (emit, events) = collect();
        block(download_progressive(targets(&[&url1, &url2]), KEY.to_vec(), IV.to_vec(), 4, emit));
        let events = events.lock().unwrap();
        assert_eq!(events.last().unwrap().kind, EVENT_DONE, "{:?}", events.last());
        assert_eq!(assemble(&events), plain);
        assert_eq!(ranges1.lock().unwrap().as_slice(), &[None]);
        // 第二次请求从第一次已收到的位置续传
        let resumed = ranges2.lock().unwrap()[0].expect("续传请求应带 Range");
        assert!(resumed > 0 && resumed <= 20_000, "{resumed}");
        let meta: Vec<_> = events.iter().filter(|e| e.kind == EVENT_META).collect();
        assert_eq!(meta.len(), 2);
        assert_eq!((meta[1].status, meta[1].bytes, meta[1].total), (206, resumed as u64, 60_000));
    }

    #[test]
    fn progressive_download_restarts_when_server_ignores_range() {
        let plain = body(30_000);
        let cipher = encrypted(&plain, &KEY, &IV);
        let (url, ranges) = serve_with(move |i, _| if i == 0 { broken_full(&cipher, 9_000) } else { ok_full(&cipher) });
        let (emit, events) = collect();
        block(download_progressive(targets(&[&url]), KEY.to_vec(), IV.to_vec(), 3, emit));
        let events = events.lock().unwrap();
        assert_eq!(events.last().unwrap().kind, EVENT_DONE);
        assert_eq!(assemble(&events), plain);
        let ranges = ranges.lock().unwrap();
        assert_eq!(ranges.len(), 2);
        assert!(ranges[1].is_some(), "第二次应请求续传");
        let meta: Vec<_> = events.iter().filter(|e| e.kind == EVENT_META).collect();
        assert_eq!((meta[1].status, meta[1].bytes), (200, 0), "忽略 Range 时从头写");
    }

    #[test]
    fn progressive_download_without_length_restarts_from_zero() {
        let plain = body(12_000);
        // 第一次回 500，第二次给出没有 Content-Length 的完整内容（读到连接关闭为止）
        let no_length = move |i: usize, _: Option<usize>| {
            if i == 0 {
                return b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec();
            }
            let mut r = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_vec();
            r.extend_from_slice(&plain);
            r
        };
        let expected = body(12_000);
        let (url, ranges) = serve_with(no_length);
        let (emit, events) = collect();
        block(download_progressive(targets(&[&url]), vec![], vec![], 3, emit));
        let events = events.lock().unwrap();
        let last = events.last().unwrap();
        assert_eq!((last.kind, last.total), (EVENT_DONE, 12_000), "{last:?}");
        assert_eq!(assemble(&events), expected);
        let meta: Vec<_> = events.iter().filter(|e| e.kind == EVENT_META).collect();
        assert_eq!((meta[0].total, meta[0].bytes), (0, 0), "总长未知");
        assert_eq!(ranges.lock().unwrap().as_slice(), &[None, None], "总长未知时不续传");
    }

    #[test]
    fn progressive_download_gives_up_after_max_attempts() {
        let (url, ranges) = serve_with(|_, _| b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec());
        let (emit, events) = collect();
        block(download_progressive(targets(&[&url]), KEY.to_vec(), IV.to_vec(), 2, emit));
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, EVENT_ERROR);
        assert!(events[0].message.starts_with("request:所有 CDN 地址下载失败"), "{}", events[0].message);
        assert!(events[0].message.contains("HTTP 403"));
        assert_eq!(ranges.lock().unwrap().len(), 2);
    }

    #[test]
    fn progressive_download_without_targets_fails() {
        let (emit, events) = collect();
        block(download_progressive(vec![], vec![], vec![], 3, emit));
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, EVENT_ERROR);
    }

    #[test]
    fn progressive_download_rejects_data_beyond_declared_length() {
        // 声明 1000 字节却发了 2000：每次都失败
        let (url, _) = serve_with(|_, _| {
            let mut r = b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-999/1000\r\nConnection: close\r\n\r\n".to_vec();
            r.extend_from_slice(&body(2000));
            r
        });
        let (emit, events) = collect();
        block(download_progressive(targets(&[&url]), vec![], vec![], 1, emit));
        let last = events.lock().unwrap().last().unwrap().clone();
        assert_eq!(last.kind, EVENT_ERROR);
        assert!(last.message.contains("超出声明长度"), "{}", last.message);
    }

    #[test]
    fn cancelling_stops_the_download() {
        let (url, ranges) = serve_with(|_, _| ok_full(&body(200_000)));
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let emit: Emit = Arc::new(move |e| {
            seen.fetch_add(1, Ordering::SeqCst);
            e.kind != EVENT_DATA // 第一块数据后取消
        });
        block(download_progressive(targets(&[&url]), vec![], vec![], 4, emit));
        assert_eq!(count.load(Ordering::SeqCst), 2, "元信息 + 一块数据之后不再上报");
        assert_eq!(ranges.lock().unwrap().len(), 1, "取消后不重试");
    }

    #[test]
    fn unreachable_cdn_reports_the_reason() {
        let (emit, events) = collect();
        block(download_progressive(targets(&["http://127.0.0.1:1/x"]), vec![], vec![], 2, emit));
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, EVENT_ERROR);
        assert!(events[0].message.starts_with("request:所有 CDN 地址下载失败："), "{}", events[0].message);
    }

    #[test]
    fn detail_strips_known_prefixes_only() {
        assert_eq!(detail("connect:refused"), "refused");
        assert_eq!(detail("request:HTTP 403"), "HTTP 403");
        assert_eq!(detail("other:x"), "other:x");
    }
}
