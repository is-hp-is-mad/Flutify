mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
// Flutify 的 Rust 核心。
//
// 包含歌词解析、文种识别、OpenCC 简繁词组消歧转换、双语歌词拆分、歌手/标题匹配、
// Spotify ID 与分享链接解析、音频响度均衡、AES/CTR、Shannon 与 AP 包编解码、AP 握手（DH / 密钥推导 /
// RSA 验签）、Hashcash、Web TOTP、大文件 SHA-256 等后端模块。

pub mod aes;
pub mod ap_crypto;
pub mod api;
pub mod artist_match;
pub mod audio_normalization;
pub mod downloads;
pub mod file_hash;
pub mod hashcash;
pub mod http_client;
pub mod lrc;
pub mod lyric_script;
pub mod lyrics_title;
pub mod shannon;
pub mod spotify_id;
pub mod spotify_link;
#[cfg(test)]
mod test_vectors;
pub mod translation_markers;
pub mod translation_merge;
pub mod web_totp;
pub mod ws;
pub mod zh_script;
