//! Rust 后端会话、令牌刷新与高并发媒体库接口（通过 flutter_rust_bridge 暴露给 Dart）。

use crate::http_client;
use crate::spotify_backend::{
    self, BackendAlbum, BackendArtist, BackendCollectionEntry, BackendImage, BackendPlaylist,
    BackendTrack,
};
use crate::spotify_session::{self, SessionState};

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
) -> Result<Option<RustPlaylistDto>, String> {
    http_client::runtime()
        .spawn(async move {
            let pl = spotify_backend::fetch_playlist_full(
                &spclient_base,
                &playlist_id,
                &decorate_hash,
            )
            .await?;
            Ok(pl.map(Into::into))
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}

pub async fn rust_fetch_tracks_by_uris(
    uris: Vec<String>,
    decorate_hash: String,
) -> Result<Vec<RustTrackDto>, String> {
    http_client::runtime()
        .spawn(async move {
            let tracks = spotify_backend::fetch_tracks_by_uris(uris, &decorate_hash).await?;
            Ok(tracks.into_iter().map(Into::into).collect())
        })
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
) -> Result<Vec<RustCollectionEntryDto>, String> {
    http_client::runtime()
        .spawn(async move {
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
        })
        .await
        .map_err(|e| format!("join:{e}"))?
}
