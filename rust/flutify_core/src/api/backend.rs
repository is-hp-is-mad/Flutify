//! Rust 后端会话、令牌刷新与高并发媒体库接口（通过 flutter_rust_bridge 暴露给 Dart）。

use crate::ap_client::{self, BackendApWelcome, BackendStorageResolveResult};
use crate::audio_cache;
use crate::catalog_backend::{
    self, BackendCanvasMedia, BackendPodcastEpisode, BackendPodcastShow,
};
use crate::connect_backend;
use crate::drm_backend::{
    self, BackendDrmRelayResult, BackendPlaybackFile, BackendPlayplayKey, BackendProtoAudioFile,
    BackendProtoEpisodeMetadata, BackendProtoTrackMetadata, BackendTrackPlaybackMedia,
};
use crate::frb_generated::StreamSink;
use crate::http_client;
use crate::lyrics_backend::{
    self, BackendLrclibCandidate, BackendLrclibResponse, BackendSpotifyLyricAlternative,
    BackendSpotifyLyricLine, BackendSpotifyLyrics,
};
use crate::spotify_backend::{
    self, BackendAlbum, BackendArtist, BackendCollectionEntry, BackendCreditGroup,
    BackendCreditPerson, BackendImage, BackendPlaylist, BackendPlaylistSummary, BackendTrack,
    BackendTrackCredits,
};
use crate::spotify_session::{self, SessionState};
use crate::watchfeed_backend::{
    self, BackendWatchFeedAudio, BackendWatchFeedCreator, BackendWatchFeedEntityRow,
    BackendWatchFeedEntry, BackendWatchFeedHashtag, BackendWatchFeedItem, BackendWatchFeedPage,
    BackendWatchFeedShelf, BackendWatchFeedVisual,
};

pub struct RustSessionConfig {
    pub sp_dc: String,
    pub access_token: String,
    pub access_token_expiry_ms: i64,
    pub client_token: String,
    pub client_token_expiry_ms: i64,
    pub device_id: String,
    pub proxy: String,
    pub epoch: u64,
}

pub struct RustTokenResult {
    pub token: String,
    pub expiry_ms: i64,
}

pub struct RustImageDto {
    pub url: String,
    pub width: Option<i32>,
    pub height: Option<i32>,
}

pub struct RustArtistDto {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub images: Vec<RustImageDto>,
    pub followers: Option<i64>,
}

pub struct RustAlbumDto {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub images: Vec<RustImageDto>,
}

pub struct RustTrackDto {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub artists: Vec<RustArtistDto>,
    pub album: Option<RustAlbumDto>,
    pub duration_ms: i32,
    pub explicit: bool,
    pub is_playable: bool,
    pub added_at_ms: Option<i64>,
}

pub struct RustPlaylistDto {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub description: String,
    pub owner_name: String,
    pub images: Vec<RustImageDto>,
    pub total_tracks: i32,
    pub tracks: Vec<RustTrackDto>,
}

pub struct RustCollectionEntryDto {
    pub uri: String,
    pub id: String,
    pub added_at_sec: i64,
}

pub struct RustPlaylistSummaryDto {
    pub id: String,
    pub name: String,
    pub uri: String,
    pub description: String,
    pub owner_name: String,
    pub images: Vec<RustImageDto>,
    pub total_tracks: i32,
}

pub struct RustCreditPersonDto {
    pub name: String,
    pub roles: Vec<String>,
    pub artist_id: String,
}

pub struct RustCreditGroupDto {
    pub name: String,
    pub people: Vec<RustCreditPersonDto>,
}

pub struct RustTrackCreditsDto {
    pub track_name: String,
    pub groups: Vec<RustCreditGroupDto>,
    pub sources: Vec<String>,
}

pub struct RustWatchFeedEntryDto {
    pub title: String,
    pub subtitle: String,
    pub overline: String,
    pub feed_uri: String,
    pub first_item_uri: String,
    pub thumbnail_url: String,
    pub video_url: String,
    pub cover_url: String,
    pub accessibility_text: String,
}

pub struct RustWatchFeedShelfDto {
    pub title: String,
    pub entries: Vec<RustWatchFeedEntryDto>,
}

pub struct RustWatchFeedVisualDto {
    pub kind: i32,
    pub video_url: String,
    pub image_url: String,
    pub animation_url: String,
    pub colors: Vec<String>,
}

pub struct RustWatchFeedAudioDto {
    pub url: String,
    pub should_loop: bool,
    pub fade_in: bool,
}

pub struct RustWatchFeedCreatorDto {
    pub uri: String,
    pub name: String,
    pub subtitle: String,
    pub image_url: String,
    pub follow_uri: String,
    pub follow_text: String,
    pub following_text: String,
}

pub struct RustWatchFeedHashtagDto {
    pub id: String,
    pub title: String,
    pub navigation_uri: String,
    pub seed_item_uri: String,
}

pub struct RustWatchFeedEntityRowDto {
    pub title: String,
    pub subtitle: String,
    pub image_url: String,
    pub play_uri: String,
    pub accessibility_text: String,
}

pub struct RustWatchFeedItemDto {
    pub id: String,
    pub uri: String,
    pub visual: RustWatchFeedVisualDto,
    pub audio: Option<RustWatchFeedAudioDto>,
    pub creator: Option<RustWatchFeedCreatorDto>,
    pub hashtags: Vec<RustWatchFeedHashtagDto>,
    pub entity_row: Option<RustWatchFeedEntityRowDto>,
    pub texts: Vec<String>,
    pub track: Option<RustTrackDto>,
    pub can_share: bool,
    pub has_menu: bool,
    pub can_save: bool,
    pub has_progress_bar: bool,
}

pub struct RustWatchFeedPageDto {
    pub header_titles: Vec<String>,
    pub items: Vec<RustWatchFeedItemDto>,
    pub next_page_token: Option<Vec<u8>>,
    pub associated_feed_uris: Vec<String>,
    pub vertical_onboarding_text: String,
    pub associated_onboarding_text: String,
}

pub struct RustStorageResolveDto {
    pub result: i32,
    pub cdn_urls: Vec<String>,
    pub file_id: Vec<u8>,
}

pub struct RustExtendedMetadataEntryDto {
    pub uri: String,
    pub data: Vec<u8>,
}

pub struct RustApWelcomeDto {
    pub session_id: u64,
    pub canonical_username: String,
    pub reusable_auth_type: i32,
    pub reusable_auth: Vec<u8>,
}

pub struct RustHttpRawDto {
    pub status: u16,
    pub body: Vec<u8>,
}

pub struct RustLrclibCandidateDto {
    pub id: i64,
    pub track_name: String,
    pub artist_name: String,
    pub album_name: String,
    pub duration_sec: f64,
    pub instrumental: bool,
    pub plain_lyrics: String,
    pub synced_lyrics: String,
}

pub struct RustLrclibResponseDto {
    pub candidates: Vec<RustLrclibCandidateDto>,
    pub network_error: bool,
}

impl From<BackendImage> for RustImageDto {
    fn from(v: BackendImage) -> Self {
        Self {
            url: v.url,
            width: v.width,
            height: v.height,
        }
    }
}

impl From<BackendArtist> for RustArtistDto {
    fn from(v: BackendArtist) -> Self {
        Self {
            id: v.id,
            name: v.name,
            uri: v.uri,
            images: v.images.into_iter().map(Into::into).collect(),
            followers: v.followers,
        }
    }
}

impl From<BackendAlbum> for RustAlbumDto {
    fn from(v: BackendAlbum) -> Self {
        Self {
            id: v.id,
            name: v.name,
            uri: v.uri,
            images: v.images.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendTrack> for RustTrackDto {
    fn from(v: BackendTrack) -> Self {
        Self {
            id: v.id,
            name: v.name,
            uri: v.uri,
            artists: v.artists.into_iter().map(Into::into).collect(),
            album: v.album.map(Into::into),
            duration_ms: v.duration_ms,
            explicit: v.explicit,
            is_playable: v.is_playable,
            added_at_ms: v.added_at_ms,
        }
    }
}

impl From<BackendPlaylist> for RustPlaylistDto {
    fn from(v: BackendPlaylist) -> Self {
        Self {
            id: v.id,
            name: v.name,
            uri: v.uri,
            description: v.description,
            owner_name: v.owner_name,
            images: v.images.into_iter().map(Into::into).collect(),
            total_tracks: v.total_tracks,
            tracks: v.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendCollectionEntry> for RustCollectionEntryDto {
    fn from(v: BackendCollectionEntry) -> Self {
        Self {
            uri: v.uri,
            id: v.id,
            added_at_sec: v.added_at_sec,
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_session_configure(config: RustSessionConfig) {
    spotify_session::configure_session(SessionState {
        sp_dc: config.sp_dc,
        access_token: config.access_token,
        access_token_expiry_ms: config.access_token_expiry_ms,
        client_token: config.client_token,
        client_token_expiry_ms: config.client_token_expiry_ms,
        device_id: config.device_id,
        proxy: config.proxy,
        epoch: config.epoch,
    });
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_session_set_proxy(proxy: String) {
    spotify_session::set_proxy(proxy);
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_session_clear() {
    spotify_session::clear_session();
}

pub async fn rust_mint_web_token(sp_dc: String, proxy: String) -> Result<RustTokenResult, String> {
    http_client::runtime()
        .spawn(async move {
            let minted = spotify_session::mint_web_token(&sp_dc, &proxy).await?;
            Ok(RustTokenResult {
                token: minted.token,
                expiry_ms: minted.expiry_ms,
            })
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_ensure_web_access_token(force_refresh: bool) -> Result<RustTokenResult, String> {
    http_client::runtime()
        .spawn(async move {
            let minted = spotify_session::ensure_web_access_token(force_refresh).await?;
            Ok(RustTokenResult {
                token: minted.token,
                expiry_ms: minted.expiry_ms,
            })
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_ensure_client_token(force_refresh: bool) -> Result<RustTokenResult, String> {
    http_client::runtime()
        .spawn(async move {
            let granted = spotify_session::ensure_client_token(force_refresh).await?;
            Ok(RustTokenResult {
                token: granted.token,
                expiry_ms: granted.expiry_ms,
            })
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_playlist_full(
    spclient_base: String,
    playlist_id: String,
    decorate_hash: String,
    proxy: String,
) -> Result<Option<RustPlaylistDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let pl = spotify_backend::fetch_playlist_full(
                &spclient_base,
                &playlist_id,
                &decorate_hash,
            )
            .await?;
            Ok(pl.map(Into::into))
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_tracks_by_uris(
    uris: Vec<String>,
    decorate_hash: String,
    proxy: String,
) -> Result<Vec<RustTrackDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let tracks = spotify_backend::fetch_tracks_by_uris(uris, &decorate_hash).await?;
            Ok(tracks.into_iter().map(Into::into).collect())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_collection_entries(
    spclient_base: String,
    username: String,
    set_name: String,
    kind: String,
    max_pages: u32,
    page_size: i32,
    proxy: String,
) -> Result<Vec<RustCollectionEntryDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let entries = spotify_backend::fetch_collection_entries(
                &spclient_base,
                &username,
                &set_name,
                &kind,
                max_pages as usize,
                page_size,
            )
            .await?;
            Ok(entries.into_iter().map(Into::into).collect())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

impl From<BackendPlaylistSummary> for RustPlaylistSummaryDto {
    fn from(v: BackendPlaylistSummary) -> Self {
        Self {
            id: v.id,
            name: v.name,
            uri: v.uri,
            description: v.description,
            owner_name: v.owner_name,
            images: v.images.into_iter().map(Into::into).collect(),
            total_tracks: v.total_tracks,
        }
    }
}

impl From<BackendCreditPerson> for RustCreditPersonDto {
    fn from(v: BackendCreditPerson) -> Self {
        Self {
            name: v.name,
            roles: v.roles,
            artist_id: v.artist_id,
        }
    }
}

impl From<BackendCreditGroup> for RustCreditGroupDto {
    fn from(v: BackendCreditGroup) -> Self {
        Self {
            name: v.name,
            people: v.people.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendTrackCredits> for RustTrackCreditsDto {
    fn from(v: BackendTrackCredits) -> Self {
        Self {
            track_name: v.track_name,
            groups: v.groups.into_iter().map(Into::into).collect(),
            sources: v.sources,
        }
    }
}

impl From<BackendWatchFeedEntry> for RustWatchFeedEntryDto {
    fn from(v: BackendWatchFeedEntry) -> Self {
        Self {
            title: v.title,
            subtitle: v.subtitle,
            overline: v.overline,
            feed_uri: v.feed_uri,
            first_item_uri: v.first_item_uri,
            thumbnail_url: v.thumbnail_url,
            video_url: v.video_url,
            cover_url: v.cover_url,
            accessibility_text: v.accessibility_text,
        }
    }
}

impl From<BackendWatchFeedShelf> for RustWatchFeedShelfDto {
    fn from(v: BackendWatchFeedShelf) -> Self {
        Self {
            title: v.title,
            entries: v.entries.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendWatchFeedVisual> for RustWatchFeedVisualDto {
    fn from(v: BackendWatchFeedVisual) -> Self {
        Self {
            kind: v.kind,
            video_url: v.video_url,
            image_url: v.image_url,
            animation_url: v.animation_url,
            colors: v.colors,
        }
    }
}

impl From<BackendWatchFeedAudio> for RustWatchFeedAudioDto {
    fn from(v: BackendWatchFeedAudio) -> Self {
        Self {
            url: v.url,
            should_loop: v.should_loop,
            fade_in: v.fade_in,
        }
    }
}

impl From<BackendWatchFeedCreator> for RustWatchFeedCreatorDto {
    fn from(v: BackendWatchFeedCreator) -> Self {
        Self {
            uri: v.uri,
            name: v.name,
            subtitle: v.subtitle,
            image_url: v.image_url,
            follow_uri: v.follow_uri,
            follow_text: v.follow_text,
            following_text: v.following_text,
        }
    }
}

impl From<BackendWatchFeedHashtag> for RustWatchFeedHashtagDto {
    fn from(v: BackendWatchFeedHashtag) -> Self {
        Self {
            id: v.id,
            title: v.title,
            navigation_uri: v.navigation_uri,
            seed_item_uri: v.seed_item_uri,
        }
    }
}

impl From<BackendWatchFeedEntityRow> for RustWatchFeedEntityRowDto {
    fn from(v: BackendWatchFeedEntityRow) -> Self {
        Self {
            title: v.title,
            subtitle: v.subtitle,
            image_url: v.image_url,
            play_uri: v.play_uri,
            accessibility_text: v.accessibility_text,
        }
    }
}

impl From<BackendWatchFeedItem> for RustWatchFeedItemDto {
    fn from(v: BackendWatchFeedItem) -> Self {
        Self {
            id: v.id,
            uri: v.uri,
            visual: v.visual.into(),
            audio: v.audio.map(Into::into),
            creator: v.creator.map(Into::into),
            hashtags: v.hashtags.into_iter().map(Into::into).collect(),
            entity_row: v.entity_row.map(Into::into),
            texts: v.texts,
            track: v.track.map(Into::into),
            can_share: v.can_share,
            has_menu: v.has_menu,
            can_save: v.can_save,
            has_progress_bar: v.has_progress_bar,
        }
    }
}

impl From<BackendWatchFeedPage> for RustWatchFeedPageDto {
    fn from(v: BackendWatchFeedPage) -> Self {
        Self {
            header_titles: v.header_titles,
            items: v.items.into_iter().map(Into::into).collect(),
            next_page_token: v.next_page_token,
            associated_feed_uris: v.associated_feed_uris,
            vertical_onboarding_text: v.vertical_onboarding_text,
            associated_onboarding_text: v.associated_onboarding_text,
        }
    }
}

impl From<BackendStorageResolveResult> for RustStorageResolveDto {
    fn from(v: BackendStorageResolveResult) -> Self {
        Self {
            result: v.result,
            cdn_urls: v.cdn_urls,
            file_id: v.file_id,
        }
    }
}

impl From<BackendApWelcome> for RustApWelcomeDto {
    fn from(v: BackendApWelcome) -> Self {
        Self {
            session_id: v.session_id,
            canonical_username: v.canonical_username,
            reusable_auth_type: v.reusable_auth_type,
            reusable_auth: v.reusable_auth,
        }
    }
}

impl From<BackendLrclibCandidate> for RustLrclibCandidateDto {
    fn from(v: BackendLrclibCandidate) -> Self {
        Self {
            id: v.id,
            track_name: v.track_name,
            artist_name: v.artist_name,
            album_name: v.album_name,
            duration_sec: v.duration_sec,
            instrumental: v.instrumental,
            plain_lyrics: v.plain_lyrics,
            synced_lyrics: v.synced_lyrics,
        }
    }
}

impl From<BackendLrclibResponse> for RustLrclibResponseDto {
    fn from(v: BackendLrclibResponse) -> Self {
        Self {
            candidates: v.candidates.into_iter().map(Into::into).collect(),
            network_error: v.network_error,
        }
    }
}

/// 通用 Pathfinder 查询（自动鉴权、401 刷新、429 退避与代理路由），返回 `data` 字段 JSON 串。
pub async fn rust_pathfinder_query(
    operation: String,
    hash: String,
    variables_json: String,
    proxy: String,
) -> Result<String, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let vars: serde_json::Value = serde_json::from_str(&variables_json)
                .map_err(|e| format!("bad_vars:{e}"))?;
            let data = spotify_session::pathfinder_query(&operation, &hash, vars).await?;
            serde_json::to_string(&data).map_err(|e| format!("encode:{e}"))
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

/// 流式/懒加载歌单：先返回首 100 首，后续分页在后台增量推送给 `sink`。
pub fn rust_fetch_playlist_stream(
    spclient_base: String,
    playlist_id: String,
    decorate_hash: String,
    proxy: String,
    sink: StreamSink<RustPlaylistDto>,
) {
    http_client::runtime().spawn(spotify_session::with_request_proxy(proxy, async move {
        let res = spotify_backend::fetch_playlist_stream(
            &spclient_base,
            &playlist_id,
            &decorate_hash,
            |snap| {
                let _ = sink.add(snap.into());
            },
        )
        .await;
        if let Err(err) = res {
            let _ = sink.add_error(err);
        }
    }));
}

pub async fn rust_fetch_rootlist(
    spclient_base: String,
    username: String,
    proxy: String,
) -> Result<Vec<RustPlaylistSummaryDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let list = spotify_backend::fetch_rootlist(&spclient_base, &username).await?;
            Ok(list.into_iter().map(Into::into).collect())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_track_credits(
    hash: String,
    track_uri: String,
    proxy: String,
) -> Result<Option<RustTrackCreditsDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let credits = spotify_backend::fetch_track_credits(&hash, &track_uri).await?;
            Ok(credits.map(Into::into))
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub fn rust_audio_cache_size_bytes(dir_path: String) -> u64 {
    audio_cache::cache_size_bytes(&dir_path)
}

pub fn rust_audio_cache_clear(dir_path: String, protected_paths: Vec<String>) -> u64 {
    audio_cache::clear_cache(&dir_path, &protected_paths)
}

pub fn rust_audio_cache_trim(
    dir_path: String,
    max_bytes: u64,
    protected_paths: Vec<String>,
) -> u64 {
    audio_cache::trim_cache(&dir_path, max_bytes, &protected_paths)
}

pub async fn rust_fetch_watch_feed_proto(
    spclient_base: String,
    feed_id: String,
    entity_id: Option<String>,
    parameters: Vec<(String, String)>,
    page_token: Option<Vec<u8>>,
    proxy: String,
) -> Result<RustWatchFeedPageDto, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let page = watchfeed_backend::fetch_watch_feed_proto(
                &spclient_base,
                &feed_id,
                entity_id.as_deref(),
                &parameters,
                page_token.as_deref(),
            )
            .await?;
            Ok(page.into())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_watch_feed_browse_shelf(
    spclient_base: String,
    timezone: Option<String>,
    proxy: String,
) -> Result<Option<RustWatchFeedShelfDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let shelf = watchfeed_backend::fetch_watch_feed_browse_shelf(
                &spclient_base,
                timezone.as_deref(),
            )
            .await?;
            Ok(shelf.map(Into::into))
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_watch_feed_seed_shelf(
    spclient_base: String,
    track_uri: String,
    creator_uri: String,
    context_uri: String,
    proxy: String,
) -> Result<Option<RustWatchFeedShelfDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let shelf = watchfeed_backend::fetch_watch_feed_seed_shelf(
                &spclient_base,
                &track_uri,
                &creator_uri,
                &context_uri,
            )
            .await?;
            Ok(shelf.map(Into::into))
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_resolve_audio_storage(
    spclient_base: String,
    file_id_hex: String,
    proxy: String,
) -> Result<RustStorageResolveDto, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let res = ap_client::resolve_audio_storage(&spclient_base, &file_id_hex).await?;
            Ok(res.into())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_extended_metadata(
    spclient_base: String,
    entity_uris: Vec<String>,
    kind: i32,
    proxy: String,
) -> Result<Vec<RustExtendedMetadataEntryDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let items =
                ap_client::fetch_extended_metadata(&spclient_base, entity_uris, kind).await?;
            Ok(items
                .into_iter()
                .map(|(uri, data)| RustExtendedMetadataEntryDto { uri, data })
                .collect())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_ap_connect_and_login(
    host: Option<String>,
    port: Option<u16>,
    proxy: String,
    username: String,
    auth_type: i32,
    auth_data: Vec<u8>,
    device_id: String,
) -> Result<RustApWelcomeDto, String> {
    http_client::runtime()
        .spawn(async move {
            let w = ap_client::ap_connect_and_login(
                host,
                port,
                &proxy,
                &username,
                auth_type,
                &auth_data,
                &device_id,
            )
            .await?;
            Ok(w.into())
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_ap_request_audio_key(
    session_id: u64,
    file_id: Vec<u8>,
    track_gid: Vec<u8>,
) -> Result<Vec<u8>, String> {
    http_client::runtime()
        .spawn(async move { ap_client::ap_request_audio_key(session_id, &file_id, &track_gid).await })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_ap_mercury_get(session_id: u64, uri: String) -> Result<Vec<u8>, String> {
    http_client::runtime()
        .spawn(async move { ap_client::ap_mercury_get(session_id, &uri).await })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub fn rust_ap_close(session_id: u64) {
    ap_client::ap_close(session_id);
}

pub async fn rust_connect_state_request(
    spclient_host: String,
    method: String,
    path: String,
    connection_id: String,
    body_json: Option<String>,
    proxy: String,
) -> Result<RustHttpRawDto, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let (status, body) = connect_backend::connect_state_request(
                &spclient_host,
                &method,
                &path,
                &connection_id,
                body_json,
            )
            .await?;
            Ok(RustHttpRawDto { status, body })
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_lrclib_get(
    track: String,
    artist: String,
    album: String,
    duration_sec: i32,
    proxy: String,
) -> Result<RustLrclibResponseDto, String> {
    http_client::runtime()
        .spawn(async move {
            Ok(lyrics_backend::lrclib_get(&track, &artist, &album, duration_sec, &proxy).await.into())
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_lrclib_search(
    track: String,
    artist: String,
    q: String,
    proxy: String,
) -> Result<RustLrclibResponseDto, String> {
    http_client::runtime()
        .spawn(async move {
            Ok(lyrics_backend::lrclib_search(&track, &artist, &q, &proxy).await.into())
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_lyrics_http_request(
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
    proxy: String,
) -> Result<RustHttpRawDto, String> {
    http_client::runtime()
        .spawn(async move {
            let (status, body) =
                lyrics_backend::lyrics_http_request(&method, &url, headers, body, &proxy).await?;
            Ok(RustHttpRawDto { status, body })
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub struct RustPlaybackFileDto {
    pub file_id_hex: String,
    pub format: i32,
    pub bitrate: i32,
    pub format_key: String,
    pub encoding_id: Option<String>,
}

pub struct RustTrackPlaybackMediaDto {
    pub name: String,
    pub duration_ms: i32,
    pub mp4_files: Vec<RustPlaybackFileDto>,
    pub external_urls: Vec<String>,
}

pub struct RustDrmRelayResultDto {
    pub host: String,
    pub status: u16,
    pub body: Vec<u8>,
}

pub struct RustProtoAudioFileDto {
    pub file_id: Vec<u8>,
    pub format: i32,
}

pub struct RustProtoTrackMetadataDto {
    pub gid: Vec<u8>,
    pub name: String,
    pub album_name: String,
    pub artist_names: Vec<String>,
    pub duration_ms: i32,
    pub explicit: bool,
    pub files: Vec<RustProtoAudioFileDto>,
    pub alternatives: Vec<RustProtoTrackMetadataDto>,
}

pub struct RustProtoEpisodeMetadataDto {
    pub gid: Vec<u8>,
    pub name: String,
    pub show_name: String,
    pub duration_ms: i32,
    pub description: String,
    pub files: Vec<RustProtoAudioFileDto>,
}

pub struct RustPlayplayKeyDto {
    pub r1: Vec<u8>,
    pub r2: Vec<u8>,
}

pub struct RustSpotifyLyricLineDto {
    pub start_time_ms: i32,
    pub words: String,
    pub translation: String,
    pub syllables: Vec<String>,
}

pub struct RustSpotifyLyricAlternativeDto {
    pub language: String,
    pub lines: Vec<String>,
}

pub struct RustSpotifyLyricsDto {
    pub sync_type: String,
    pub language: String,
    pub lines: Vec<RustSpotifyLyricLineDto>,
    pub alternatives: Vec<RustSpotifyLyricAlternativeDto>,
}

pub struct RustPodcastEpisodeDto {
    pub id: String,
    pub uri: String,
    pub name: String,
    pub description: String,
    pub duration_ms: i32,
    pub release_date: String,
    pub images: Vec<RustImageDto>,
    pub show_uri: String,
    pub show_name: String,
    pub preview_url: String,
    pub resume_ms: i32,
    pub played: bool,
}

pub struct RustPodcastShowDto {
    pub id: String,
    pub uri: String,
    pub name: String,
    pub publisher: String,
    pub description: String,
    pub images: Vec<RustImageDto>,
    pub episodes: Vec<RustPodcastEpisodeDto>,
}

pub struct RustCanvasMediaDto {
    pub url: String,
    pub is_video: bool,
    pub bytes: Vec<u8>,
}

impl From<BackendPlaybackFile> for RustPlaybackFileDto {
    fn from(v: BackendPlaybackFile) -> Self {
        Self {
            file_id_hex: v.file_id_hex,
            format: v.format,
            bitrate: v.bitrate,
            format_key: v.format_key,
            encoding_id: v.encoding_id,
        }
    }
}

impl From<BackendTrackPlaybackMedia> for RustTrackPlaybackMediaDto {
    fn from(v: BackendTrackPlaybackMedia) -> Self {
        Self {
            name: v.name,
            duration_ms: v.duration_ms,
            mp4_files: v.mp4_files.into_iter().map(Into::into).collect(),
            external_urls: v.external_urls,
        }
    }
}

impl From<BackendDrmRelayResult> for RustDrmRelayResultDto {
    fn from(v: BackendDrmRelayResult) -> Self {
        Self {
            host: v.host,
            status: v.status,
            body: v.body,
        }
    }
}

impl From<BackendProtoAudioFile> for RustProtoAudioFileDto {
    fn from(v: BackendProtoAudioFile) -> Self {
        Self {
            file_id: v.file_id,
            format: v.format,
        }
    }
}

impl From<BackendProtoTrackMetadata> for RustProtoTrackMetadataDto {
    fn from(v: BackendProtoTrackMetadata) -> Self {
        Self {
            gid: v.gid,
            name: v.name,
            album_name: v.album_name,
            artist_names: v.artist_names,
            duration_ms: v.duration_ms,
            explicit: v.explicit,
            files: v.files.into_iter().map(Into::into).collect(),
            alternatives: v.alternatives.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendProtoEpisodeMetadata> for RustProtoEpisodeMetadataDto {
    fn from(v: BackendProtoEpisodeMetadata) -> Self {
        Self {
            gid: v.gid,
            name: v.name,
            show_name: v.show_name,
            duration_ms: v.duration_ms,
            description: v.description,
            files: v.files.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendPlayplayKey> for RustPlayplayKeyDto {
    fn from(v: BackendPlayplayKey) -> Self {
        Self { r1: v.r1, r2: v.r2 }
    }
}

impl From<BackendSpotifyLyricLine> for RustSpotifyLyricLineDto {
    fn from(v: BackendSpotifyLyricLine) -> Self {
        Self {
            start_time_ms: v.start_time_ms,
            words: v.words,
            translation: v.translation,
            syllables: v.syllables,
        }
    }
}

impl From<BackendSpotifyLyricAlternative> for RustSpotifyLyricAlternativeDto {
    fn from(v: BackendSpotifyLyricAlternative) -> Self {
        Self {
            language: v.language,
            lines: v.lines,
        }
    }
}

impl From<BackendSpotifyLyrics> for RustSpotifyLyricsDto {
    fn from(v: BackendSpotifyLyrics) -> Self {
        Self {
            sync_type: v.sync_type,
            language: v.language,
            lines: v.lines.into_iter().map(Into::into).collect(),
            alternatives: v.alternatives.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendPodcastEpisode> for RustPodcastEpisodeDto {
    fn from(v: BackendPodcastEpisode) -> Self {
        Self {
            id: v.id,
            uri: v.uri,
            name: v.name,
            description: v.description,
            duration_ms: v.duration_ms,
            release_date: v.release_date,
            images: v.images.into_iter().map(Into::into).collect(),
            show_uri: v.show_uri,
            show_name: v.show_name,
            preview_url: v.preview_url,
            resume_ms: v.resume_ms,
            played: v.played,
        }
    }
}

impl From<BackendPodcastShow> for RustPodcastShowDto {
    fn from(v: BackendPodcastShow) -> Self {
        Self {
            id: v.id,
            uri: v.uri,
            name: v.name,
            publisher: v.publisher,
            description: v.description,
            images: v.images.into_iter().map(Into::into).collect(),
            episodes: v.episodes.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<BackendCanvasMedia> for RustCanvasMediaDto {
    fn from(v: BackendCanvasMedia) -> Self {
        Self {
            url: v.url,
            is_video: v.is_video,
            bytes: v.bytes,
        }
    }
}

pub async fn rust_fetch_track_playback_media(
    spclient_base: String,
    track_id_or_uri: String,
    proxy: String,
) -> Result<RustTrackPlaybackMediaDto, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let media =
                drm_backend::fetch_track_playback_media(&spclient_base, &track_id_or_uri).await?;
            Ok(media.into())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_parse_track_playback_media_json(
    body: Vec<u8>,
    track_id_or_uri: String,
) -> Result<RustTrackPlaybackMediaDto, String> {
    drm_backend::parse_track_playback_media_json(&body, &track_id_or_uri).map(Into::into)
}

pub async fn rust_fetch_hls_manifest(
    spclient_base: String,
    file_id_hex: String,
    proxy: String,
) -> Result<String, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            drm_backend::fetch_hls_manifest(&spclient_base, &file_id_hex).await
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_localize_hls_manifest(
    m3u8: String,
    origin: String,
    widevine_key_format: bool,
    fair_play: bool,
    file_id_hex: Option<String>,
) -> Result<String, String> {
    drm_backend::localize_hls_manifest(
        &m3u8,
        &origin,
        widevine_key_format,
        fair_play,
        file_id_hex.as_deref(),
    )
}

pub async fn rust_relay_drm_request(
    hosts: Vec<String>,
    method: String,
    path_and_query: String,
    bearer_token: Option<String>,
    client_token: String,
    request_body: Option<Vec<u8>>,
    timeout_ms: u64,
    proxy: String,
) -> Result<RustDrmRelayResultDto, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let res = drm_backend::relay_drm_request(
                hosts,
                &method,
                &path_and_query,
                bearer_token,
                &client_token,
                request_body,
                timeout_ms,
            )
            .await?;
            Ok(res.into())
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_parse_track_metadata_proto(data: Vec<u8>) -> RustProtoTrackMetadataDto {
    drm_backend::parse_track_metadata_proto(&data).into()
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_parse_episode_metadata_proto(data: Vec<u8>) -> RustProtoEpisodeMetadataDto {
    drm_backend::parse_episode_metadata_proto(&data).into()
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_encode_playplay_key_request(now_sec: i64) -> Vec<u8> {
    drm_backend::encode_playplay_key_request(now_sec)
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_parse_playplay_key_proto(data: Vec<u8>) -> Result<RustPlayplayKeyDto, String> {
    drm_backend::parse_playplay_key_proto(&data).map(Into::into)
}

pub async fn rust_fetch_color_lyrics(
    spclient_base: String,
    track_id: String,
    proxy: String,
) -> Result<Option<RustSpotifyLyricsDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let lyrics = lyrics_backend::fetch_color_lyrics(&spclient_base, &track_id).await?;
            Ok(lyrics.map(Into::into))
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_parse_color_lyrics_json(body: Vec<u8>) -> Option<RustSpotifyLyricsDto> {
    lyrics_backend::parse_color_lyrics_json(&body).map(Into::into)
}

pub async fn rust_fetch_podcast_show(
    show_id: String,
    proxy: String,
) -> Result<RustPodcastShowDto, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            catalog_backend::fetch_podcast_show(&show_id).await.map(Into::into)
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_parse_podcast_show_html(
    show_id: String,
    html: String,
) -> Result<RustPodcastShowDto, String> {
    catalog_backend::parse_podcast_show_html(&show_id, &html).map(Into::into)
}

pub async fn rust_fetch_podcast_episode(
    episode_id: String,
    proxy: String,
) -> Result<RustPodcastEpisodeDto, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            catalog_backend::fetch_podcast_episode(&episode_id)
                .await
                .map(Into::into)
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

#[flutter_rust_bridge::frb(sync)]
pub fn rust_parse_podcast_episode_html(
    episode_id: String,
    html: String,
) -> Result<RustPodcastEpisodeDto, String> {
    catalog_backend::parse_podcast_episode_html(&episode_id, &html).map(Into::into)
}

pub async fn rust_fetch_canvas(
    hash: String,
    track_uri: String,
    proxy: String,
) -> Result<Option<RustCanvasMediaDto>, String> {
    http_client::runtime()
        .spawn(spotify_session::with_request_proxy(proxy, async move {
            let media = catalog_backend::fetch_canvas(&hash, &track_uri).await?;
            Ok(media.map(Into::into))
        }))
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_track_playback_request(
    spclient_host: String,
    method: String,
    path: String,
    bearer_token: String,
    client_token: String,
    app_version: String,
    proxy: String,
    body_json: Option<String>,
) -> Result<RustHttpRawDto, String> {
    http_client::runtime()
        .spawn(async move {
            let (status, body) = connect_backend::track_playback_request(
                &spclient_host,
                &method,
                &path,
                &bearer_token,
                &client_token,
                &app_version,
                &proxy,
                body_json,
            )
            .await?;
            Ok(RustHttpRawDto { status, body })
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_write_backup_file_atomic(
    file_path: String,
    content: String,
) -> Result<(), String> {
    http_client::runtime()
        .spawn_blocking(move || catalog_backend::write_backup_file_atomic(&file_path, &content))
        .await
        .map_err(|e| format!("join:{e}"))?
}
