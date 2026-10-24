//! 测试用：从 tests/fixtures/ap_vectors.txt 读取 Dart 实现生成的对照向量（`名称=十六进制`）。

const FIXTURE: &str = include_str!("../tests/fixtures/ap_vectors.txt");

pub fn vector(name: &str) -> String {
    FIXTURE
        .lines()
        .find_map(|line| line.trim().strip_prefix(&format!("{name}=")).map(str::to_string))
        .unwrap_or_else(|| panic!("missing vector {name}"))
}

pub fn hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}
