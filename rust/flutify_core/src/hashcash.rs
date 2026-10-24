//! Spotify Hashcash 工作量证明求解器（SHA-1 PoW）。
//!
//! 行为与 `lib/services/auth/hashcash.dart` 及 librespot `util::solve_hash_cash` 一致：
//! 1. `target = int64_be(SHA1(ctx)[12..20])`；
//! 2. 从 `counter = 0` 起循环，`suffix = be8(target + counter) ++ be8(counter)`（共 16 字节）；
//! 3. 若 `int64_be(SHA1(prefix ++ suffix)[12..20])` 的末尾 0 比特数 >= `length`，则 `suffix` 即解。

use std::time::{Duration, Instant};

use crate::web_totp::sha1;

/// 求解 Hashcash 并返回 16 字节 suffix；超时则报错。
pub fn solve_hashcash(
    ctx: &[u8],
    prefix: &[u8],
    length: u32,
    timeout_ms: u64,
) -> Result<[u8; 16], String> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let md = sha1(ctx);
    let target = i64::from_be_bytes([
        md[12], md[13], md[14], md[15], md[16], md[17], md[18], md[19],
    ]);

    let mut buf = Vec::with_capacity(prefix.len() + 16);
    buf.extend_from_slice(prefix);
    let suffix_start = prefix.len();
    buf.extend_from_slice(&[0u8; 16]);

    let mut counter: i64 = 0;
    loop {
        if (counter & 0xff) == 0 && Instant::now() > deadline {
            return Err(format!("Hashcash 求解超时（{length} 位难度）"));
        }

        let hi = target.wrapping_add(counter).to_be_bytes();
        let lo = counter.to_be_bytes();
        buf[suffix_start..suffix_start + 8].copy_from_slice(&hi);
        buf[suffix_start + 8..suffix_start + 16].copy_from_slice(&lo);

        let sum = sha1(&buf);
        let tail = u64::from_be_bytes([
            sum[12], sum[13], sum[14], sum[15], sum[16], sum[17], sum[18], sum[19],
        ]);
        if tail.trailing_zeros() >= length {
            let mut suffix = [0u8; 16];
            suffix[..8].copy_from_slice(&hi);
            suffix[8..].copy_from_slice(&lo);
            return Ok(suffix);
        }

        counter = counter.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solves_valid_hashcash_suffix() {
        let ctx = b"spotify-login-ctx";
        let prefix = b"0123456789abcdef";
        let suffix = solve_hashcash(ctx, prefix, 10, 5000).unwrap();
        let mut msg = Vec::from(&prefix[..]);
        msg.extend_from_slice(&suffix);
        let sum = sha1(&msg);
        let tail = u64::from_be_bytes([
            sum[12], sum[13], sum[14], sum[15], sum[16], sum[17], sum[18], sum[19],
        ]);
        assert!(tail.trailing_zeros() >= 10);
    }
}
