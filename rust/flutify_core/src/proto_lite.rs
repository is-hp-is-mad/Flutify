//! 轻量级 Protobuf 编解码与树形只读解析器（供 collection、watchfeed、AP/Mercury、storage-resolve 共用）。

use std::collections::HashMap;

#[derive(Debug, Clone)]
pub enum ProtoVal<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
}

/// 只读 Protobuf 消息树：宽松解析，损坏字节处截断，绝不 panic。
#[derive(Debug, Clone, Default)]
pub struct ProtoMsg<'a> {
    fields: HashMap<u32, Vec<ProtoVal<'a>>>,
}

impl<'a> ProtoMsg<'a> {
    pub fn parse(data: &'a [u8]) -> Self {
        let mut fields: HashMap<u32, Vec<ProtoVal<'a>>> = HashMap::new();
        let mut pos = 0usize;
        while pos < data.len() {
            let Some((tag, p1)) = read_varint(data, pos) else {
                break;
            };
            pos = p1;
            let field_num = (tag >> 3) as u32;
            let wire_type = (tag & 0x07) as u8;
            if field_num == 0 {
                break;
            }
            match wire_type {
                0 => {
                    let Some((v, p2)) = read_varint(data, pos) else {
                        break;
                    };
                    pos = p2;
                    fields.entry(field_num).or_default().push(ProtoVal::Varint(v));
                }
                1 => {
                    if pos + 8 > data.len() {
                        break;
                    }
                    let v = u64::from_le_bytes(data[pos..pos + 8].try_into().unwrap());
                    pos += 8;
                    fields.entry(field_num).or_default().push(ProtoVal::Varint(v));
                }
                2 => {
                    let Some((len, p2)) = read_varint(data, pos) else {
                        break;
                    };
                    let len = len as usize;
                    if p2 + len > data.len() {
                        break;
                    }
                    let slice = &data[p2..p2 + len];
                    pos = p2 + len;
                    fields.entry(field_num).or_default().push(ProtoVal::Bytes(slice));
                }
                5 => {
                    if pos + 4 > data.len() {
                        break;
                    }
                    let v = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap()) as u64;
                    pos += 4;
                    fields.entry(field_num).or_default().push(ProtoVal::Varint(v));
                }
                _ => break,
            }
        }
        Self { fields }
    }

    pub fn has(&self, number: u32) -> bool {
        self.fields.contains_key(&number)
    }

    pub fn str(&self, number: u32) -> &'a str {
        self.bytes(number)
            .and_then(|b| std::str::from_utf8(b).ok())
            .unwrap_or("")
    }

    pub fn strs(&self, number: u32) -> Vec<&'a str> {
        self.all_bytes(number)
            .into_iter()
            .filter_map(|b| std::str::from_utf8(b).ok())
            .collect()
    }

    pub fn integer(&self, number: u32) -> i64 {
        let Some(list) = self.fields.get(&number) else {
            return 0;
        };
        for item in list.iter().rev() {
            if let ProtoVal::Varint(v) = item {
                return *v as i64;
            }
        }
        0
    }

    pub fn u64_val(&self, number: u32) -> u64 {
        let Some(list) = self.fields.get(&number) else {
            return 0;
        };
        for item in list.iter().rev() {
            if let ProtoVal::Varint(v) = item {
                return *v;
            }
        }
        0
    }

    pub fn flag(&self, number: u32) -> bool {
        self.integer(number) != 0
    }

    pub fn bytes(&self, number: u32) -> Option<&'a [u8]> {
        let list = self.fields.get(&number)?;
        for item in list.iter().rev() {
            if let ProtoVal::Bytes(b) = item {
                return Some(b);
            }
        }
        None
    }

    pub fn all_bytes(&self, number: u32) -> Vec<&'a [u8]> {
        let Some(list) = self.fields.get(&number) else {
            return Vec::new();
        };
        list.iter()
            .filter_map(|item| match item {
                ProtoVal::Bytes(b) => Some(*b),
                ProtoVal::Varint(_) => None,
            })
            .collect()
    }

    pub fn msg(&self, number: u32) -> ProtoMsg<'a> {
        self.bytes(number).map(ProtoMsg::parse).unwrap_or_default()
    }

    pub fn msgs(&self, number: u32) -> Vec<ProtoMsg<'a>> {
        self.all_bytes(number)
            .into_iter()
            .map(ProtoMsg::parse)
            .collect()
    }

    pub fn any(&self, number: u32) -> Option<ProtoAny<'a>> {
        if !self.has(number) {
            return None;
        }
        let m = self.msg(number);
        let type_url = m.str(1);
        if type_url.is_empty() {
            return None;
        }
        Some(ProtoAny {
            type_url,
            value: m.msg(2),
        })
    }

    pub fn anys(&self, number: u32) -> Vec<ProtoAny<'a>> {
        self.msgs(number)
            .into_iter()
            .filter_map(|m| {
                let type_url = m.str(1);
                if type_url.is_empty() {
                    None
                } else {
                    Some(ProtoAny {
                        type_url,
                        value: m.msg(2),
                    })
                }
            })
            .collect()
    }
}

#[derive(Debug, Clone)]
pub struct ProtoAny<'a> {
    pub type_url: &'a str,
    pub value: ProtoMsg<'a>,
}

impl<'a> ProtoAny<'a> {
    pub fn short_type(&self) -> &'a str {
        let idx = self.type_url.rfind(['.', '/']);
        match idx {
            Some(i) => &self.type_url[i + 1..],
            None => self.type_url,
        }
    }
}

pub fn read_varint(data: &[u8], mut pos: usize) -> Option<(u64, usize)> {
    let mut val = 0u64;
    let mut shift = 0u32;
    while pos < data.len() && shift < 64 {
        let b = data[pos];
        pos += 1;
        val |= ((b & 0x7F) as u64) << shift;
        if b & 0x80 == 0 {
            return Some((val, pos));
        }
        shift += 7;
    }
    None
}

pub fn write_varint(out: &mut Vec<u8>, mut val: u64) {
    loop {
        let mut byte = (val & 0x7F) as u8;
        val >>= 7;
        if val != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if val == 0 {
            break;
        }
    }
}

pub fn write_bytes(out: &mut Vec<u8>, field: u32, data: &[u8]) {
    if data.is_empty() {
        return;
    }
    write_varint(out, ((field as u64) << 3) | 2);
    write_varint(out, data.len() as u64);
    out.extend_from_slice(data);
}

pub fn write_string(out: &mut Vec<u8>, field: u32, s: &str) {
    write_bytes(out, field, s.as_bytes());
}

pub fn write_int32(out: &mut Vec<u8>, field: u32, v: i32) {
    write_varint(out, (field as u64) << 3);
    write_varint(out, v as u64);
}

pub fn write_bool(out: &mut Vec<u8>, field: u32, v: bool) {
    if !v {
        return;
    }
    write_varint(out, (field as u64) << 3);
    out.push(1);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_any_short_type() {
        let mut inner = Vec::new();
        write_string(&mut inner, 1, "hello");
        write_int32(&mut inner, 2, 42);

        let mut any_msg = Vec::new();
        write_string(&mut any_msg, 1, "type.googleapis.com/spotify.watchfeed.Hashtag");
        write_bytes(&mut any_msg, 2, &inner);

        let mut outer = Vec::new();
        write_bytes(&mut outer, 3, &any_msg);

        let parsed = ProtoMsg::parse(&outer);
        let any = parsed.any(3).expect("any");
        assert_eq!(any.short_type(), "Hashtag");
        assert_eq!(any.value.str(1), "hello");
        assert_eq!(any.value.integer(2), 42);
    }
}
