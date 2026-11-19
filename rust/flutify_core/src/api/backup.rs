//! 多账号歌单备份的 Dart 接口：用备份账号自己的会话拉取唯一识别符、已点赞歌曲与收藏歌单（见 `crate::backup_backend`）。
//! 序列化与落盘仍由 Dart 完成（`BackupAccount.toJson` + [`super::backend::rust_write_backup_file_atomic`]）。

use crate::api::backend::{RustPlaylistDto, RustTrackDto};
use crate::backup_backend::{self, BackupFetchInput};
use crate::http_client;

/// 拉取请求：备份账号的会话凭据、已知资料与接口参数。
pub struct RustBackupFetchRequest {
    pub sp_dc: String,
    pub access_token: String,
    pub client_token: String,
    pub user_id: String,
    pub email: String,
    pub display_name: String,
    pub avatar_url: String,
    pub spclient_base: String,
    pub web_api_base: String,
    pub profile_attributes_hash: String,
    pub decorate_hash: String,
    pub library_tracks_hash: String,
    /// 主会话（本机登录账号）可用时，用它补全曲目详情、在备份账号读不到时拉取歌单。
    pub use_main_session: bool,
    pub proxy: String,
}

pub struct RustBackupSnapshotDto {
    pub id: String,
    pub email: String,
    pub display_name: String,
    pub avatar_url: String,
    pub liked_tracks: Vec<RustTrackDto>,
    pub playlists: Vec<RustPlaylistDto>,
}

/// 用备份账号会话拉取快照。错误：`backup:missing credentials`、`backup:token:…`（令牌换取失败）、
/// `backup:no_user_id`（读不到唯一识别符）。
pub async fn rust_backup_fetch_snapshot(
    request: RustBackupFetchRequest,
) -> Result<RustBackupSnapshotDto, String> {
    let input = BackupFetchInput {
        sp_dc: request.sp_dc,
        access_token: request.access_token,
        client_token: request.client_token,
        user_id: request.user_id,
        email: request.email,
        display_name: request.display_name,
        avatar_url: request.avatar_url,
        spclient_base: request.spclient_base,
        web_api_base: request.web_api_base,
        profile_attributes_hash: request.profile_attributes_hash,
        decorate_hash: request.decorate_hash,
        library_tracks_hash: request.library_tracks_hash,
        use_main_session: request.use_main_session,
        proxy: request.proxy,
    };
    let snapshot = http_client::runtime()
        .spawn(backup_backend::fetch_snapshot(input))
        .await
        .map_err(|e| format!("join:{e}"))??;
    Ok(RustBackupSnapshotDto {
        id: snapshot.id,
        email: snapshot.email,
        display_name: snapshot.display_name,
        avatar_url: snapshot.avatar_url,
        liked_tracks: snapshot.liked_tracks.into_iter().map(Into::into).collect(),
        playlists: snapshot.playlists.into_iter().map(Into::into).collect(),
    })
}
