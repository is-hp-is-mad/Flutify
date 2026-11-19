//! 本地音频缓存目录体积统计、清空与按最近修改时间 LRU 淘汰（原生 std::fs）。

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

const NORM_SIDECAR_EXT: &str = "norm";

fn normalize_path_set(paths: &[String]) -> HashSet<PathBuf> {
    paths
        .iter()
        .map(|p| {
            let pb = PathBuf::from(p);
            fs::canonicalize(&pb).unwrap_or(pb)
        })
        .collect()
}

fn is_protected(path: &Path, protected: &HashSet<PathBuf>) -> bool {
    if protected.is_empty() {
        return false;
    }
    if protected.contains(path) {
        return true;
    }
    if let Ok(canon) = fs::canonicalize(path) {
        return protected.contains(&canon);
    }
    false
}

fn sidecar_for(path: &Path) -> PathBuf {
    let mut os = path.as_os_str().to_os_string();
    os.push(".");
    os.push(NORM_SIDECAR_EXT);
    PathBuf::from(os)
}

fn is_sidecar_or_part(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
        return false;
    };
    name.ends_with(".part") || name.ends_with(&format!(".{NORM_SIDECAR_EXT}"))
}

/// 统计缓存目录总字节数（出错时返回 0）。
pub fn cache_size_bytes(dir_path: &str) -> u64 {
    let dir = Path::new(dir_path);
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    let mut total = 0u64;
    for entry in entries.flatten() {
        if let Ok(meta) = entry.metadata() {
            if meta.is_file() {
                total += meta.len();
            }
        }
    }
    total
}

/// 清空缓存目录（跳过受保护路径及正在使用的文件），返回释放字节数。
pub fn clear_cache(dir_path: &str, protected_paths: &[String]) -> u64 {
    let dir = Path::new(dir_path);
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    let protected = normalize_path_set(protected_paths);
    let mut freed = 0u64;

    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if !meta.is_file() || is_sidecar_or_part(&path) {
            continue;
        }
        if is_protected(&path, &protected) {
            continue;
        }
        let size = meta.len();
        if fs::remove_file(&path).is_ok() {
            freed += size;
            let sidecar = sidecar_for(&path);
            if let Ok(sm) = fs::metadata(&sidecar) {
                let s_len = sm.len();
                if fs::remove_file(&sidecar).is_ok() {
                    freed += s_len;
                }
            }
        }
    }
    freed
}

/// 当音频总字节数超过 `max_bytes` 时按 mtime 从旧到新删除（同步删除 `.norm` 旁路文件）。
pub fn trim_cache(dir_path: &str, max_bytes: u64, protected_paths: &[String]) -> u64 {
    let dir = Path::new(dir_path);
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    let mut files: Vec<(PathBuf, u64, SystemTime)> = Vec::new();
    let mut total = 0u64;

    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if !meta.is_file() || is_sidecar_or_part(&path) {
            continue;
        }
        let len = meta.len();
        let modified = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        total += len;
        files.push((path, len, modified));
    }

    if total <= max_bytes {
        return 0;
    }

    files.sort_by_key(|a| a.2);
    let protected = normalize_path_set(protected_paths);
    let mut freed = 0u64;

    for (path, len, _) in files {
        if total <= max_bytes {
            break;
        }
        if is_protected(&path, &protected) {
            continue;
        }
        if fs::remove_file(&path).is_ok() {
            total = total.saturating_sub(len);
            freed += len;
            let sidecar = sidecar_for(&path);
            if let Ok(sm) = fs::metadata(&sidecar) {
                let s_len = sm.len();
                if fs::remove_file(&sidecar).is_ok() {
                    freed += s_len;
                }
            }
        }
    }
    freed
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn trim_evicts_oldest_and_sidecar_and_respects_protected() {
        let tmp = std::env::temp_dir().join(format!("flutify_cache_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();

        let f1 = tmp.join("a.ogg");
        let f1_norm = tmp.join("a.ogg.norm");
        let f2 = tmp.join("b.ogg");
        let f3 = tmp.join("c.ogg");

        fs::write(&f1, vec![1u8; 100]).unwrap();
        fs::write(&f1_norm, vec![2u8; 8]).unwrap();
        thread::sleep(Duration::from_millis(25));
        fs::write(&f2, vec![3u8; 100]).unwrap();
        thread::sleep(Duration::from_millis(25));
        fs::write(&f3, vec![4u8; 100]).unwrap();

        // 保护 f1，因此淘汰次旧的 f2
        let freed = trim_cache(
            tmp.to_str().unwrap(),
            200,
            &[f1.to_str().unwrap().to_string()],
        );
        assert_eq!(freed, 100);
        assert!(f1.exists());
        assert!(f1_norm.exists());
        assert!(!f2.exists());
        assert!(f3.exists());

        // 不保护 f1，淘汰最旧的 f1 及其旁路文件 f1_norm
        let freed2 = trim_cache(tmp.to_str().unwrap(), 100, &[]);
        assert_eq!(freed2, 108);
        assert!(!f1.exists());
        assert!(!f1_norm.exists());
        assert!(f3.exists());

        let _ = fs::remove_dir_all(&tmp);
    }
}
