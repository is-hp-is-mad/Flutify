//! 边下边播（AP 链路）的 Dart 接口：下载、AES-128-CTR 解密、断线续传、CDN 轮换与重试都在 Rust 完成，
//! Dart 只把推送来的明文块按文件偏移放进播放缓冲区（取消订阅即停止下载）。

use std::sync::Arc;

use crate::api::network::AudioDownloadEvent;
use crate::api::protocol::HttpHeaderEntry;
use crate::downloads::{self, DownloadEvent, DownloadTarget, Emit};
use crate::frb_generated::StreamSink;
use crate::http_client;

/// 一个 CDN 地址及其路线：`proxy` 空 = 直连，否则为 Dart 侧选出的代理；`headers` 为额外请求头（网关凭据）。
pub struct AudioDownloadTarget {
    pub proxy: String,
    pub url: String,
    pub headers: Vec<HttpHeaderEntry>,
}

/// 下载并解密整首音频（[key] 为空时不解密），事件语义见 `downloads::download_progressive`：
/// `kind` 0 元信息（`total` 0 = 未知，`bytes` = 本次数据起点）/ 1 数据块（`bytes` = 文件偏移）/
/// 3 完成（`total`）/ 4 失败（`message`，已含全部重试的结论）。
pub fn audio_progressive_download(
    sink: StreamSink<AudioDownloadEvent>,
    targets: Vec<AudioDownloadTarget>,
    key: Vec<u8>,
    iv: Vec<u8>,
    max_attempts: u32,
) {
    let emit: Emit = Arc::new(move |event: DownloadEvent| sink.add(event.into()).is_ok());
    let targets = targets
        .into_iter()
        .map(|t| DownloadTarget {
            proxy: t.proxy,
            url: t.url,
            headers: t.headers.into_iter().map(|h| (h.name, h.value)).collect(),
        })
        .collect();
    http_client::runtime().spawn(downloads::download_progressive(targets, key, iv, max_attempts, emit));
}
