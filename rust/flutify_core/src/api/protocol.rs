use crate::aes::{AesCipher, AesCtr};
use crate::ap_crypto;
use crate::audio_normalization::AudioNormalization;
use crate::file_hash;
use crate::hashcash;
use crate::http_client;
use crate::shannon;
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

/// 从 `spotify:track:xxx` / `track:xxx` / `xxx` 提取 16 字节原始 GID。
#[flutter_rust_bridge::frb(sync)]
pub fn spotify_id_from_uri(uri: String) -> Result<Vec<u8>, String> {
    Ok(SpotifyId::from_uri(&uri)?.raw.to_vec())
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

/// 还原混淆的 Web 播放器 TOTP secret。
#[flutter_rust_bridge::frb(sync)]
pub fn deobfuscate_totp_secret(obfuscated: String) -> Vec<u8> {
    web_totp::deobfuscate_secret(&obfuscated)
}

/// 生成标准 HMAC-SHA1 TOTP 口令。
#[flutter_rust_bridge::frb(sync)]
pub fn generate_totp(secret: Vec<u8>, timestamp_ms: i64, period: i64, digits: u32) -> String {
    web_totp::totp(&secret, timestamp_ms, period, digits)
}

/// 使用内置 V61 密钥直接生成指定毫秒时间戳的 6 位 Web 播放器 TOTP。
#[flutter_rust_bridge::frb(sync)]
pub fn generate_web_player_totp_v61(timestamp_ms: i64) -> String {
    web_totp::web_player_totp_v61(timestamp_ms)
}

/// 求解 Spotify Hashcash SHA-1 工作量证明，返回 16 字节 suffix。
#[flutter_rust_bridge::frb(sync)]
pub fn solve_hashcash(
    ctx: Vec<u8>,
    prefix: Vec<u8>,
    length: u32,
    timeout_ms: i64,
) -> Result<Vec<u8>, String> {
    let ms = timeout_ms.max(1) as u64;
    Ok(hashcash::solve_hashcash(&ctx, &prefix, length, ms)?.to_vec())
}

/// 使用 Shannon 流密码编码单帧 AP 数据包。
#[flutter_rust_bridge::frb(sync)]
pub fn shannon_encode_packet(key: Vec<u8>, nonce: u32, cmd: u8, payload: Vec<u8>) -> Vec<u8> {
    shannon::encode_ap_packet(&key, nonce, cmd, &payload)
}

/// 解密 AP 包的 3 字节头（`cmd + len(BE)`），用来得知包体长度。
#[flutter_rust_bridge::frb(sync)]
pub fn shannon_decrypt_header(key: Vec<u8>, nonce: u32, header: Vec<u8>) -> Result<Vec<u8>, String> {
    shannon::decrypt_ap_header(&key, nonce, &header)
}

/// 解密并校验完整 AP 包，返回包体明文；MAC 不符返回错误。
#[flutter_rust_bridge::frb(sync)]
pub fn shannon_decode_packet(
    key: Vec<u8>,
    nonce: u32,
    header: Vec<u8>,
    body: Vec<u8>,
    mac: Vec<u8>,
) -> Result<Vec<u8>, String> {
    shannon::decode_ap_packet(&key, nonce, &header, &body, &mac)
}

/// AP 握手 DH：95 字节小端私钥 → 96 字节大端公钥。
#[flutter_rust_bridge::frb(sync)]
pub fn ap_dh_public_key(private_le: Vec<u8>) -> Result<Vec<u8>, String> {
    ap_crypto::dh_public_key(&private_le)
}

/// AP 握手 DH：共享密钥（最小大端字节）。
#[flutter_rust_bridge::frb(sync)]
pub fn ap_dh_shared_secret(private_le: Vec<u8>, remote_be: Vec<u8>) -> Vec<u8> {
    ap_crypto::dh_shared_secret(&private_le, &remote_be)
}

/// AP 握手推导出的 challenge 与收发密钥。
pub struct ApHandshakeKeys {
    pub challenge: Vec<u8>,
    pub send_key: Vec<u8>,
    pub recv_key: Vec<u8>,
}

/// 由共享密钥与握手报文推导 challenge / send_key / recv_key。
#[flutter_rust_bridge::frb(sync)]
pub fn ap_compute_keys(shared_secret: Vec<u8>, handshake_packets: Vec<u8>) -> ApHandshakeKeys {
    let keys = ap_crypto::compute_keys(&shared_secret, &handshake_packets);
    ApHandshakeKeys {
        challenge: keys.challenge,
        send_key: keys.send_key,
        recv_key: keys.recv_key,
    }
}

/// 服务端 DH 公钥签名验证（RSA PKCS#1 v1.5 + SHA-1，e = 65537）。
#[flutter_rust_bridge::frb(sync)]
pub fn ap_rsa_verify_pkcs1_sha1(modulus: Vec<u8>, signature: Vec<u8>, message: Vec<u8>) -> bool {
    ap_crypto::rsa_verify_pkcs1_sha1(&modulus, &signature, &message)
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

/// 经 Rust HTTP/2 客户端发请求（仅直连；代理 / 网关由 Dart 侧判断后不走这里）。
/// 错误以 `connect:`（未发出，可安全改走其他通道）/ `timeout:` / `request:` 开头。
pub async fn http_send(
    method: String,
    url: String,
    headers: Vec<HttpHeaderEntry>,
    body: Vec<u8>,
    timeout_ms: u64,
) -> Result<HttpResponseData, String> {
    let response = http_client::send(
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
