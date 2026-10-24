//! 音频下载与 WebSocket 的 Dart 接口（事件经 StreamSink 推送；Dart 取消订阅即停止）。

use std::sync::Arc;

use crate::api::protocol::HttpHeaderEntry;
use crate::downloads::{self, DownloadEvent, Emit, FileDownloadOptions};
use crate::frb_generated::StreamSink;
use crate::http_client;
use crate::ws::{self, WsEmit, WsEvent};

/// 下载事件：`kind` 0 元信息 / 1 数据块 / 2 进度 / 3 完成 / 4 失败（`message` 以 `connect:` 开头表示一个字节都没收到）。
pub struct AudioDownloadEvent {
    pub kind: u8,
    pub status: u16,
    pub total: i64,
    pub bytes: i64,
    pub data: Vec<u8>,
    pub message: String,
}

impl From<DownloadEvent> for AudioDownloadEvent {
    fn from(e: DownloadEvent) -> Self {
        Self {
            kind: e.kind,
            status: e.status,
            total: e.total as i64,
            bytes: e.bytes as i64,
            data: e.data,
            message: e.message,
        }
    }
}

fn pairs(headers: Vec<HttpHeaderEntry>) -> Vec<(String, String)> {
    headers.into_iter().map(|h| (h.name, h.value)).collect()
}

fn download_emit(sink: StreamSink<AudioDownloadEvent>) -> Emit {
    Arc::new(move |event: DownloadEvent| sink.add(event.into()).is_ok())
}

/// AP 链路：从 [offset] 起下载并（[key] 非空时）AES-128-CTR 解密，逐块推送解密后的数据。
pub fn audio_download_decrypt(
    sink: StreamSink<AudioDownloadEvent>,
    url: String,
    headers: Vec<HttpHeaderEntry>,
    offset: i64,
    key: Vec<u8>,
    iv: Vec<u8>,
) {
    let emit = download_emit(sink);
    http_client::runtime().spawn(downloads::download_decrypt(
        url,
        pairs(headers),
        offset.max(0) as u64,
        key,
        iv,
        emit,
    ));
}

/// EME 链路：多连接分段下载写入 [path]，推送「从 0 起连续可用字节」进度。
pub fn audio_download_to_file(
    sink: StreamSink<AudioDownloadEvent>,
    urls: Vec<String>,
    headers: Vec<HttpHeaderEntry>,
    path: String,
    segment_bytes: i64,
    connections: u32,
    max_attempts_per_segment: u32,
) {
    let emit = download_emit(sink);
    http_client::runtime().spawn(downloads::download_to_file(
        FileDownloadOptions {
            urls,
            headers: pairs(headers),
            path,
            segment_bytes: segment_bytes.max(1) as u64,
            connections,
            max_attempts_per_segment,
        },
        emit,
    ));
}

/// WebSocket 事件：`kind` 0 已连接 / 1 文本帧 / 2 已关闭（`code`、`text` 为原因）/ 3 出错（以 `connect:` 开头表示握手没成功）。
pub struct WebSocketEvent {
    pub kind: u8,
    pub text: String,
    pub code: u16,
}

impl From<WsEvent> for WebSocketEvent {
    fn from(e: WsEvent) -> Self {
        Self { kind: e.kind, text: e.text, code: e.code }
    }
}

/// 建立 WebSocket 连接（[id] 由 Dart 分配），事件持续推送到连接关闭。
pub fn websocket_connect(
    sink: StreamSink<WebSocketEvent>,
    id: i64,
    url: String,
    headers: Vec<HttpHeaderEntry>,
) {
    let emit: WsEmit = Arc::new(move |event: WsEvent| sink.add(event.into()).is_ok());
    http_client::runtime().spawn(ws::connect(id as u64, url, pairs(headers), emit));
}

/// 发送文本帧；连接已关闭时返回错误。
#[flutter_rust_bridge::frb(sync)]
pub fn websocket_send(id: i64, text: String) -> Result<(), String> {
    ws::send(id as u64, text)
}

/// 主动关闭连接。
#[flutter_rust_bridge::frb(sync)]
pub fn websocket_close(id: i64) {
    ws::close(id as u64)
}
