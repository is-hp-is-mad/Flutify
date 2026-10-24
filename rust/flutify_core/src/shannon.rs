//! Shannon 流密码（Spotify Access Point 通道加密）。
//!
//! 行为与 `lib/services/protocol/shannon.dart` 保持一致（取 C/Java 完整字折入 MAC 语义）。

const N: usize = 16;
const FOLD: usize = 16;
const INIT_KONST: u32 = 0x6996_c53a;
const KEY_P: usize = 13;

#[derive(Clone)]
pub struct Shannon {
    r: [u32; N],
    crc: [u32; N],
    init_r: [u32; N],
    konst: u32,
    sbuf: u32,
    mbuf: u32,
    nbuf: u32,
}

impl Shannon {
    pub fn new(key: &[u8]) -> Self {
        let mut r = [0u32; N];
        r[0] = 1;
        r[1] = 1;
        for i in 2..N {
            r[i] = r[i - 1].wrapping_add(r[i - 2]);
        }
        let mut s = Self {
            r,
            crc: [0u32; N],
            init_r: [0u32; N],
            konst: INIT_KONST,
            sbuf: 0,
            mbuf: 0,
            nbuf: 0,
        };
        s.load_key(key);
        s.genkonst();
        s.init_r = s.r;
        s
    }

    #[inline]
    fn sbox1(w: u32) -> u32 {
        let w = w ^ (w.rotate_left(5) | w.rotate_left(7));
        w ^ (w.rotate_left(19) | w.rotate_left(22))
    }

    #[inline]
    fn sbox2(w: u32) -> u32 {
        let w = w ^ (w.rotate_left(7) | w.rotate_left(22));
        w ^ (w.rotate_left(5) | w.rotate_left(19))
    }

    #[inline]
    fn genkonst(&mut self) {
        self.konst = self.r[0];
    }

    fn cycle(&mut self) {
        let mut t = Self::sbox1(self.r[12] ^ self.r[13] ^ self.konst) ^ self.r[0].rotate_left(1);
        for i in 1..N {
            self.r[i - 1] = self.r[i];
        }
        self.r[N - 1] = t;
        t = Self::sbox2(self.r[2] ^ self.r[15]);
        self.r[0] ^= t;
        self.sbuf = t ^ self.r[8] ^ self.r[12];
    }

    fn diffuse(&mut self) {
        for _ in 0..FOLD {
            self.cycle();
        }
    }

    fn load_key(&mut self, key: &[u8]) {
        let mut off = 0;
        while off < key.len() {
            let mut word = 0u32;
            let remain = (key.len() - off).min(4);
            for i in 0..remain {
                word |= (key[off + i] as u32) << (8 * i);
            }
            self.r[KEY_P] ^= word;
            self.cycle();
            off += 4;
        }
        self.r[KEY_P] ^= key.len() as u32;
        self.cycle();
        self.crc = self.r;
        self.diffuse();
        for i in 0..N {
            self.r[i] ^= self.crc[i];
        }
    }

    /// 以 4 字节大端 nonce 重新播种（每包调用一次）。
    pub fn nonce_u32(&mut self, nonce: u32) {
        self.r = self.init_r;
        self.konst = INIT_KONST;
        self.load_key(&nonce.to_be_bytes());
        self.genkonst();
        self.nbuf = 0;
        self.mbuf = 0;
    }

    #[inline]
    fn crcfunc(&mut self, word: u32) {
        let t = self.crc[0] ^ self.crc[2] ^ self.crc[15] ^ word;
        for j in 1..N {
            self.crc[j - 1] = self.crc[j];
        }
        self.crc[N - 1] = t;
    }

    #[inline]
    fn macfunc(&mut self, word: u32) {
        self.crcfunc(word);
        self.r[KEY_P] ^= word;
    }

    /// 加密 + 累积 MAC（明文计入 MAC）。原地修改 `buf`。
    pub fn encrypt(&mut self, buf: &mut [u8]) {
        self.process(buf, true);
    }

    /// 解密 + 累积 MAC（明文计入 MAC）。原地修改 `buf`。
    pub fn decrypt(&mut self, buf: &mut [u8]) {
        self.process(buf, false);
    }

    fn process(&mut self, buf: &mut [u8], encrypt_word: bool) {
        let mut i = 0;
        let n = buf.len();

        // 1) 上次调用遗留的半个字：补齐后折一次 MAC（LFSR 无需再 cycle）
        if self.nbuf != 0 {
            while self.nbuf > 0 {
                if i >= n {
                    return;
                }
                let b = buf[i];
                let shift = 32 - self.nbuf;
                let ks = ((self.sbuf >> shift) & 0xff) as u8;
                if encrypt_word {
                    self.mbuf ^= (b as u32) << shift;
                    buf[i] = b ^ ks;
                } else {
                    let pt = b ^ ks;
                    buf[i] = pt;
                    self.mbuf ^= (pt as u32) << shift;
                }
                i += 1;
                self.nbuf -= 8;
            }
            self.macfunc(self.mbuf);
        }

        // 2) 整字
        let whole_end = i + ((n - i) & !0x3);
        while i < whole_end {
            self.cycle();
            let mut t = u32::from_le_bytes([buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]);
            if encrypt_word {
                self.macfunc(t);
                t ^= self.sbuf;
            } else {
                t ^= self.sbuf;
                self.macfunc(t);
            }
            let out = t.to_le_bytes();
            buf[i..i + 4].copy_from_slice(&out);
            i += 4;
        }

        // 3) 尾部不足一个字：先 cycle，等凑齐再折 MAC
        if i < n {
            self.cycle();
            self.mbuf = 0;
            self.nbuf = 32;
            while i < n {
                let b = buf[i];
                let shift = 32 - self.nbuf;
                let ks = ((self.sbuf >> shift) & 0xff) as u8;
                if encrypt_word {
                    self.mbuf ^= (b as u32) << shift;
                    buf[i] = b ^ ks;
                } else {
                    let pt = b ^ ks;
                    buf[i] = pt;
                    self.mbuf ^= (pt as u32) << shift;
                }
                i += 1;
                self.nbuf -= 8;
            }
        }
    }

    /// 结束当前包：产出 `length` 字节 MAC。
    pub fn finish(&mut self, length: usize) -> Vec<u8> {
        if self.nbuf != 0 {
            self.macfunc(self.mbuf);
        }
        self.cycle();
        self.r[KEY_P] ^= INIT_KONST ^ (self.nbuf << 3);
        self.nbuf = 0;
        for i in 0..N {
            self.r[i] ^= self.crc[i];
        }
        self.diffuse();

        let mut out = vec![0u8; length];
        let mut produced = 0;
        while produced < length {
            self.cycle();
            for b in 0..4 {
                if produced >= length {
                    break;
                }
                out[produced] = ((self.sbuf >> (8 * b)) & 0xff) as u8;
                produced += 1;
            }
        }
        out
    }
}

/// 编码单帧 AP 数据包：`cmd(1) + len(2 BE) + payload + mac(4)`。
pub fn encode_ap_packet(key: &[u8], nonce: u32, cmd: u8, payload: &[u8]) -> Vec<u8> {
    let mut s = Shannon::new(key);
    s.nonce_u32(nonce);
    let len = payload.len() as u16;
    let len_be = len.to_be_bytes();
    let mut frame = Vec::with_capacity(3 + payload.len() + 4);
    frame.push(cmd);
    frame.extend_from_slice(&len_be);
    frame.extend_from_slice(payload);
    s.encrypt(&mut frame);
    let mac = s.finish(4);
    frame.extend_from_slice(&mac);
    frame
}

/// 解密 AP 包的 3 字节头 `cmd + len(BE)`（先于包体到达，用来得知包体长度）。
pub fn decrypt_ap_header(key: &[u8], nonce: u32, header: &[u8]) -> Result<Vec<u8>, String> {
    if header.len() != 3 {
        return Err("AP header must be 3 bytes".to_string());
    }
    let mut s = Shannon::new(key);
    s.nonce_u32(nonce);
    let mut out = header.to_vec();
    s.decrypt(&mut out);
    Ok(out)
}

/// 解密并校验一个完整 AP 包（头、体按收包时的两次调用解密，MAC 不符返回错误），返回包体明文。
pub fn decode_ap_packet(
    key: &[u8],
    nonce: u32,
    header: &[u8],
    body: &[u8],
    mac: &[u8],
) -> Result<Vec<u8>, String> {
    if header.len() != 3 || mac.len() != 4 {
        return Err("bad AP frame".to_string());
    }
    let mut s = Shannon::new(key);
    s.nonce_u32(nonce);
    let mut head = header.to_vec();
    s.decrypt(&mut head);
    let mut payload = body.to_vec();
    s.decrypt(&mut payload);
    if s.finish(4) != mac {
        return Err("AP packet MAC mismatch".to_string());
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn hex_of(data: &[u8]) -> String {
        let mut s = String::with_capacity(data.len() * 2);
        for b in data {
            s.push_str(&format!("{b:02x}"));
        }
        s
    }

    const KEY_HEX: &str = "f1e2d3c4b5a69788796a5b4c3d2e1f00";
    const PT_HEX: &str = "a20d90a8e46cd854b052527cfe0c417ac95ed19c0d46d056808b56d1828b";

    #[test]
    fn encrypt_and_mac_golden_nonce_7() {
        let mut shannon = Shannon::new(&hex(KEY_HEX));
        shannon.nonce_u32(7);
        let mut data = hex(PT_HEX);
        shannon.encrypt(&mut data);
        assert_eq!(
            hex_of(&data),
            "68dd29ea34198a2328e3b0ac64aa2e84601dafc77cbb4a3b5e9fc239f06a"
        );
        assert_eq!(hex_of(&shannon.finish(4)), "72a47775");
    }

    #[test]
    fn decrypt_and_mac_golden_nonce_7() {
        let mut shannon = Shannon::new(&hex(KEY_HEX));
        shannon.nonce_u32(7);
        let mut data = hex("68dd29ea34198a2328e3b0ac64aa2e84601dafc77cbb4a3b5e9fc239f06a");
        shannon.decrypt(&mut data);
        assert_eq!(hex_of(&data), PT_HEX);
        assert_eq!(hex_of(&shannon.finish(4)), "72a47775");
    }

    #[test]
    fn split_header_and_payload_nonce_0() {
        let mut shannon = Shannon::new(&hex(KEY_HEX));
        shannon.nonce_u32(0);
        let mut header = hex("0c0024");
        shannon.encrypt(&mut header);
        assert_eq!(hex_of(&header), "df42b5");
        let mut payload = hex(PT_HEX);
        shannon.encrypt(&mut payload);
        assert_eq!(
            hex_of(&payload),
            "30fe46ab823ff84de8838bde5429066e16d50f58a2935d8c3df322a3e27d"
        );
        assert_eq!(hex_of(&shannon.finish(4)), "ca143ce1");
    }

    #[test]
    fn ap_frames_match_dart_and_round_trip() {
        use crate::test_vectors::{hex as h, vector};
        let key = h(&vector("sendKey"));
        let payloads: [Vec<u8>; 3] = [
            vec![],
            (1..=5).collect(),
            (0..1000u32).map(|i| ((i * 13) & 0xff) as u8).collect(),
        ];
        for (i, payload) in payloads.iter().enumerate() {
            let frame = encode_ap_packet(&key, i as u32, 0x40 + i as u8, payload);
            assert_eq!(hex_of(&frame), vector(&format!("frame{i}")));
            let header = decrypt_ap_header(&key, i as u32, &frame[..3]).unwrap();
            assert_eq!(header[0], 0x40 + i as u8);
            let len = ((header[1] as usize) << 8) | header[2] as usize;
            assert_eq!(len, payload.len());
            let body = decode_ap_packet(&key, i as u32, &frame[..3], &frame[3..3 + len], &frame[3 + len..]).unwrap();
            assert_eq!(&body, payload);
        }
    }

    #[test]
    fn ap_packet_rejects_bad_mac() {
        let key = hex(KEY_HEX);
        let mut frame = encode_ap_packet(&key, 3, 0x10, &[9, 8, 7]);
        let last = frame.len() - 1;
        frame[last] ^= 1;
        assert!(decode_ap_packet(&key, 3, &frame[..3], &frame[3..6], &frame[6..]).is_err());
        assert!(decrypt_ap_header(&key, 3, &frame[..2]).is_err());
    }
}
