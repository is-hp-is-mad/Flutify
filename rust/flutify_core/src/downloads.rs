//! 音频下载（边下边播）：
//! - [download_to_file]：EME 主链路。多连接分段 Range 下载直接写文件，按「从 0 起连续可用字节」汇报进度，
//!   语义与 `lib/services/eme/segmented_download.dart` 一致；CDN 支持 HTTP/2 时多段共用一条连接。
//! - [download_decrypt]：AP 链路。下载同时 AES-128-CTR 解密，解密块逐个交给调用方（不再经 Dart 解密 Isolate 往返）。
//!
//! 结果通过回调逐个上报（api 层把它接到 frb 的 StreamSink）；回调返回 false 表示调用方已取消，立即停止下载。
//! 只处理直连的 CDN 请求，网关 / 代理由 Dart 侧判断后不走这里。

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

fn request(url: &str, headers: &[(String, String)], range: Option<(u64, Option<u64>)>) -> reqwest::RequestBuilder {
    let mut builder = http_client::shared_client()
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
    builder
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
// 下载 + 解密（AP 链路）
// ---------------------------------------------------------------------------

/// 从 [offset] 起下载 [url] 到结尾，[key] 非空时按 AES-128-CTR（文件坐标）解密后逐块上报。
/// 先报一次元信息（status 与总长度），再逐块报数据，最后报完成或失败。
/// 服务器忽略 Range（回 200）时从文件开头解密，调用方据 status 判断写入位置。
pub async fn download_decrypt(
    url: String,
    headers: Vec<(String, String)>,
    offset: u64,
    key: Vec<u8>,
    iv: Vec<u8>,
    emit: Emit,
) {
    let result = run_decrypt(&url, &headers, offset, &key, &iv, &emit).await;
    match result {
        Ok(()) => {}
        Err(message) => {
            emit(DownloadEvent { kind: EVENT_ERROR, message, ..Default::default() });
        }
    }
}

async fn run_decrypt(
    url: &str,
    headers: &[(String, String)],
    offset: u64,
    key: &[u8],
    iv: &[u8],
    emit: &Emit,
) -> Result<(), String> {
    let range = (offset > 0).then_some((offset, None));
    let response = request(url, headers, range).send().await.map_err(|e| error_text(&e))?;
    let status = response.status().as_u16();
    if status != 200 && status != 206 {
        return Err(format!("request:CDN 返回 HTTP {status}"));
    }
    let total = if status == 206 {
        total_from_content_range(&response).unwrap_or(0)
    } else {
        response.content_length().unwrap_or(0)
    };
    if !emit(DownloadEvent { kind: EVENT_META, status, total, ..Default::default() }) {
        return Ok(());
    }
    let start = if status == 206 { offset } else { 0 };
    let mut ctr = if key.is_empty() {
        None
    } else {
        Some(AesCtr::at_offset(key, iv, start as usize).map_err(|e| format!("request:{e}"))?)
    };
    let mut stream = response.bytes_stream();
    let mut received = start;
    while let Some(chunk) = stream.next().await {
        let mut data = chunk.map_err(|e| format!("request:{e}"))?.to_vec();
        if let Some(ctr) = ctr.as_mut() {
            ctr.process(&mut data);
        }
        received += data.len() as u64;
        if !emit(DownloadEvent { kind: EVENT_DATA, data, ..Default::default() }) {
            return Ok(()); // 已取消：丢弃响应即关闭连接
        }
    }
    emit(DownloadEvent { kind: EVENT_DONE, total: received, ..Default::default() });
    Ok(())
}

// ---------------------------------------------------------------------------
// 分段下载写文件（EME 链路）
// ---------------------------------------------------------------------------

pub struct FileDownloadOptions {
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
            match request(&url, &self.options.headers, Some((start, Some(end)))).send().await {
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
    let first = request(&url, &shared.options.headers, Some((0, Some(segment_bytes - 1))))
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
    let total = total_from_content_range(&first)
        .filter(|t| *t > 0)
        .ok_or_else(|| "request:CDN 未返回 Content-Range 总长".to_string())?;
    let count = total.div_ceil(segment_bytes) as usize;
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

    #[test]
    fn decrypting_download_matches_aes_ctr_and_resumes_at_offset() {
        let plain = body(4000);
        let key = vec![7u8; 16];
        let iv = vec![9u8; 16];
        let mut encrypted = plain.clone();
        AesCtr::at_offset(&key, &iv, 0).unwrap().process(&mut encrypted);
        let url = serve(encrypted, true, Arc::new(AtomicUsize::new(0)));

        for offset in [0u64, 1234] {
            let (emit, events) = collect();
            block(download_decrypt(url.clone(), vec![], offset, key.clone(), iv.clone(), emit));
            let events = events.lock().unwrap();
            assert_eq!(events[0].kind, EVENT_META);
            assert_eq!(events[0].total, 4000);
            let out: Vec<u8> = events.iter().filter(|e| e.kind == EVENT_DATA).flat_map(|e| e.data.clone()).collect();
            assert_eq!(out, plain[offset as usize..]);
            assert_eq!(events.last().unwrap().kind, EVENT_DONE);
        }
    }

    #[test]
    fn cancelling_stops_the_download() {
        let url = serve(body(200_000), true, Arc::new(AtomicUsize::new(0)));
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        let emit: Emit = Arc::new(move |e| {
            if e.kind == EVENT_DATA {
                seen.fetch_add(1, Ordering::SeqCst);
                return false; // 第一块数据后取消
            }
            true
        });
        block(download_decrypt(url, vec![], 0, vec![], vec![], emit));
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn unreachable_cdn_is_a_connect_error() {
        let (emit, events) = collect();
        block(download_decrypt("http://127.0.0.1:1/x".into(), vec![], 0, vec![], vec![], emit));
        let events = events.lock().unwrap();
        assert_eq!(events.last().unwrap().kind, EVENT_ERROR);
        assert!(events.last().unwrap().message.starts_with("connect:"));
    }
}
