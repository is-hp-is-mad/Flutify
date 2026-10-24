//! Spotify Web 播放器 TOTP 密钥反混淆与一次性口令生成（RFC 6238 / HMAC-SHA1）。
//!
//! 行为与 `lib/services/auth/web_token_service.dart` 保持一致。

pub const TOTP_VERSION: u32 = 61;
pub const OBFUSCATED_SECRET_V61: &str = ",7/*F(\"rLJ2oxaKL^f+E1xvP@N";

/// 还原混淆的 TOTP secret：逐字节 `b ^ ((i % 33) + 9)`，十进制拼接后的 ASCII 字节即为 secret。
pub fn deobfuscate_secret(obfuscated: &str) -> Vec<u8> {
    let mut joined = String::new();
    for (i, b) in obfuscated.bytes().enumerate() {
        let code = (b as u32) ^ (((i as u32) % 33) + 9);
        joined.push_str(&code.to_string());
    }
    joined.into_bytes()
}

/// 标准 TOTP（HMAC-SHA1，默认 30 秒周期、6 位数字）。
pub fn totp(secret: &[u8], timestamp_ms: i64, period: i64, digits: u32) -> String {
    let period = period.max(1);
    let digits = digits.clamp(1, 9);
    let counter = (timestamp_ms / 1000 / period) as u64;
    let msg = counter.to_be_bytes();
    let h = hmac_sha1(secret, &msg);
    let off = (h[19] & 0x0f) as usize;
    let raw = u32::from_be_bytes([h[off], h[off + 1], h[off + 2], h[off + 3]]) & 0x7fff_ffff;
    let code = raw % 10u32.pow(digits);
    format!("{:0width$}", code, width = digits as usize)
}

/// 使用内置 V61 密钥直接计算指定毫秒时间戳的 6 位 TOTP。
pub fn web_player_totp_v61(timestamp_ms: i64) -> String {
    let secret = deobfuscate_secret(OBFUSCATED_SECRET_V61);
    totp(&secret, timestamp_ms, 30, 6)
}

/// SHA-1（FIPS 180-4）。
pub fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h0: u32 = 0x67452301;
    let mut h1: u32 = 0xefcdab89;
    let mut h2: u32 = 0x98badcfe;
    let mut h3: u32 = 0x10325476;
    let mut h4: u32 = 0xc3d2e1f0;

    let bit_len = (data.len() as u64) * 8;
    let mut padded = Vec::with_capacity((data.len() + 9).div_ceil(64) * 64);
    padded.extend_from_slice(data);
    padded.push(0x80);
    while (padded.len() % 64) != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in padded.as_chunks::<64>().0 {
        let mut w = [0u32; 80];
        for (i, word) in chunk.as_chunks::<4>().0.iter().enumerate() {
            w[i] = u32::from_be_bytes(*word);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }

        let (mut a, mut b, mut c, mut d, mut e) = (h0, h1, h2, h3, h4);
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5a827999),
                20..=39 => (b ^ c ^ d, 0x6ed9eba1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8f1bbcdc),
                _ => (b ^ c ^ d, 0xca62c1d6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }

        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
        h4 = h4.wrapping_add(e);
    }

    let mut out = [0u8; 20];
    out[0..4].copy_from_slice(&h0.to_be_bytes());
    out[4..8].copy_from_slice(&h1.to_be_bytes());
    out[8..12].copy_from_slice(&h2.to_be_bytes());
    out[12..16].copy_from_slice(&h3.to_be_bytes());
    out[16..20].copy_from_slice(&h4.to_be_bytes());
    out
}

/// HMAC-SHA1（RFC 2104）。
pub fn hmac_sha1(key: &[u8], message: &[u8]) -> [u8; 20] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let hashed = sha1(key);
        k_block[..20].copy_from_slice(&hashed);
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }

    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k_block[i];
        opad[i] ^= k_block[i];
    }

    let mut inner = Vec::with_capacity(64 + message.len());
    inner.extend_from_slice(&ipad);
    inner.extend_from_slice(message);
    let inner_hash = sha1(&inner);

    let mut outer = [0u8; 84];
    outer[..64].copy_from_slice(&opad);
    outer[64..].copy_from_slice(&inner_hash);
    sha1(&outer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_standard_vectors() {
        let h = sha1(b"abc");
        let hex: String = h.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "a9993e364706816aba3e25717850c26c9cd0d89d");
    }

    #[test]
    fn rfc6238_totp_sha1_vectors() {
        let secret = b"12345678901234567890";
        assert_eq!(totp(secret, 59_000, 30, 8), "94287082");
        assert_eq!(totp(secret, 1_111_111_109_000, 30, 8), "07081804");
        assert_eq!(totp(secret, 1_234_567_890_000, 30, 8), "89005924");
    }

    #[test]
    fn v61_secret_deobfuscation_and_totp() {
        let secret = deobfuscate_secret(OBFUSCATED_SECRET_V61);
        assert!(!secret.is_empty());
        let code = web_player_totp_v61(1_700_000_000_000);
        assert_eq!(code.len(), 6);
        assert!(code.bytes().all(|b| b.is_ascii_digit()));
    }
}
