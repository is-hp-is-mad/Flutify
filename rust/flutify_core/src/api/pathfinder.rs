//! Pathfinder 查询 + 解析的 Dart 接口：Rust 发请求、直接解析成类型化 DTO，
//! 不再把整段 JSON 字符串交回 Dart 解码再解析（大响应可达数 MB）。
//!
//! 每个函数的 `hash` / `variables_json` 与 Dart `PathfinderOperation` 一致；错误串沿用
//! `rust_pathfinder_query`（`http:{status}:…`、`auth:missing…` 等），解析错误为 `format:{说明}`。

use serde_json::Value;

use crate::api::backend::{
    RustAlbumDto, RustArtistDto, RustImageDto, RustPlaylistSummaryDto, RustTrackDto,
};
use crate::http_client;
use crate::spotify_backend::{
    self, BackendCatalogPage, BackendCategory, BackendHomeChip, BackendHomeFeed, BackendHomeItem,
    BackendHomeSection,
};
use crate::spotify_session;

pub struct RustHomeChipDto {
    pub id: String,
    pub label: String,
    pub sub_chips: Vec<RustHomeChipDto>,
}

pub struct RustHomeItemDto {
    /// 0 playlist、1 album、2 artist、3 likedSongs、4 podcast、5 episode（与 Dart `HomeItemKind` 顺序一致）。
    pub kind: i32,
    pub uri: String,
    pub title: String,
    pub subtitle: String,
    pub images: Vec<RustImageDto>,
    pub reason: String,
    pub reason_artist: Option<RustArtistDto>,
    pub playlist: Option<RustPlaylistSummaryDto>,
    pub album: Option<RustAlbumDto>,
    pub artist: Option<RustArtistDto>,
    pub parent_uri: String,
}

pub struct RustHomeSectionDto {
    pub uri: String,
    /// 0 shelf、1 recents、2 feed（与 Dart `HomeSectionKind` 顺序一致）。
    pub kind: i32,
    pub title: String,
    pub subtitle: String,
    pub header_artist: Option<RustArtistDto>,
    pub items: Vec<RustHomeItemDto>,
    pub total_count: i32,
}

pub struct RustHomeFeedDto {
    pub greeting: String,
    pub chips: Vec<RustHomeChipDto>,
    pub shortcuts: Vec<RustHomeItemDto>,
    pub sections: Vec<RustHomeSectionDto>,
}

pub struct RustCategoryDto {
    pub id: String,
    pub name: String,
    pub icon_url: String,
    /// `#rrggbb`；空表示服务端没给（Dart 侧用默认色）。
    pub color_hex: String,
}

pub struct RustTrackCatalogPageDto {
    pub items: Vec<RustTrackDto>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

pub struct RustArtistCatalogPageDto {
    pub items: Vec<RustArtistDto>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

pub struct RustPlaylistCatalogPageDto {
    pub items: Vec<RustPlaylistSummaryDto>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

pub struct RustAlbumCatalogPageDto {
    pub items: Vec<RustAlbumDto>,
    pub offset: i32,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
}

pub struct RustSearchPageDto {
    pub tracks: RustTrackCatalogPageDto,
    pub artists: RustArtistCatalogPageDto,
    pub playlists: RustPlaylistCatalogPageDto,
}

pub struct RustAlbumQueryDto {
    /// 专辑缺失时为 None（`page_error` 为 `format:Missing album`）。
    pub album: Option<RustAlbumDto>,
    pub tracks: Vec<RustTrackDto>,
    pub total: Option<i32>,
    pub next_offset: Option<i32>,
    /// 曲目分页解析失败的原因（`format:` 前缀）；专辑页本身仍可用。
    pub page_error: Option<String>,
}

pub struct RustArtistOverviewDto {
    pub artist: RustArtistDto,
    pub top_tracks: Vec<RustTrackDto>,
}

pub struct RustLibraryTrackDto {
    pub track: RustTrackDto,
    /// `addedAt.isoString` 原样字符串（交给 Dart `DateTime.tryParse`）。
    pub added_at_iso: Option<String>,
}

pub struct RustLibraryTracksPageDto {
    pub items: Vec<RustLibraryTrackDto>,
    pub total_count: i32,
}

impl From<BackendHomeChip> for RustHomeChipDto {
    fn from(v: BackendHomeChip) -> Self {
        Self {
            id: v.id,
            label: v.label,
            sub_chips: v.sub_chips.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendHomeItem> for RustHomeItemDto {
    fn from(v: BackendHomeItem) -> Self {
        Self {
            kind: v.kind,
            uri: v.uri,
            title: v.title,
            subtitle: v.subtitle,
            images: v.images.into_iter().map(Into::into).collect(),
            reason: v.reason,
            reason_artist: v.reason_artist.map(Into::into),
            playlist: v.playlist.map(Into::into),
            album: v.album.map(Into::into),
            artist: v.artist.map(Into::into),
            parent_uri: v.parent_uri,
        }
    }
}

impl From<BackendHomeSection> for RustHomeSectionDto {
    fn from(v: BackendHomeSection) -> Self {
        Self {
            uri: v.uri,
            kind: v.kind,
            title: v.title,
            subtitle: v.subtitle,
            header_artist: v.header_artist.map(Into::into),
            items: v.items.into_iter().map(Into::into).collect(),
            total_count: v.total_count,
        }
    }
}

impl From<BackendHomeFeed> for RustHomeFeedDto {
    fn from(v: BackendHomeFeed) -> Self {
        Self {
            greeting: v.greeting,
            chips: v.chips.into_iter().map(Into::into).collect(),
            shortcuts: v.shortcuts.into_iter().map(Into::into).collect(),
            sections: v.sections.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendCategory> for RustCategoryDto {
    fn from(v: BackendCategory) -> Self {
        Self {
            id: v.id,
            name: v.name,
            icon_url: v.icon_url,
            color_hex: v.color_hex,
        }
    }
}

macro_rules! catalog_page_from {
    ($dto:ident, $item:ty) => {
        impl From<BackendCatalogPage<$item>> for $dto {
            fn from(v: BackendCatalogPage<$item>) -> Self {
                Self {
                    items: v.items.into_iter().map(Into::into).collect(),
                    offset: v.offset,
                    total: v.total,
                    next_offset: v.next_offset,
                }
            }
        }
    };
}

catalog_page_from!(RustTrackCatalogPageDto, spotify_backend::BackendTrack);
catalog_page_from!(RustArtistCatalogPageDto, spotify_backend::BackendArtist);
catalog_page_from!(RustPlaylistCatalogPageDto, spotify_backend::BackendPlaylistSummary);
catalog_page_from!(RustAlbumCatalogPageDto, spotify_backend::BackendAlbum);

/// 在 Rust 运行时里（带请求级代理）执行一次 Pathfinder 查询，再在同一任务里解析。
async fn query_and_parse<T, F>(
    operation: String,
    hash: String,
    variables_json: String,
    proxy: String,
    parse: F,
) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(&Value) -> Result<T, String> + Send + 'static,
{
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let vars: Value =
                serde_json::from_str(&variables_json).map_err(|e| format!("bad_vars:{e}"))?;
            let data = spotify_session::pathfinder_query(&operation, &hash, vars).await?;
            parse(&data)
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_pf_home(
    hash: String,
    variables_json: String,
    proxy: String,
) -> Result<RustHomeFeedDto, String> {
    query_and_parse("home".into(), hash, variables_json, proxy, |d| {
        Ok(spotify_backend::parse_home_feed(d).into())
    })
    .await
}

pub async fn rust_pf_browse_sections(
    hash: String,
    variables_json: String,
    proxy: String,
) -> Result<Vec<RustHomeSectionDto>, String> {
    query_and_parse("browsePage".into(), hash, variables_json, proxy, |d| {
        Ok(spotify_backend::parse_browse_sections(d).into_iter().map(Into::into).collect())
    })
    .await
}

pub async fn rust_pf_categories(
    hash: String,
    variables_json: String,
    proxy: String,
) -> Result<Vec<RustCategoryDto>, String> {
    query_and_parse("browseAll".into(), hash, variables_json, proxy, |d| {
        Ok(spotify_backend::parse_categories(d).into_iter().map(Into::into).collect())
    })
    .await
}

pub async fn rust_pf_search(
    hash: String,
    variables_json: String,
    offset: i32,
    limit: i32,
    proxy: String,
) -> Result<RustSearchPageDto, String> {
    query_and_parse("searchDesktop".into(), hash, variables_json, proxy, move |d| {
        let page = spotify_backend::parse_search_page(d, offset, limit)?;
        Ok(RustSearchPageDto {
            tracks: page.tracks.into(),
            artists: page.artists.into(),
            playlists: page.playlists.into(),
        })
    })
    .await
}

pub async fn rust_pf_album(
    hash: String,
    variables_json: String,
    offset: i32,
    limit: i32,
    proxy: String,
) -> Result<RustAlbumQueryDto, String> {
    query_and_parse("getAlbum".into(), hash, variables_json, proxy, move |d| {
        let q = spotify_backend::parse_album_query(d, offset, limit);
        Ok(RustAlbumQueryDto {
            album: q.album.map(Into::into),
            tracks: q.tracks.into_iter().map(Into::into).collect(),
            total: q.total,
            next_offset: q.next_offset,
            page_error: q.page_error,
        })
    })
    .await
}

pub async fn rust_pf_artist_overview(
    hash: String,
    variables_json: String,
    proxy: String,
) -> Result<Option<RustArtistOverviewDto>, String> {
    query_and_parse("queryArtistOverview".into(), hash, variables_json, proxy, |d| {
        Ok(spotify_backend::parse_artist_overview(d).map(|p| RustArtistOverviewDto {
            artist: p.artist.into(),
            top_tracks: p.top_tracks.into_iter().map(Into::into).collect(),
        }))
    })
    .await
}

/// 唱片目录一页；[fallback_artist] 回填条目缺失的艺人（与 Dart `discographyPage(artist:)` 一致）。
pub async fn rust_pf_discography(
    hash: String,
    variables_json: String,
    fallback_artist: Option<RustArtistDto>,
    offset: i32,
    limit: i32,
    proxy: String,
) -> Result<RustAlbumCatalogPageDto, String> {
    let fallback = fallback_artist.map(Into::into);
    query_and_parse("queryArtistDiscographyAll".into(), hash, variables_json, proxy, move |d| {
        Ok(spotify_backend::parse_artist_discography_page(d, fallback, offset, limit)?.into())
    })
    .await
}

pub async fn rust_pf_library_tracks(
    hash: String,
    variables_json: String,
    proxy: String,
) -> Result<RustLibraryTracksPageDto, String> {
    query_and_parse("fetchLibraryTracks".into(), hash, variables_json, proxy, |d| {
        let page = spotify_backend::parse_library_tracks_page(d);
        Ok(RustLibraryTracksPageDto {
            items: page
                .items
                .into_iter()
                .map(|i| RustLibraryTrackDto {
                    track: i.track.into(),
                    added_at_iso: i.added_at_iso,
                })
                .collect(),
            total_count: page.total_count,
        })
    })
    .await
}
