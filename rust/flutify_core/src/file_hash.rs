//! 大文件 SHA-256（更新包校验、缓存迁移核对）：流式读取，不整读进内存。

use std::fs::File;
use std::io::{BufReader, Read};

use sha2::{Digest, Sha256};

/// 文件的 SHA-256（小写十六进制）。
pub fn sha256_file(path: &str) -> Result<String, String> {
    let file = File::open(path).map_err(|e| format!("open {path}: {e}"))?;
    let mut reader = BufReader::with_capacity(1 << 20, file);
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("read {path}: {e}"))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_vectors::{hex, vector};

    #[test]
    fn matches_dart_sha256() {
        let path = std::env::temp_dir().join(format!("flutify_sha_{}.bin", std::process::id()));
        std::fs::write(&path, hex(&vector("packets"))).unwrap();
        let digest = sha256_file(path.to_str().unwrap()).unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(digest, vector("sha256"));
    }

    #[test]
    fn missing_file_is_an_error() {
        assert!(sha256_file("Z:/definitely/missing/file.bin").is_err());
    }
}
