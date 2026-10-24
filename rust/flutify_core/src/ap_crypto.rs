//! Access Point 握手的密钥学原语（对照 librespot `handshake.rs` / `diffie_hellman.rs`）：
//! - DH（768 位 Oakley Group 1，generator 2）；
//! - 握手密钥推导（HMAC-SHA1 链）；
//! - 服务端 DH 公钥签名验证（RSA PKCS#1 v1.5 + SHA-1）。
//!
//! 行为与 `lib/services/protocol/ap_crypto.dart` 逐字节一致（见 tests/fixtures/ap_vectors.txt）。

use num_bigint::BigUint;

use crate::web_totp::{hmac_sha1, sha1};

/// RFC 2409 Oakley Group 1（768 位 / 96 字节）。
const DH_PRIME_HEX: &str = concat!(
    "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74",
    "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437",
    "4fe1356d6d51c245e485b576625e7ec6f44c42e9a63a3620ffffffffffffffff",
);

/// DH 公钥固定长度（字节），按大端补齐发送。
pub const DH_KEY_LENGTH: usize = 96;

fn dh_prime() -> BigUint {
    BigUint::parse_bytes(DH_PRIME_HEX.as_bytes(), 16).expect("valid prime")
}

/// 大端补齐到 [length] 字节；超长返回错误。
fn to_be_padded(value: &BigUint, length: usize) -> Result<Vec<u8>, String> {
    let bytes = value.to_bytes_be();
    if bytes.len() > length {
        return Err("value too large".to_string());
    }
    let mut out = vec![0u8; length - bytes.len()];
    out.extend_from_slice(&bytes);
    Ok(out)
}

/// 最小大端字节（无前导零；0 为单个 0 字节），与 librespot `to_bytes_be` 一致。
fn to_be_minimal(value: &BigUint) -> Vec<u8> {
    value.to_bytes_be()
}

/// 私钥（95 字节小端）→ 96 字节大端公钥 `2^priv mod p`。
pub fn dh_public_key(private_le: &[u8]) -> Result<Vec<u8>, String> {
    let private = BigUint::from_bytes_le(private_le);
    let public = BigUint::from(2u32).modpow(&private, &dh_prime());
    to_be_padded(&public, DH_KEY_LENGTH)
}

/// 共享密钥 `remote^priv mod p`（最小大端字节）。
pub fn dh_shared_secret(private_le: &[u8], remote_be: &[u8]) -> Vec<u8> {
    let private = BigUint::from_bytes_le(private_le);
    let remote = BigUint::from_bytes_be(remote_be);
    to_be_minimal(&remote.modpow(&private, &dh_prime()))
}

pub struct ApKeys {
    pub challenge: Vec<u8>,
    pub send_key: Vec<u8>,
    pub recv_key: Vec<u8>,
}

/// 由握手期双方报文字节（含帧头）推导 challenge / send_key / recv_key：
/// `data = HMAC(shared, packets || i) for i in 1..=5`，
/// `challenge = HMAC(data[0..20], packets)`，`send = data[20..52]`，`recv = data[52..84]`。
pub fn compute_keys(shared_secret: &[u8], handshake_packets: &[u8]) -> ApKeys {
    let mut data = Vec::with_capacity(100);
    let mut message = Vec::with_capacity(handshake_packets.len() + 1);
    message.extend_from_slice(handshake_packets);
    message.push(0);
    for i in 1..=5u8 {
        *message.last_mut().unwrap() = i;
        data.extend_from_slice(&hmac_sha1(shared_secret, &message));
    }
    ApKeys {
        challenge: hmac_sha1(&data[0..20], handshake_packets).to_vec(),
        send_key: data[20..52].to_vec(),
        recv_key: data[52..84].to_vec(),
    }
}

const SHA1_DIGEST_INFO: [u8; 15] = [
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
];

/// RSA PKCS#1 v1.5 + SHA-1 验签（e = 65537）：`sig^e mod n` 应为
/// `00 01 FF..FF 00 || DigestInfo(SHA-1) || H(message)`，FF 至少 8 个。
pub fn rsa_verify_pkcs1_sha1(modulus: &[u8], signature: &[u8], message: &[u8]) -> bool {
    let n = BigUint::from_bytes_be(modulus);
    if n == BigUint::from(0u32) {
        return false;
    }
    let s = BigUint::from_bytes_be(signature);
    let m = s.modpow(&BigUint::from(65537u32), &n);
    let em = match to_be_padded(&m, modulus.len()) {
        Ok(em) => em,
        Err(_) => return false,
    };

    let hash = sha1(message);
    let expected_len = SHA1_DIGEST_INFO.len() + hash.len();
    if em.len() < expected_len + 11 {
        return false;
    }
    let sep = em.len() - expected_len - 1;
    if em[0] != 0x00 || em[1] != 0x01 {
        return false;
    }
    if em[2..sep].iter().any(|&b| b != 0xff) || em[sep] != 0x00 {
        return false;
    }
    em[sep + 1..sep + 1 + SHA1_DIGEST_INFO.len()] == SHA1_DIGEST_INFO
        && em[sep + 1 + SHA1_DIGEST_INFO.len()..] == hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_vectors::{hex, vector};

    #[test]
    fn dh_matches_dart() {
        assert_eq!(dh_public_key(&hex(&vector("privA"))).unwrap(), hex(&vector("pubA")));
        assert_eq!(dh_public_key(&hex(&vector("privB"))).unwrap(), hex(&vector("pubB")));
        let shared = dh_shared_secret(&hex(&vector("privA")), &hex(&vector("pubB")));
        assert_eq!(shared, hex(&vector("shared")));
        // 对称：B 侧算出同一个共享密钥
        assert_eq!(dh_shared_secret(&hex(&vector("privB")), &hex(&vector("pubA"))), shared);
    }

    #[test]
    fn handshake_keys_match_dart() {
        let keys = compute_keys(&hex(&vector("shared")), &hex(&vector("packets")));
        assert_eq!(keys.challenge, hex(&vector("challenge")));
        assert_eq!(keys.send_key, hex(&vector("sendKey")));
        assert_eq!(keys.recv_key, hex(&vector("recvKey")));
    }

    #[test]
    fn rsa_accepts_valid_and_rejects_tampered() {
        let n = hex(&vector("rsaN"));
        let sig = hex(&vector("rsaSig"));
        let mut msg = hex(&vector("rsaMsg"));
        assert!(rsa_verify_pkcs1_sha1(&n, &sig, &msg));
        msg[0] ^= 1;
        assert!(!rsa_verify_pkcs1_sha1(&n, &sig, &msg));
        assert!(!rsa_verify_pkcs1_sha1(&n, &sig[1..], &hex(&vector("rsaMsg"))));
    }

    #[test]
    fn rsa_rejects_forged_and_degenerate() {
        let modulus: Vec<u8> = (0..=255u8).collect();
        let signature: Vec<u8> = (0..=255u8).rev().collect();
        assert!(!rsa_verify_pkcs1_sha1(&modulus, &signature, &[1, 2, 3]));
        assert!(!rsa_verify_pkcs1_sha1(&[0; 256], &signature, &[1, 2, 3]));
    }
}
