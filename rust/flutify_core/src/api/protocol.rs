use crate::aes::{AesCipher, AesCtr};
use crate::audio_normalization::AudioNormalization;
use crate::file_hash;
use crate::http_client;
use crate::spotify_id::SpotifyId;
use crate::spotify_link;
use crate::web_totp;

/// 解析出的 Spotify 分享链接 / URI 目标。
pub struct SpotifyLinkTarget {
    pub kind: String,
    pub id: String,
    pub uri: String,
}

/// 解析 `spotify:track:xxx`（及 `album` / `playlist` / `artist`）或 `open.spotify.com` 分享链接。
#[flutter_rust_bridge::frb(sync)]
pub fn parse_spotify_link(input: String) -> Option<SpotifyLinkTarget> {
    let link = spotify_link::parse_spotify_link(&input)?;
    Some(SpotifyLinkTarget {
        kind: link.kind,
        id: link.id,
        uri: link.uri,
    })
}

/// 从 22 位 base62 ID 解析出 16 字节原始 GID。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_from_base62(src: String) -> Result<Vec<u8>, String> {
    Ok(SpotifyId::from_base62(&src)?.raw.to_vec())
}

/// 从 32 位十六进制 GID 解析出 16 字节原始 GID。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_from_base16(src: String) -> Result<Vec<u8>, String> {
    Ok(SpotifyId::from_base16(&src)?.raw.to_vec())
}

/// 16 字节原始 GID 转 22 位 base62。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_to_base62(raw: Vec<u8>) -> Result<String, String> {
    Ok(SpotifyId::from_raw(&raw)?.to_base62())
}

/// 16 字节原始 GID 转 32 位小写十六进制。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_to_base16(raw: Vec<u8>) -> Result<String, String> {
    Ok(SpotifyId::from_raw(&raw)?.to_base16())
}

/// 音频响度均衡数据。
pub struct NormalizationInfo {
    pub track_gain_db: f64,
    pub track_peak: f64,
    pub volume_factor: f64,
}

/// 解析 16 字节 Spotify 音频响度头；不合法时返回 None。
#[flutter_rust_bridge::frb(sync)]
pub fn parse_audio_normalization(bytes: Vec<u8>) -> Option<NormalizationInfo> {
    let norm = AudioNormalization::parse(&bytes)?;
    Some(NormalizationInfo {
        track_gain_db: norm.track_gain_db,
        track_peak: norm.track_peak,
        volume_factor: norm.volume_factor(),
    })
}

/// 按增益与峰值计算播放器音量倍率（[0.0, 1.0]）。
#[flutter_rust_bridge::frb(sync)]
pub fn normalization_volume_factor(track_gain_db: f64, track_peak: f64) -> f64 {
    AudioNormalization::compute_volume_factor(track_gain_db, track_peak)
}

/// AES 单块（16 字节）加密。
#[flutter_rust_bridge::frb(sync)]
pub fn aes_encrypt_block(key: Vec<u8>, block: Vec<u8>) -> Result<Vec<u8>, String> {
    Ok(AesCipher::new(&key)?.encrypt_block(&block)?.to_vec())
}

/// AES-128-CTR 从指定字节偏移起加/解密一段数据。
#[flutter_rust_bridge::frb(sync)]
pub fn aes_ctr_process_at_offset(
    key: Vec<u8>,
    iv: Vec<u8>,
    offset: i64,
    mut data: Vec<u8>,
) -> Result<Vec<u8>, String> {
    if offset < 0 {
        return Err("offset must be >= 0".to_string());
    }
    let mut ctr = AesCtr::at_offset(&key, &iv, offset as usize)?;
    ctr.process(&mut data);
    Ok(data)
}

/// 使用内置 V61 密钥直接生成指定毫秒时间戳的 6 位 Web 播放器 TOTP。
#[flutter_rust_bridge::frb(sync)]
pub fn generate_web_player_totp_v61(timestamp_ms: i64) -> String {
    web_totp::web_player_totp_v61(timestamp_ms)
}

/// 文件 SHA-256（小写十六进制）。大文件耗时，在后台线程执行（非 sync），不阻塞 Dart。
pub fn sha256_file(path: String) -> Result<String, String> {
    file_hash::sha256_file(&path)
}

/// HTTP 头（名称 / 值）。
pub struct HttpHeaderEntry {
    pub name: String,
    pub value: String,
}

/// HTTP 响应（完整响应体）。
pub struct HttpResponseData {
    pub status: u16,
    pub headers: Vec<HttpHeaderEntry>,
    pub body: Vec<u8>,
    /// 实际协商到的协议（`HTTP/2.0` / `HTTP/1.1`）。
    pub version: String,
}

/// 经 Rust HTTP/2 客户端发请求。[proxy] 为空表示直连，否则为 Dart 侧选出的代理地址
/// （`http://[user:pass@]host:port` / `socks5h://…`）；网关由 Dart 侧处理，不走这里。
/// 错误以 `connect:`（未发出，可安全改走其他通道）/ `timeout:` / `request:` 开头。
pub async fn http_send(
    proxy: String,
    method: String,
    url: String,
    headers: Vec<HttpHeaderEntry>,
    body: Vec<u8>,
    timeout_ms: u64,
) -> Result<HttpResponseData, String> {
    let response = http_client::send(
        proxy,
        method,
        url,
        headers
            .into_iter()
            .map(|h| http_client::HttpHeader { name: h.name, value: h.value })
            .collect(),
        body,
        timeout_ms,
    )
    .await?;
    Ok(HttpResponseData {
        status: response.status,
        headers: response
            .headers
            .into_iter()
            .map(|h| HttpHeaderEntry { name: h.name, value: h.value })
            .collect(),
        body: response.body,
        version: response.version,
    })
}
