//! AES 分组密码（FIPS-197）+ CTR 工作模式（Ctr128BE）。
//!
//! 行为与 `lib/services/protocol/aes.dart` 保持一致。

const SBOX: [u8; 256] = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

const RCON: [u8; 10] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

#[derive(Clone)]
pub struct AesCipher {
    rounds: usize,
    round_keys: Vec<u8>,
}

impl AesCipher {
    pub fn new(key: &[u8]) -> Result<Self, String> {
        if !matches!(key.len(), 16 | 24 | 32) {
            return Err(format!("AES key must be 16/24/32 bytes, got {}", key.len()));
        }
        let nk = key.len() / 4;
        let rounds = nk + 6;
        let mut expanded = vec![0u8; 16 * (rounds + 1)];
        expanded[..key.len()].copy_from_slice(key);

        let mut temp = [0u8; 4];
        for i in nk..(4 * (rounds + 1)) {
            temp.copy_from_slice(&expanded[4 * (i - 1)..4 * i]);
            if i.is_multiple_of(nk) {
                let t = temp[0];
                temp[0] = SBOX[temp[1] as usize] ^ RCON[i / nk - 1];
                temp[1] = SBOX[temp[2] as usize];
                temp[2] = SBOX[temp[3] as usize];
                temp[3] = SBOX[t as usize];
            } else if nk > 6 && i % nk == 4 {
                for b in &mut temp {
                    *b = SBOX[*b as usize];
                }
            }
            for b in 0..4 {
                expanded[4 * i + b] = expanded[4 * (i - nk) + b] ^ temp[b];
            }
        }
        Ok(Self { rounds, round_keys: expanded })
    }

    pub fn encrypt_block(&self, block: &[u8]) -> Result<[u8; 16], String> {
        let mut s: [u8; 16] = block
            .try_into()
            .map_err(|_| format!("AES block must be 16 bytes, got {}", block.len()))?;
        self.encrypt_in_place(&mut s);
        Ok(s)
    }

    pub fn encrypt_in_place(&self, s: &mut [u8; 16]) {
        self.add_round_key(s, 0);
        for round in 1..self.rounds {
            Self::sub_bytes(s);
            Self::shift_rows(s);
            Self::mix_columns(s);
            self.add_round_key(s, round);
        }
        Self::sub_bytes(s);
        Self::shift_rows(s);
        self.add_round_key(s, self.rounds);
    }

    fn add_round_key(&self, s: &mut [u8; 16], round: usize) {
        let rk = &self.round_keys[16 * round..16 * (round + 1)];
        for (b, &k) in s.iter_mut().zip(rk.iter()) {
            *b ^= k;
        }
    }

    fn sub_bytes(s: &mut [u8; 16]) {
        for b in s.iter_mut() {
            *b = SBOX[*b as usize];
        }
    }

    fn shift_rows(s: &mut [u8; 16]) {
        let t = s[1];
        s[1] = s[5];
        s[5] = s[9];
        s[9] = s[13];
        s[13] = t;

        s.swap(2, 10);
        s.swap(6, 14);

        let t = s[15];
        s[15] = s[11];
        s[11] = s[7];
        s[7] = s[3];
        s[3] = t;
    }

    fn mix_columns(s: &mut [u8; 16]) {
        for c in 0..4 {
            let (a0, a1, a2, a3) = (s[4 * c], s[4 * c + 1], s[4 * c + 2], s[4 * c + 3]);
            s[4 * c] = Self::mul2(a0) ^ Self::mul3(a1) ^ a2 ^ a3;
            s[4 * c + 1] = a0 ^ Self::mul2(a1) ^ Self::mul3(a2) ^ a3;
            s[4 * c + 2] = a0 ^ a1 ^ Self::mul2(a2) ^ Self::mul3(a3);
            s[4 * c + 3] = Self::mul3(a0) ^ a1 ^ a2 ^ Self::mul2(a3);
        }
    }

    #[inline]
    fn mul2(x: u8) -> u8 {
        (x << 1) ^ if (x & 0x80) != 0 { 0x1b } else { 0 }
    }

    #[inline]
    fn mul3(x: u8) -> u8 {
        Self::mul2(x) ^ x
    }
}

pub struct AesCtr {
    cipher: AesCipher,
    counter: [u8; 16],
    keystream: [u8; 16],
    keystream_pos: usize,
    offset: usize,
}

impl AesCtr {
    pub fn new(key: &[u8], iv: &[u8]) -> Result<Self, String> {
        let counter: [u8; 16] = iv
            .try_into()
            .map_err(|_| format!("CTR IV must be 16 bytes, got {}", iv.len()))?;
        let cipher = AesCipher::new(key)?;
        Ok(Self {
            cipher,
            counter,
            keystream: [0u8; 16],
            keystream_pos: 16,
            offset: 0,
        })
    }

    pub fn at_offset(key: &[u8], iv: &[u8], offset: usize) -> Result<Self, String> {
        let mut ctr = Self::new(key, iv)?;
        ctr.add_to_counter((offset / 16) as u128);
        let rem = offset % 16;
        if rem > 0 {
            ctr.next_keystream_block();
            ctr.keystream_pos = rem;
        }
        ctr.offset = offset;
        Ok(ctr)
    }

    pub fn process(&mut self, data: &mut [u8]) {
        let mut pos = self.keystream_pos;
        for b in data.iter_mut() {
            if pos == 16 {
                self.next_keystream_block();
                pos = 0;
            }
            *b ^= self.keystream[pos];
            pos += 1;
        }
        self.keystream_pos = pos;
        self.offset += data.len();
    }

    pub fn offset(&self) -> usize {
        self.offset
    }

    fn next_keystream_block(&mut self) {
        self.keystream = self.counter;
        self.cipher.encrypt_in_place(&mut self.keystream);
        self.increment_counter();
    }

    fn add_to_counter(&mut self, blocks: u128) {
        let val = u128::from_be_bytes(self.counter).wrapping_add(blocks);
        self.counter = val.to_be_bytes();
    }

    fn increment_counter(&mut self) {
        for b in self.counter.iter_mut().rev() {
            *b = b.wrapping_add(1);
            if *b != 0 {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len() / 2)
            .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
            .collect()
    }

    fn hex_of(data: &[u8]) -> String {
        data.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn fips_197_appendix_c_vectors() {
        let pt = hex("00112233445566778899aabbccddeeff");

        let c128 = AesCipher::new(&hex("000102030405060708090a0b0c0d0e0f")).unwrap();
        assert_eq!(
            hex_of(&c128.encrypt_block(&pt).unwrap()),
            "69c4e0d86a7b0430d8cdb78070b4c55a"
        );

        let c192 =
            AesCipher::new(&hex("000102030405060708090a0b0c0d0e0f1011121314151617")).unwrap();
        assert_eq!(
            hex_of(&c192.encrypt_block(&pt).unwrap()),
            "dda97ca4864cdfe06eaf70a0ec0d7191"
        );

        let c256 = AesCipher::new(&hex(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        ))
        .unwrap();
        assert_eq!(
            hex_of(&c256.encrypt_block(&pt).unwrap()),
            "8ea2b7ca516745bfeafc49904b496089"
        );

        assert!(AesCipher::new(&[0u8; 15]).is_err());
    }

    #[test]
    fn sp_800_38a_ctr_vector() {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c");
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
        let pt = hex(concat!(
            "6bc1bee22e409f96e93d7e117393172a",
            "ae2d8a571e03ac9c9eb76fac45af8e51",
            "30c81c46a35ce411e5fbc1191a0a52ef"
        ));
        let expected = hex(concat!(
            "874d6191b620e3261bef6864990db6ce",
            "9806f66b7970fdff8617187bb9fffdff",
            "5ae4df3edbd5d35e5b4f09020db03eab"
        ));

        let mut data = pt.clone();
        AesCtr::new(&key, &iv).unwrap().process(&mut data);
        assert_eq!(data, expected);

        AesCtr::new(&key, &iv).unwrap().process(&mut data);
        assert_eq!(data, pt);
    }

    #[test]
    fn ctr_chunked_and_at_offset() {
        let key = hex("f8e18cf61b5ee520660e33a6d725c0d7");
        let iv = hex("e652d95733c05b6d69ef66a427ffffff");
        let pt: Vec<u8> = (0..1000).map(|i| ((i * 7 + 3) & 0xff) as u8).collect();
        let mut full = pt.clone();
        AesCtr::new(&key, &iv).unwrap().process(&mut full);

        for offset in [0, 1, 15, 16, 17, 255, 256, 513, 999] {
            let mut tail = pt[offset..].to_vec();
            let mut cipher = AesCtr::at_offset(&key, &iv, offset).unwrap();
            cipher.process(&mut tail);
            assert_eq!(tail, &full[offset..], "offset {offset}");
            assert_eq!(cipher.offset(), pt.len());
        }
    }
}
