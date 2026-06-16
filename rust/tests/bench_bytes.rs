//! Byte-identity check for the benchmark workloads.
//!
//! Re-derives each of the seven benchmark payloads from `bench/data/<name>.json`
//! using the exact appendX sequence the bench binary (`src/bin/bench.rs`) uses,
//! and asserts the result matches `bench/payloads.json` (byte_len + a real
//! SHA-256). This runs under `cargo test`, so it verifies the bench's
//! correctness without needing to execute the bench binary. It also pins the
//! self-contained SHA-256 against the canonical FIPS-180-4 test vectors.

use std::collections::HashMap;
use std::path::PathBuf;

use struple::Writer;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

// --- minimal JSON tokenizer (mirrors src/bin/bench.rs) ---------------------

struct JsonParser<'a> {
    src: &'a [u8],
    pos: usize,
}
impl<'a> JsonParser<'a> {
    fn new(src: &'a [u8]) -> Self {
        JsonParser { src, pos: 0 }
    }
    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }
    fn bump(&mut self) -> Option<u8> {
        let c = self.peek();
        if c.is_some() {
            self.pos += 1;
        }
        c
    }
    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.pos += 1;
        }
    }
    fn expect(&mut self, c: u8) {
        assert_eq!(self.bump(), Some(c));
    }
    fn parse_string(&mut self) -> String {
        self.expect(b'"');
        let mut out = String::new();
        loop {
            let c = self.bump().expect("unterminated string");
            match c {
                b'"' => break,
                b'\\' => {
                    let e = self.bump().unwrap();
                    out.push(match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'b' => '\u{0008}',
                        b'f' => '\u{000C}',
                        b'u' => {
                            let mut v: u16 = 0;
                            for _ in 0..4 {
                                let d = self.bump().unwrap();
                                let n = match d {
                                    b'0'..=b'9' => d - b'0',
                                    b'a'..=b'f' => d - b'a' + 10,
                                    b'A'..=b'F' => d - b'A' + 10,
                                    _ => panic!("bad hex"),
                                };
                                v = (v << 4) | n as u16;
                            }
                            char::from_u32(v as u32).unwrap()
                        }
                        _ => panic!("bad escape"),
                    });
                }
                _ if c < 0x80 => out.push(c as char),
                _ => {
                    let mut bytes = vec![c];
                    let extra = if c >= 0xF0 {
                        3
                    } else if c >= 0xE0 {
                        2
                    } else {
                        1
                    };
                    for _ in 0..extra {
                        bytes.push(self.bump().unwrap());
                    }
                    out.push_str(std::str::from_utf8(&bytes).unwrap());
                }
            }
        }
        out
    }
}

fn parse_string_array(src: &[u8]) -> Vec<String> {
    let mut p = JsonParser::new(src);
    p.skip_ws();
    p.expect(b'[');
    let mut out = Vec::new();
    p.skip_ws();
    if p.peek() == Some(b']') {
        return out;
    }
    loop {
        p.skip_ws();
        out.push(p.parse_string());
        p.skip_ws();
        match p.bump() {
            Some(b',') => continue,
            Some(b']') => break,
            o => panic!("{o:?}"),
        }
    }
    out
}

fn parse_rows(src: &[u8]) -> Vec<Vec<String>> {
    let mut p = JsonParser::new(src);
    p.skip_ws();
    p.expect(b'[');
    let mut rows = Vec::new();
    p.skip_ws();
    if p.peek() == Some(b']') {
        return rows;
    }
    loop {
        p.skip_ws();
        p.expect(b'[');
        let mut row = Vec::new();
        p.skip_ws();
        if p.peek() == Some(b']') {
            p.bump();
        } else {
            loop {
                p.skip_ws();
                row.push(p.parse_string());
                p.skip_ws();
                match p.bump() {
                    Some(b',') => continue,
                    Some(b']') => break,
                    o => panic!("{o:?}"),
                }
            }
        }
        rows.push(row);
        p.skip_ws();
        match p.bump() {
            Some(b',') => continue,
            Some(b']') => break,
            o => panic!("{o:?}"),
        }
    }
    rows
}

// --- typed-string field decode ---------------------------------------------

fn f64_from_hex(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap())
}
fn digits_from_str(s: &str) -> Vec<u8> {
    s.bytes().map(|b| b - b'0').collect()
}
fn bytes_from_hex(h: &str) -> Vec<u8> {
    let b = h.as_bytes();
    let nib = |c: u8| match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        b'A'..=b'F' => c - b'A' + 10,
        _ => panic!("bad nibble"),
    };
    (0..b.len() / 2).map(|i| (nib(b[2 * i]) << 4) | nib(b[2 * i + 1])).collect()
}
fn i128_from_hex(h: &str) -> i128 {
    bytes_from_hex(h).into_iter().fold(0i128, |v, b| (v << 8) | b as i128)
}

// --- canonical builders (the bench's encode_once sequences) ----------------

fn data_dir() -> PathBuf {
    repo_root().join("bench").join("data")
}
fn load(name: &str) -> Vec<u8> {
    std::fs::read(data_dir().join(format!("{name}.json"))).unwrap()
}

fn build_stock_quotes() -> Vec<u8> {
    let mut out = Writer::new();
    let mut sc = Writer::new();
    for r in parse_rows(&load("stock_quotes")) {
        sc.clear();
        sc.append_string(&r[0]);
        sc.append_decimal(false, &digits_from_str(&r[1]), r[2].parse().unwrap());
        sc.append_decimal(false, &digits_from_str(&r[3]), r[4].parse().unwrap());
        sc.append_f64(f64_from_hex(&r[5]));
        sc.append_int(r[6].parse().unwrap());
        sc.append_timestamp(r[7].parse().unwrap());
        out.append_array(sc.bytes());
    }
    out.into_bytes()
}

fn build_geo_points() -> Vec<u8> {
    let mut out = Writer::new();
    let mut sc = Writer::new();
    for r in parse_rows(&load("geo_points")) {
        sc.clear();
        sc.append_f64(f64_from_hex(&r[0]));
        sc.append_f64(f64_from_hex(&r[1]));
        sc.append_f64(f64_from_hex(&r[2]));
        sc.append_string(&r[3]);
        sc.append_timestamp(r[4].parse().unwrap());
        out.append_array(sc.bytes());
    }
    out.into_bytes()
}

fn build_tweets() -> Vec<u8> {
    let mut out = Writer::new();
    let mut sc = Writer::new();
    for r in parse_rows(&load("tweets")) {
        sc.clear();
        sc.append_int(r[0].parse().unwrap());
        sc.append_string(&r[1]);
        sc.append_string(&r[2]);
        sc.append_timestamp(r[3].parse().unwrap());
        sc.append_int(r[4].parse().unwrap());
        sc.append_int(r[5].parse().unwrap());
        out.append_array(sc.bytes());
    }
    out.into_bytes()
}

fn build_blockchain_txs() -> Vec<u8> {
    let mut out = Writer::new();
    let mut sc = Writer::new();
    for r in parse_rows(&load("blockchain_txs")) {
        sc.clear();
        sc.append_int(r[0].parse().unwrap());
        sc.append_bytes(&bytes_from_hex(&r[1]));
        sc.append_bytes(&bytes_from_hex(&r[2]));
        sc.append_bytes(&bytes_from_hex(&r[3]));
        match r[4].as_str() {
            "big" => {
                sc.append_big_int(false, &bytes_from_hex(&r[5]));
            }
            "fix" => {
                sc.append_int(i128_from_hex(&r[5]));
            }
            o => panic!("bad kind {o}"),
        }
        sc.append_int(r[6].parse().unwrap());
        sc.append_int(r[7].parse().unwrap());
        sc.append_timestamp(r[8].parse().unwrap());
        out.append_array(sc.bytes());
    }
    out.into_bytes()
}

fn build_int_stream() -> Vec<u8> {
    let mut out = Writer::new();
    for s in parse_string_array(&load("int_stream")) {
        out.append_int(s.parse().unwrap());
    }
    out.into_bytes()
}

fn build_string_stream() -> Vec<u8> {
    let mut out = Writer::new();
    for s in parse_string_array(&load("string_stream")) {
        out.append_string(&s);
    }
    out.into_bytes()
}

fn enc_str(s: &str) -> Vec<u8> {
    let mut w = Writer::new();
    w.append_string(s);
    w.into_bytes()
}
fn enc_int(v: i128) -> Vec<u8> {
    let mut w = Writer::new();
    w.append_int(v);
    w.into_bytes()
}
fn enc_bool(v: bool) -> Vec<u8> {
    let mut w = Writer::new();
    w.append_bool(v);
    w.into_bytes()
}

fn build_nested_doc() -> Vec<u8> {
    let (k_active, k_scores, k_user, k_id, k_name) =
        (enc_str("active"), enc_str("scores"), enc_str("user"), enc_str("id"), enc_str("name"));
    let mut out = Writer::new();
    for r in parse_rows(&load("nested_doc")) {
        let active = r[0] == "1";
        let uid: i128 = r[1].parse().unwrap();
        let name = &r[2];
        let scores: [i128; 3] = [r[3].parse().unwrap(), r[4].parse().unwrap(), r[5].parse().unwrap()];

        let mut user = Writer::new();
        user.append_map(&[(k_id.clone(), enc_int(uid)), (k_name.clone(), enc_str(name))]);
        let mut scores_inner = Writer::new();
        scores_inner.append_int(scores[0]);
        scores_inner.append_int(scores[1]);
        scores_inner.append_int(scores[2]);
        let mut scores_arr = Writer::new();
        scores_arr.append_array(scores_inner.bytes());
        out.append_map(&[
            (k_active.clone(), enc_bool(active)),
            (k_scores.clone(), scores_arr.into_bytes()),
            (k_user.clone(), user.into_bytes()),
        ]);
    }
    out.into_bytes()
}

// --- SHA-256 (same impl as the bench) --------------------------------------

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

fn sha256_hex(msg: &[u8]) -> String {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut data = msg.to_vec();
    let bit_len = (msg.len() as u64).wrapping_mul(8);
    data.push(0x80);
    while data.len() % 64 != 56 {
        data.push(0);
    }
    data.extend_from_slice(&bit_len.to_be_bytes());

    for block in data.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(block[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ ((!v[4]) & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for i in 0..8 {
            h[i] = h[i].wrapping_add(v[i]);
        }
    }
    let mut s = String::new();
    for word in h {
        s.push_str(&format!("{word:08x}"));
    }
    s
}

// --- manifest -------------------------------------------------------------

fn read_manifest() -> HashMap<String, (usize, String)> {
    let text = std::fs::read_to_string(repo_root().join("bench").join("payloads.json")).unwrap();
    let mut map = HashMap::new();
    let mut search = text.as_str();
    while let Some(p) = search.find("\"name\"") {
        let block = &search[p..];
        let field_str = |key: &str| -> Option<String> {
            let pat = format!("\"{key}\"");
            let k = block.find(&pat)?;
            let after = &block[k + pat.len()..];
            let colon = after.find(':')?;
            let rest = &after[colon + 1..];
            let q1 = rest.find('"')?;
            let tail = &rest[q1 + 1..];
            let q2 = tail.find('"')?;
            Some(tail[..q2].to_string())
        };
        let field_num = |key: &str| -> Option<usize> {
            let pat = format!("\"{key}\"");
            let k = block.find(&pat)?;
            let after = &block[k + pat.len()..];
            let colon = after.find(':')?;
            let rest = after[colon + 1..].trim_start();
            let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
            rest[..end].parse().ok()
        };
        let name = field_str("name").unwrap();
        let bl = field_num("byte_len").unwrap();
        let sha = field_str("sha256").unwrap();
        map.insert(name, (bl, sha));
        search = &block[6..];
    }
    map
}

// --- the tests --------------------------------------------------------------

#[test]
fn sha256_known_vectors() {
    assert_eq!(
        sha256_hex(b""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    assert_eq!(
        sha256_hex(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        sha256_hex(b"The quick brown fox jumps over the lazy dog"),
        "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
    );
    // 1,000,000 'a' (FIPS appendix B.3)
    let a = vec![b'a'; 1_000_000];
    assert_eq!(
        sha256_hex(&a),
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    );
}

#[test]
fn bench_payloads_are_byte_identical() {
    let manifest = read_manifest();
    let builders: &[(&str, fn() -> Vec<u8>)] = &[
        ("stock_quotes", build_stock_quotes),
        ("geo_points", build_geo_points),
        ("tweets", build_tweets),
        ("blockchain_txs", build_blockchain_txs),
        ("int_stream", build_int_stream),
        ("string_stream", build_string_stream),
        ("nested_doc", build_nested_doc),
    ];
    assert_eq!(builders.len(), 7);
    for (name, build) in builders {
        let bytes = build();
        let (exp_len, exp_sha) = manifest.get(*name).unwrap_or_else(|| panic!("missing {name}"));
        assert_eq!(bytes.len(), *exp_len, "{name}: byte_len mismatch");
        assert_eq!(&sha256_hex(&bytes), exp_sha, "{name}: sha256 mismatch");
        // also stable across a re-encode
        assert_eq!(build(), bytes, "{name}: not deterministic");
    }
}
