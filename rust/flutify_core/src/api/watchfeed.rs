//! Watch Feed 响应纯解析接口（通过 flutter_rust_bridge 暴露给 Dart）。
//!
//! 网络请求不经 Rust 时（自定义网关、Pathfinder 由 Dart 发起），Dart 拿到响应后交给这里解析，
//! 保证所有 Watch Feed 数据都由 Rust 解析。

use crate::api::backend::{RustWatchFeedItemDto, RustWatchFeedPageDto, RustWatchFeedShelfDto};
use crate::watchfeed_backend;

/// 桌面版实体 feed（Pathfinder `watchFeedEntity`）的一页。
pub struct RustWatchFeedEntityPageDto {
    pub items: Vec<RustWatchFeedItemDto>,
    pub total_count: i64,
    pub next_offset: Option<i64>,
}

/// `watch-feed-view/v1/feed` Protobuf 响应 → 一页。
pub fn rust_parse_watch_feed(bytes: Vec<u8>) -> RustWatchFeedPageDto {
    watchfeed_backend::parse_feed(&bytes).into()
}

/// `browsita/v1/browse` Protobuf 响应 → 第一个 WatchFeed 区块；没有则 None。
pub fn rust_parse_watch_feed_browse_shelf(bytes: Vec<u8>) -> Option<RustWatchFeedShelfDto> {
    watchfeed_backend::parse_browse_shelf(&bytes).map(Into::into)
}

/// `watch-feed-entrypoints/v1/discovery-from-seed` Protobuf 响应 → 卡片行；没有内容为 None。
pub fn rust_parse_watch_feed_seed_shelf(bytes: Vec<u8>) -> Option<RustWatchFeedShelfDto> {
    watchfeed_backend::parse_seed_shelf(&bytes).map(Into::into)
}

/// Pathfinder `watchFeedEntity` 响应的 `data` 对象（JSON 文本）→ 一页。
pub fn rust_parse_watch_feed_entity(data_json: String) -> Result<RustWatchFeedEntityPageDto, String> {
    let data: serde_json::Value = serde_json::from_str(&data_json).map_err(|e| e.to_string())?;
    let page = watchfeed_backend::parse_entity_feed(&data);
    Ok(RustWatchFeedEntityPageDto {
        items: page.items.into_iter().map(Into::into).collect(),
        total_count: page.total_count,
        next_offset: page.next_offset,
    })
}

/// Pathfinder `watchFeedView` 响应的 `data` 对象（JSON 文本）→ 一页；
/// [previous_items] 为之前各页已出现的条目 uri（写进下一页令牌）。
pub fn rust_parse_watch_feed_discovery_view(
    data_json: String,
    previous_items: Vec<String>,
) -> Result<RustWatchFeedPageDto, String> {
    let data: serde_json::Value = serde_json::from_str(&data_json).map_err(|e| e.to_string())?;
    Ok(watchfeed_backend::parse_discovery_feed_view(&data, &previous_items).into())
}
