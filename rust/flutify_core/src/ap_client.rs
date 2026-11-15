//! Spotify AccessPoint (AP) 长连接、DH+Shannon 握手、登录、音频密钥、Mercury 与 StorageResolve/ExtendedMetadata。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{oneshot, Mutex as AsyncMutex};

use crate::ap_crypto;
use crate::proto_lite::{write_bytes, write_int32, write_string, write_varint, ProtoMsg};
use crate::shannon;
use crate::spotify_session;
use crate::ws;

const AP_SERVER_KEY_MODULUS: [u8; 256] = [
    0xac, 0xe0, 0x46, 0x0b, 0xff, 0xc2, 0x30, 0xaf, 0xf4, 0x6b, 0xfe, 0xc3, 0xbf, 0xbf, 0x86, 0x3d,
    0xa1, 0x91, 0xc6, 0xcc, 0x33, 0x6c, 0x93, 0xa1, 0x4f, 0xb3, 0xb0, 0x16, 0x12, 0xac, 0xac, 0x6a,
    0xf1, 0x80, 0xe7, 0xf6, 0x14, 0xd9, 0x42, 0x9d, 0xbe, 0x2e, 0x34, 0x66, 0x43, 0xe3, 0x62, 0xd2,
    0x32, 0x7a, 0x1a, 0x0d, 0x92, 0x3b, 0xae, 0xdd, 0x14, 0x02, 0xb1, 0x81, 0x55, 0x05, 0x61, 0x04,
    0xd5, 0x2c, 0x96, 0xa4, 0x4c, 0x1e, 0xcc, 0x02, 0x4a, 0xd4, 0xb2, 0x0c, 0x00, 0x1f, 0x17, 0xed,
    0xc2, 0x2f, 0xc4, 0x35, 0x21, 0xc8, 0xf0, 0xcb, 0xae, 0xd2, 0xad, 0xd7, 0x2b, 0x0f, 0x9d, 0xb3,
    0xc5, 0x32, 0x1a, 0x2a, 0xfe, 0x59, 0xf3, 0x5a, 0x0d, 0xac, 0x68, 0xf1, 0xfa, 0x62, 0x1e, 0xfb,
    0x2c, 0x8d, 0x0c, 0xb7, 0x39, 0x2d, 0x92, 0x47, 0xe3, 0xd7, 0x35, 0x1a, 0x6d, 0xbd, 0x24, 0xc2,
    0xae, 0x25, 0x5b, 0x88, 0xff, 0xab, 0x73, 0x29, 0x8a, 0x0b, 0xcc, 0xcd, 0x0c, 0x58, 0x67, 0x31,
    0x89, 0xe8, 0xbd, 0x34, 0x80, 0x78, 0x4a, 0x5f, 0xc9, 0x6b, 0x89, 0x9d, 0x95, 0x6b, 0xfc, 0x86,
    0xd7, 0x4f, 0x33, 0xa6, 0x78, 0x17, 0x96, 0xc9, 0xc3, 0x2d, 0x0d, 0x32, 0xa5, 0xab, 0xcd, 0x05,
    0x27, 0xe2, 0xf7, 0x10, 0xa3, 0x96, 0x13, 0xc4, 0x2f, 0x99, 0xc0, 0x27, 0xbf, 0xed, 0x04, 0x9c,
    0x3c, 0x27, 0x58, 0x04, 0xb6, 0xb2, 0x19, 0xf9, 0xc1, 0x2f, 0x02, 0xe9, 0x48, 0x63, 0xec, 0xa1,
    0xb6, 0x42, 0xa0, 0x9d, 0x48, 0x25, 0xf8, 0xb3, 0x9d, 0xd0, 0xe8, 0x6a, 0xf9, 0x48, 0x4d, 0xa1,
    0xc2, 0xba, 0x86, 0x30, 0x42, 0xea, 0x9d, 0xb3, 0x08, 0x6c, 0x19, 0x0e, 0x48, 0xb3, 0x9d, 0x66,
    0xeb, 0x00, 0x06, 0xa2, 0x5a, 0xee, 0xa1, 0x1b, 0x13, 0x87, 0x3c, 0xd7, 0x19, 0xe6, 0x55, 0xbd,
];

const CMD_PING: u8 = 0x04;
const CMD_REQUEST_KEY: u8 = 0x0c;
const CMD_AES_KEY: u8 = 0x0d;
const CMD_AES_KEY_ERROR: u8 = 0x0e;
const CMD_PONG: u8 = 0x49;
const CMD_LOGIN: u8 = 0xab;
const CMD_AP_WELCOME: u8 = 0xac;
const CMD_AUTH_FAILURE: u8 = 0xad;
const CMD_MERCURY_REQ: u8 = 0xb2;

const DESKTOP_VERSION: &str = "1.2.84.476.ga19d6c2c";
const DESKTOP_BUILD_NUMBER: i32 = 102840476;

#[derive(Debug, Clone)]
pub struct BackendStorageResolveResult {
    pub result: i32,
    pub cdn_urls: Vec<String>,
    pub file_id: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct BackendApWelcome {
    pub session_id: u64,
    pub canonical_username: String,
    pub reusable_auth_type: i32,
    pub reusable_auth: Vec<u8>,
}

pub async fn resolve_audio_storage(
    spclient_base: &str,
    file_id_hex: &str,
) -> Result<BackendStorageResolveResult, String> {
    let base = spclient_base.trim_end_matches('/');
    let paths = [
        format!("{base}/storage-resolve/files/audio/interactive/{file_id_hex}"),
        format!("{base}/storage-resolve/v2/files/audio/interactive/{file_id_hex}"),
    ];
    let mut last_status = 0u16;
    for url in &paths {
        let (status, bytes) = spotify_session::authorized_request(
            reqwest::Method::GET,
            url,
            &[("Accept", "application/x-protobuf")],
            None,
        )
        .await?;
        if status == 200 {
            let msg = ProtoMsg::parse(&bytes);
            let result = msg.integer(1) as i32;
            let cdn_urls: Vec<String> = msg.strs(2).into_iter().map(str::to_string).collect();
            let file_id = msg.bytes(4).unwrap_or(&[]).to_vec();
            if cdn_urls.is_empty() {
                return Err(format!("storage-resolve:empty cdn_urls (result={result})"));
            }
            return Ok(BackendStorageResolveResult {
                result,
                cdn_urls,
                file_id,
            });
        }
        last_status = status;
        if status != 404 {
            break;
        }
    }
    Err(format!("http:{last_status}:storage-resolve"))
}

pub async fn fetch_extended_metadata(
    spclient_base: &str,
    entity_uris: Vec<String>,
    kind: i32,
) -> Result<Vec<(String, Vec<u8>)>, String> {
    if entity_uris.is_empty() {
        return Ok(Vec::new());
    }
    let mut header = Vec::new();
    write_string(&mut header, 1, "from_token");
    let mut req = Vec::new();
    write_bytes(&mut req, 1, &header);

    for uri in &entity_uris {
        let mut q = Vec::new();
        write_int32(&mut q, 1, kind);
        let mut ent = Vec::new();
        write_string(&mut ent, 1, uri);
        write_bytes(&mut ent, 2, &q);
        write_bytes(&mut req, 2, &ent);
    }

    let base = spclient_base.trim_end_matches('/');
    let url = format!("{base}/extended-metadata/v0/extended-metadata");
    let (status, bytes) = spotify_session::authorized_request(
        reqwest::Method::POST,
        &url,
        &[
            ("Accept", "application/protobuf"),
            ("Content-Type", "application/protobuf"),
        ],
        Some(req),
    )
    .await?;
    if status != 200 {
        return Err(format!("http:{status}:extended-metadata"));
    }

    let root = ProtoMsg::parse(&bytes);
    let mut out = Vec::new();
    for ext_meta in root.msgs(2) {
        if ext_meta.integer(2) as i32 != kind {
            continue;
        }
        for ext_data in ext_meta.msgs(3) {
            let status_code = ext_data.msg(1).integer(1);
            if status_code != 0 && status_code != 200 {
                continue;
            }
            let uri = ext_data.str(2).to_string();
            if uri.is_empty() {
                continue;
            }
            if let Some(any) = ext_data.any(3) {
                if let Some(val_bytes) = ext_data.msg(3).bytes(2) {
                    let _ = any;
                    out.push((uri, val_bytes.to_vec()));
                }
            }
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// AP 长连接池与会话实现
// ---------------------------------------------------------------------------

struct SendState {
    writer: OwnedWriteHalf,
    key: Vec<u8>,
    nonce: u32,
}

impl SendState {
    async fn send_packet(&mut self, cmd: u8, payload: &[u8]) -> Result<(), String> {
        let frame = shannon::encode_ap_packet(&self.key, self.nonce, cmd, payload);
        self.nonce = self.nonce.wrapping_add(1);
        self.writer
            .write_all(&frame)
            .await
            .map_err(|e| format!("ap_write:{e}"))?;
        self.writer
            .flush()
            .await
            .map_err(|e| format!("ap_flush:{e}"))
    }
}

pub struct ApSession {
    send: AsyncMutex<SendState>,
    key_seq: AtomicU32,
    mercury_seq: AtomicU64,
    pending_keys: Mutex<HashMap<u32, oneshot::Sender<Result<Vec<u8>, String>>>>,
    pending_mercury: Mutex<HashMap<u64, oneshot::Sender<Result<Vec<u8>, String>>>>,
    closed: AtomicU32,
}

impl ApSession {
    async fn send_packet(&self, cmd: u8, payload: &[u8]) -> Result<(), String> {
        if self.closed.load(Ordering::Acquire) != 0 {
            return Err("ap:closed".into());
        }
        let mut guard = self.send.lock().await;
        guard.send_packet(cmd, payload).await
    }

    fn close_all(&self, reason: &str) {
        self.closed.store(1, Ordering::Release);
        if let Ok(mut map) = self.pending_keys.lock() {
            for (_, tx) in map.drain() {
                let _ = tx.send(Err(reason.to_string()));
            }
        }
        if let Ok(mut map) = self.pending_mercury.lock() {
            for (_, tx) in map.drain() {
                let _ = tx.send(Err(reason.to_string()));
            }
        }
    }
}

static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

fn sessions() -> &'static Mutex<HashMap<u64, Arc<ApSession>>> {
    static MAP: OnceLock<Mutex<HashMap<u64, Arc<ApSession>>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

fn last_good_ap() -> &'static Mutex<Option<(String, u16)>> {
    static LAST: OnceLock<Mutex<Option<(String, u16)>>> = OnceLock::new();
    LAST.get_or_init(|| Mutex::new(None))
}

fn random_bytes(len: usize) -> Vec<u8> {
    let mut out = vec![0u8; len];
    let mut seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64
        ^ 0x9e3779b97f4a7c15;
    for b in &mut out {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        *b = (seed & 0xff) as u8;
    }
    out
}

async fn resolve_access_points(proxy: &str) -> Result<Vec<(String, u16)>, String> {
    let client = spotify_session::client_for_proxy(proxy)?;
    let res = tokio::time::timeout(
        Duration::from_secs(10),
        client
            .get("https://apresolve.spotify.com/?type=accesspoint")
            .header("Accept", "application/json")
            .send(),
    )
    .await
    .map_err(|_| "apresolve:timeout".to_string())?
    .map_err(|e| format!("apresolve:{e}"))?;
    let body = res.bytes().await.map_err(|e| format!("apresolve_body:{e}"))?;
    let val: Value = serde_json::from_slice(&body).map_err(|e| format!("apresolve_json:{e}"))?;
    let arr = val
        .get("accesspoint")
        .and_then(|v| v.as_array())
        .ok_or_else(|| "apresolve:empty".to_string())?;
    let mut out = Vec::new();
    for item in arr {
        if let Some(s) = item.as_str() {
            if let Some((h, p)) = s.rsplit_once(':') {
                if let Ok(port) = p.parse::<u16>() {
                    out.push((h.to_string(), port));
                }
            }
        }
    }
    if out.is_empty() {
        return Err("apresolve:empty".into());
    }
    out.sort_by_key(|(_, port)| match port {
        4070 => 0,
        443 => 1,
        _ => 2,
    });
    Ok(out)
}

async fn handshake_and_login_one(
    host: &str,
    port: u16,
    proxy: &str,
    username: &str,
    auth_type: i32,
    auth_data: &[u8],
    device_id: &str,
) -> Result<BackendApWelcome, String> {
    let mut stream = tokio::time::timeout(
        Duration::from_secs(10),
        ws::open_tcp(proxy, host, port),
    )
    .await
    .map_err(|_| "ap:connect timeout".to_string())??;

    // 1) ClientHello
    let dh_priv = random_bytes(95);
    let dh_pub = ap_crypto::dh_public_key(&dh_priv)?;
    let nonce = random_bytes(16);

    let mut build_info = Vec::new();
    write_varint(&mut build_info, 10 << 3);
    write_varint(&mut build_info, 0); // PRODUCT_CLIENT
    write_varint(&mut build_info, 20 << 3);
    write_varint(&mut build_info, 0); // PRODUCT_FLAG_NONE
    write_varint(&mut build_info, 30 << 3);
    write_varint(&mut build_info, 0x27); // PLATFORM_WIN32_X86_64
    write_varint(&mut build_info, 40 << 3);
    write_varint(&mut build_info, DESKTOP_BUILD_NUMBER as u64);

    let mut dh_hello = Vec::new();
    write_bytes(&mut dh_hello, 10, &dh_pub);
    write_varint(&mut dh_hello, 20 << 3);
    write_varint(&mut dh_hello, 1);

    let mut login_crypto_hello = Vec::new();
    write_bytes(&mut login_crypto_hello, 10, &dh_hello);

    let mut hello_payload = Vec::new();
    write_bytes(&mut hello_payload, 10, &build_info);
    write_varint(&mut hello_payload, 30 << 3);
    write_varint(&mut hello_payload, 0); // CRYPTO_SUITE_SHANNON
    write_bytes(&mut hello_payload, 50, &login_crypto_hello);
    write_bytes(&mut hello_payload, 60, &nonce);
    write_bytes(&mut hello_payload, 70, &[0x1e]);

    let mut hello_frame = Vec::with_capacity(6 + hello_payload.len());
    hello_frame.extend_from_slice(&[0x00, 0x04]);
    hello_frame.extend_from_slice(&((6 + hello_payload.len()) as u32).to_be_bytes());
    hello_frame.extend_from_slice(&hello_payload);

    stream
        .write_all(&hello_frame)
        .await
        .map_err(|e| format!("ap:write hello:{e}"))?;
    stream
        .flush()
        .await
        .map_err(|e| format!("ap:flush hello:{e}"))?;

    // 2) APResponseMessage
    let mut size_buf = [0u8; 4];
    tokio::time::timeout(Duration::from_secs(10), stream.read_exact(&mut size_buf))
        .await
        .map_err(|_| "ap:handshake read timeout".to_string())?
        .map_err(|e| format!("ap:handshake read:{e}"))?;
    let total_size = u32::from_be_bytes(size_buf) as usize;
    if !(4..=65536).contains(&total_size) {
        return Err(format!("ap:invalid handshake size {total_size}"));
    }
    let mut resp_raw = vec![0u8; total_size];
    resp_raw[0..4].copy_from_slice(&size_buf);
    tokio::time::timeout(
        Duration::from_secs(10),
        stream.read_exact(&mut resp_raw[4..]),
    )
    .await
    .map_err(|_| "ap:handshake body timeout".to_string())?
    .map_err(|e| format!("ap:handshake body:{e}"))?;

    let resp = ProtoMsg::parse(&resp_raw[4..]);
    if resp.has(30) {
        let code = resp.msg(30).integer(10);
        return Err(format!("ap_login:{code}"));
    }
    let dh_challenge = resp.msg(10).msg(10).msg(10);
    let gs = dh_challenge
        .bytes(10)
        .ok_or_else(|| "ap:missing gs".to_string())?;
    let gs_sig = dh_challenge
        .bytes(30)
        .ok_or_else(|| "ap:missing gs_signature".to_string())?;

    if !ap_crypto::rsa_verify_pkcs1_sha1(&AP_SERVER_KEY_MODULUS, gs_sig, gs) {
        return Err("ap:rsa verify failed".into());
    }

    let shared = ap_crypto::dh_shared_secret(&dh_priv, gs);
    let mut accumulated = Vec::with_capacity(hello_frame.len() + resp_raw.len());
    accumulated.extend_from_slice(&hello_frame);
    accumulated.extend_from_slice(&resp_raw);
    let keys = ap_crypto::compute_keys(&shared, &accumulated);

    // 3) ClientResponsePlaintext
    let mut dh_resp = Vec::new();
    write_bytes(&mut dh_resp, 10, &keys.challenge);
    let mut login_crypto_resp = Vec::new();
    write_bytes(&mut login_crypto_resp, 10, &dh_resp);
    let mut plain = Vec::new();
    write_bytes(&mut plain, 10, &login_crypto_resp);
    write_varint(&mut plain, (20 << 3) | 2);
    write_varint(&mut plain, 0);
    write_varint(&mut plain, (30 << 3) | 2);
    write_varint(&mut plain, 0);

    let mut plain_frame = Vec::with_capacity(4 + plain.len());
    plain_frame.extend_from_slice(&((4 + plain.len()) as u32).to_be_bytes());
    plain_frame.extend_from_slice(&plain);
    stream
        .write_all(&plain_frame)
        .await
        .map_err(|e| format!("ap:write plain:{e}"))?;
    stream
        .flush()
        .await
        .map_err(|e| format!("ap:flush plain:{e}"))?;

    // 4) 发送 AP Login 包
    let (reader, writer) = stream.into_split();
    let mut send_state = SendState {
        writer,
        key: keys.send_key,
        nonce: 0,
    };

    let mut creds = Vec::new();
    write_string(&mut creds, 10, username);
    write_varint(&mut creds, 20 << 3);
    write_varint(&mut creds, auth_type as u64);
    write_bytes(&mut creds, 30, auth_data);

    let mut sys_info = Vec::new();
    write_varint(&mut sys_info, 10 << 3);
    write_varint(&mut sys_info, 2); // CPU_X86_64
    write_varint(&mut sys_info, 60 << 3);
    write_varint(&mut sys_info, 1); // OS_WINDOWS
    write_string(&mut sys_info, 100, device_id);

    let mut login_req = Vec::new();
    write_bytes(&mut login_req, 10, &creds);
    write_bytes(&mut login_req, 50, &sys_info);
    write_string(&mut login_req, 70, DESKTOP_VERSION);

    send_state.send_packet(CMD_LOGIN, &login_req).await?;

    // 5) 读取 apWelcome / authFailure
    let mut recv_reader = reader;
    let recv_key = keys.recv_key;
    let mut recv_nonce = 0u32;

    let (canonical_username, reusable_auth_type, reusable_auth) = loop {
        let (cmd, payload) = read_encrypted_packet(&mut recv_reader, &recv_key, recv_nonce).await?;
        recv_nonce = recv_nonce.wrapping_add(1);
        match cmd {
            CMD_PING => {
                send_state.send_packet(CMD_PONG, &payload).await?;
            }
            CMD_AP_WELCOME => {
                let m = ProtoMsg::parse(&payload);
                break (
                    m.str(10).to_string(),
                    m.integer(30) as i32,
                    m.bytes(40).unwrap_or(&[]).to_vec(),
                );
            }
            CMD_AUTH_FAILURE => {
                let m = ProtoMsg::parse(&payload);
                let code = m.integer(10);
                let desc = m.str(20);
                return Err(format!("ap_login:{code}:{desc}"));
            }
            _ => {}
        }
    };

    let session_id = NEXT_SESSION_ID.fetch_add(1, Ordering::Relaxed);
    let session = Arc::new(ApSession {
        send: AsyncMutex::new(send_state),
        key_seq: AtomicU32::new(1),
        mercury_seq: AtomicU64::new(1),
        pending_keys: Mutex::new(HashMap::new()),
        pending_mercury: Mutex::new(HashMap::new()),
        closed: AtomicU32::new(0),
    });

    sessions().lock().unwrap().insert(session_id, session.clone());

    // 启动后台包分发循环
    let bg_session = session.clone();
    tokio::spawn(async move {
        let mut r = recv_reader;
        let mut nonce = recv_nonce;
        loop {
            match read_encrypted_packet(&mut r, &recv_key, nonce).await {
                Ok((cmd, payload)) => {
                    nonce = nonce.wrapping_add(1);
                    handle_ap_packet(&bg_session, cmd, payload).await;
                }
                Err(e) => {
                    bg_session.close_all(&e);
                    break;
                }
            }
        }
    });

    Ok(BackendApWelcome {
        session_id,
        canonical_username,
        reusable_auth_type,
        reusable_auth,
    })
}

async fn read_encrypted_packet(
    reader: &mut OwnedReadHalf,
    key: &[u8],
    nonce: u32,
) -> Result<(u8, Vec<u8>), String> {
    let mut header = [0u8; 3];
    reader
        .read_exact(&mut header)
        .await
        .map_err(|e| format!("ap_read_hdr:{e}"))?;
    let plain_hdr = shannon::decrypt_ap_header(key, nonce, &header)?;
    let size = u16::from_be_bytes([plain_hdr[1], plain_hdr[2]]) as usize;
    let mut body_and_mac = vec![0u8; size + 4];
    reader
        .read_exact(&mut body_and_mac)
        .await
        .map_err(|e| format!("ap_read_body:{e}"))?;
    let (body, mac) = body_and_mac.split_at(size);
    let payload = shannon::decode_ap_packet(key, nonce, &header, body, mac)?;
    Ok((plain_hdr[0], payload))
}

async fn handle_ap_packet(session: &Arc<ApSession>, cmd: u8, payload: Vec<u8>) {
    match cmd {
        CMD_PING => {
            let _ = session.send_packet(CMD_PONG, &payload).await;
        }
        CMD_AES_KEY => {
            if payload.len() >= 20 {
                let seq = u32::from_be_bytes(payload[0..4].try_into().unwrap());
                let key = payload[4..20].to_vec();
                if let Some(tx) = session.pending_keys.lock().unwrap().remove(&seq) {
                    let _ = tx.send(Ok(key));
                }
            }
        }
        CMD_AES_KEY_ERROR => {
            if payload.len() >= 6 {
                let seq = u32::from_be_bytes(payload[0..4].try_into().unwrap());
                let code = u16::from_be_bytes(payload[4..6].try_into().unwrap());
                if let Some(tx) = session.pending_keys.lock().unwrap().remove(&seq) {
                    let _ = tx.send(Err(format!("ap_key_error:{code}")));
                }
            }
        }
        CMD_MERCURY_REQ => {
            if payload.len() < 7 {
                return;
            }
            let seq_len = u16::from_be_bytes([payload[0], payload[1]]) as usize;
            if seq_len != 8 || payload.len() < 2 + seq_len + 3 {
                return;
            }
            let seq = u64::from_be_bytes(payload[2..10].try_into().unwrap());
            let mut off = 2 + seq_len;
            let flags = payload[off];
            off += 1;
            if flags != 1 {
                return;
            }
            let count = u16::from_be_bytes([payload[off], payload[off + 1]]) as usize;
            off += 2;
            let mut parts: Vec<&[u8]> = Vec::with_capacity(count);
            for _ in 0..count {
                if off + 2 > payload.len() {
                    return;
                }
                let len = u16::from_be_bytes([payload[off], payload[off + 1]]) as usize;
                off += 2;
                if off + len > payload.len() {
                    return;
                }
                parts.push(&payload[off..off + len]);
                off += len;
            }
            if parts.is_empty() {
                return;
            }
            let hdr = ProtoMsg::parse(parts[0]);
            let status = if hdr.has(4) {
                let v = hdr.u64_val(4);
                ((v >> 1) as i64) ^ (-((v & 1) as i64))
            } else {
                200
            };
            if let Some(tx) = session.pending_mercury.lock().unwrap().remove(&seq) {
                if status != 200 {
                    let _ = tx.send(Err(format!("ap_mercury:{status}")));
                } else {
                    let mut body = Vec::new();
                    for p in parts.into_iter().skip(1) {
                        body.extend_from_slice(p);
                    }
                    let _ = tx.send(Ok(body));
                }
            }
        }
        _ => {}
    }
}

pub async fn ap_connect_and_login(
    host: Option<String>,
    port: Option<u16>,
    proxy: &str,
    username: &str,
    auth_type: i32,
    auth_data: &[u8],
    device_id: &str,
) -> Result<BackendApWelcome, String> {
    if let (Some(h), Some(p)) = (host.filter(|s| !s.is_empty()), port) {
        return handshake_and_login_one(&h, p, proxy, username, auth_type, auth_data, device_id)
            .await;
    }

    let resolved = resolve_access_points(proxy).await?;
    let last = last_good_ap().lock().unwrap().clone();
    let mut candidates = Vec::new();
    if let Some(ref l) = last {
        candidates.push(l.clone());
    }
    for c in resolved {
        if last.as_ref() != Some(&c) {
            candidates.push(c);
        }
    }

    let mut last_err = String::from("ap:no candidates");
    for (h, p) in candidates.into_iter().take(6) {
        match handshake_and_login_one(&h, p, proxy, username, auth_type, auth_data, device_id)
            .await
        {
            Ok(welcome) => {
                *last_good_ap().lock().unwrap() = Some((h, p));
                return Ok(welcome);
            }
            Err(e) => {
                // 非 TryAnotherAP 的明确登录拒绝不重试其它接入点
                if e.starts_with("ap_login:") && !e.starts_with("ap_login:2:") && e != "ap_login:2" {
                    return Err(e);
                }
                if last.as_ref() == Some(&(h.clone(), p)) {
                    *last_good_ap().lock().unwrap() = None;
                }
                last_err = e;
            }
        }
    }
    Err(last_err)
}

pub async fn ap_request_audio_key(
    session_id: u64,
    file_id: &[u8],
    track_gid: &[u8],
) -> Result<Vec<u8>, String> {
    if file_id.len() != 20 || track_gid.len() != 16 {
        return Err("ap:invalid file_id or track_gid length".into());
    }
    let session = sessions()
        .lock()
        .unwrap()
        .get(&session_id)
        .cloned()
        .ok_or_else(|| "ap:session not found".to_string())?;
    let seq = session.key_seq.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = oneshot::channel();
    session.pending_keys.lock().unwrap().insert(seq, tx);

    let mut payload = Vec::with_capacity(42);
    payload.extend_from_slice(file_id);
    payload.extend_from_slice(track_gid);
    payload.extend_from_slice(&seq.to_be_bytes());
    payload.extend_from_slice(&[0, 0]);

    if let Err(e) = session.send_packet(CMD_REQUEST_KEY, &payload).await {
        session.pending_keys.lock().unwrap().remove(&seq);
        return Err(e);
    }

    match tokio::time::timeout(Duration::from_secs(10), rx).await {
        Ok(Ok(res)) => res,
        Ok(Err(_)) => Err("ap:key channel closed".into()),
        Err(_) => {
            session.pending_keys.lock().unwrap().remove(&seq);
            Err("ap:audio key timeout".into())
        }
    }
}

pub async fn ap_mercury_get(session_id: u64, uri: &str) -> Result<Vec<u8>, String> {
    let session = sessions()
        .lock()
        .unwrap()
        .get(&session_id)
        .cloned()
        .ok_or_else(|| "ap:session not found".to_string())?;
    let seq = session.mercury_seq.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = oneshot::channel();
    session.pending_mercury.lock().unwrap().insert(seq, tx);

    let mut hdr = Vec::new();
    write_string(&mut hdr, 1, uri);
    write_string(&mut hdr, 3, "GET");

    let mut payload = Vec::with_capacity(13 + hdr.len());
    payload.extend_from_slice(&8u16.to_be_bytes());
    payload.extend_from_slice(&seq.to_be_bytes());
    payload.push(1);
    payload.extend_from_slice(&1u16.to_be_bytes());
    payload.extend_from_slice(&(hdr.len() as u16).to_be_bytes());
    payload.extend_from_slice(&hdr);

    if let Err(e) = session.send_packet(CMD_MERCURY_REQ, &payload).await {
        session.pending_mercury.lock().unwrap().remove(&seq);
        return Err(e);
    }

    match tokio::time::timeout(Duration::from_secs(10), rx).await {
        Ok(Ok(res)) => res,
        Ok(Err(_)) => Err("ap:mercury channel closed".into()),
        Err(_) => {
            session.pending_mercury.lock().unwrap().remove(&seq);
            Err("ap:mercury timeout".into())
        }
    }
}

pub fn ap_close(session_id: u64) {
    if let Some(session) = sessions().lock().unwrap().remove(&session_id) {
        session.close_all("ap:closed");
    }
}
