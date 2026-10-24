//! Spotify ID（16 字节 GID）与 base62 / base16 / URI 的互转。
//!
//! 与 librespot `spotify_id.rs` 及 `lib/services/protocol/spotify_id.dart` 一致：
//! base62 为 22 位定长、大端 u128 语义。

pub const RAW_SIZE: usize = 16;
pub const BASE62_SIZE: usize = 22;
pub const BASE16_SIZE: usize = 32;

const DIGITS: &[u8; 62] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const HEX_DIGITS: &[u8; 16] = b"0123456789abcdef";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpotifyId {
    pub raw: [u8; RAW_SIZE],
}

impl SpotifyId {
    /// 从 22 位 base62 ID 解析（`spotify:track:xxxx` 中的 xxxx）。
    pub fn from_base62(src: &str) -> Result<Self, String> {
        if src.len() != BASE62_SIZE {
            return Err(format!("base62 id must be {BASE62_SIZE} chars"));
        }
        let mut value: u128 = 0;
        for b in src.bytes() {
            let p: u128 = match b {
                b'0'..=b'9' => (b - b'0') as u128,
                b'a'..=b'z' => (b - b'a' + 10) as u128,
                b'A'..=b'Z' => (b - b'A' + 36) as u128,
                _ => return Err("invalid base62 char".to_string()),
            };
            value = value
                .checked_mul(62)
                .and_then(|v| v.checked_add(p))
                .ok_or_else(|| "base62 id overflow".to_string())?;
        }
        Ok(Self { raw: value.to_be_bytes() })
    }

    /// 从 32 位十六进制 GID 解析。
    pub fn from_base16(src: &str) -> Result<Self, String> {
        if src.len() != BASE16_SIZE {
            return Err(format!("base16 id must be {BASE16_SIZE} chars"));
        }
        let bytes = src.as_bytes();
        let mut raw = [0u8; RAW_SIZE];
        for (i, slot) in raw.iter_mut().enumerate() {
            let hi = hex_val(bytes[i * 2]).ok_or_else(|| "invalid hex char".to_string())?;
            let lo = hex_val(bytes[i * 2 + 1]).ok_or_else(|| "invalid hex char".to_string())?;
            *slot = (hi << 4) | lo;
        }
        Ok(Self { raw })
    }

    /// 从原始 16 字节解析。
    pub fn from_raw(raw: &[u8]) -> Result<Self, String> {
        let arr: [u8; RAW_SIZE] = raw
            .try_into()
            .map_err(|_| format!("raw id must be {RAW_SIZE} bytes"))?;
        Ok(Self { raw: arr })
    }

    /// 从 `spotify:track:xxx` / `track:xxx` / `xxx` 中提取 ID。
    pub fn from_uri(uri: &str) -> Result<Self, String> {
        let s = uri.trim();
        let id = match s.rfind(':') {
            Some(idx) => &s[idx + 1..],
            None => s,
        };
        Self::from_base62(id)
    }

    /// 22 位 base62。
    pub fn to_base62(&self) -> String {
        let mut v = u128::from_be_bytes(self.raw);
        let mut chars = [b'0'; BASE62_SIZE];
        for slot in chars.iter_mut().rev() {
            *slot = DIGITS[(v % 62) as usize];
            v /= 62;
        }
        String::from_utf8(chars.to_vec()).expect("ASCII base62 digits")
    }

    /// 32 位小写十六进制 GID。
    pub fn to_base16(&self) -> String {
        let mut out = Vec::with_capacity(BASE16_SIZE);
        for &b in &self.raw {
            out.push(HEX_DIGITS[(b >> 4) as usize]);
            out.push(HEX_DIGITS[(b & 0x0f) as usize]);
        }
        String::from_utf8(out).expect("ASCII hex digits")
    }
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base62_base16_golden_vectors() {
        assert_eq!(
            SpotifyId::from_base62("02zOzC6p81K9r7qBEmFJT9").unwrap().to_base16(),
            "015db4870e9b1c4ea11c4a3c7c0a3867"
        );
        assert_eq!(
            SpotifyId::from_base16("015db4870e9b1c4ea11c4a3c7c0a3867").unwrap().to_base62(),
            "02zOzC6p81K9r7qBEmFJT9"
        );
    }

    #[test]
    fn real_track_id_blinding_lights() {
        assert_eq!(
            SpotifyId::from_base62("0VjIjW4GlUZAMYd2vXMi3b").unwrap().to_base16(),
            "1e6028dab84d4a17a1b3fb28ad51df5d"
        );
    }

    #[test]
    fn uri_extraction() {
        for input in [
            "spotify:track:0VjIjW4GlUZAMYd2vXMi3b",
            "track:0VjIjW4GlUZAMYd2vXMi3b",
            "0VjIjW4GlUZAMYd2vXMi3b",
        ] {
            assert_eq!(SpotifyId::from_uri(input).unwrap().to_base62(), "0VjIjW4GlUZAMYd2vXMi3b");
        }
    }

    #[test]
    fn roundtrip_full_range() {
        for hex_id in [
            "00000000000000000000000000000000",
            "ffffffffffffffffffffffffffffffff",
            "1e6028dab84d4a17a1b3fb28ad51df5d",
            "00000000000000000000000000000001",
        ] {
            let b62 = SpotifyId::from_base16(hex_id).unwrap().to_base62();
            assert_eq!(b62.len(), 22);
            assert_eq!(SpotifyId::from_base62(&b62).unwrap().to_base16(), hex_id);
        }
    }

    #[test]
    fn rejects_invalid_inputs() {
        assert!(SpotifyId::from_base62("short").is_err());
        assert!(SpotifyId::from_base62("!!!!!!!!!!!!!!!!!!!!!!").is_err());
        assert!(SpotifyId::from_base16("abcd").is_err());
    }
}
