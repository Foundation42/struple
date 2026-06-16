//! struple reference benchmark (Rust).
//!
//! Mirrors bench/zig/bench.zig and bench/js/bench.ts: encode (build a framed
//! stream from prepared in-memory records) and decode (walk the whole stream,
//! descending and un-escaping every container body and touching every scalar)
//! throughput for the seven shared workloads — four realistic streaming shapes
//! (stock quotes, geospatial points, tweets, blockchain transactions) plus three
//! structural micro-benchmarks (an integer stream, a string stream, a nested
//! document).
//!
//! The native records are parsed from bench/data/<name>.json once (setup,
//! untimed); the encoder then rebuilds the bytes with the same appendX sequence
//! the Zig/TS references use. Byte-identity is verified against
//! bench/payloads.json (sha256 + byte_len, real SHA-256) before any throughput
//! figure is reported.
//!
//! Methodology (per (payload, op)): 5 warm-up runs, auto-calibrate the iteration
//! count to a ~100 ms trial, then 9 trials — the MEDIAN ns/op is reported. A
//! global checksum sink (drained through std::hint::black_box) defeats dead-code
//! elimination. Steady-state buffers retain capacity. Single-threaded.
//!
//! Zero dependencies beyond std (a tiny self-contained JSON tokenizer reads the
//! arrays-of-strings data; a tiny self-contained SHA-256 verifies byte-identity).
//!
//! Run:  cargo run --release --bin bench   (--release is mandatory)

use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::time::Instant;

use struple::{Element, Reader, Writer};

// ---------------------------------------------------------------------------
// DCE sink — every measured op folds something into this (wrapping u64, exactly
// like the Zig `g_sink: u64`); printed at the end behind black_box so the
// optimizer must actually perform the work.
// ---------------------------------------------------------------------------
static mut G_SINK: u64 = 0;

#[inline(always)]
fn sink(v: u64) {
    // Single-threaded benchmark; the static is touched only from main's thread.
    unsafe {
        G_SINK = G_SINK.wrapping_add(v);
    }
}

// ---------------------------------------------------------------------------
// Native record shapes (parsed once from the shared JSON data).
// ---------------------------------------------------------------------------

/// A price as an exact decimal: coefficient digits (MSD-first, each 0–9) · 10^exp.
struct Dec {
    digits: Vec<u8>,
    exp: i32,
}

struct Quote {
    symbol: String,
    bid: Dec,
    ask: Dec,
    last: f64,
    volume: i128,
    ts: i64, // µs since epoch
}

struct Geo {
    lat: f64,
    lon: f64,
    elevation: f64,
    name: String,
    ts: i64,
}

struct Tweet {
    id: i128, // u64 id (fits the i128 fixed path)
    user: String,
    text: String,
    created_at: i64,
    likes: i128,
    retweets: i128,
}

/// Blockchain value: `big` magnitudes exceed i128 (use the big-int code), `fix`
/// magnitudes fit i128 (use the fixed integer path) — exactly the Zig
/// appendBigInt / appendI128 split, keyed by the data's "big"|"fix" tag.
enum TxValue {
    Big(Vec<u8>), // big-endian magnitude (as decoded from hex)
    Fix(i128),
}

struct Tx {
    height: i128,
    tx_hash: Vec<u8>, // 32 bytes
    from: Vec<u8>,    // 20 bytes
    to: Vec<u8>,      // 20 bytes
    value: TxValue,
    gas: i128,
    nonce: i128,
    ts: i64,
}

struct Nested {
    uid: i128,
    name: String,
    active: bool,
    scores: [i128; 3],
}

struct Data {
    quotes: Vec<Quote>,
    geo: Vec<Geo>,
    tweets: Vec<Tweet>,
    txs: Vec<Tx>,
    ints: Vec<i128>,
    strings: Vec<String>,
    nested: Vec<Nested>,
}

#[derive(Clone, Copy, PartialEq)]
enum PKind {
    Quotes,
    Geo,
    Tweets,
    Txs,
    Ints,
    Strings,
    Nested,
}

struct PayloadMeta {
    kind: PKind,
    name: &'static str,
    /// "streaming" | "structural" — kept for parity with the reference manifest
    /// (the category split is documented in bench/README.md).
    #[allow(dead_code)]
    category: &'static str,
}

const PAYLOADS: &[PayloadMeta] = &[
    PayloadMeta { kind: PKind::Quotes, name: "stock_quotes", category: "streaming" },
    PayloadMeta { kind: PKind::Geo, name: "geo_points", category: "streaming" },
    PayloadMeta { kind: PKind::Tweets, name: "tweets", category: "streaming" },
    PayloadMeta { kind: PKind::Txs, name: "blockchain_txs", category: "streaming" },
    PayloadMeta { kind: PKind::Ints, name: "int_stream", category: "structural" },
    PayloadMeta { kind: PKind::Strings, name: "string_stream", category: "structural" },
    PayloadMeta { kind: PKind::Nested, name: "nested_doc", category: "structural" },
];

// ---------------------------------------------------------------------------
// Tiny self-contained JSON tokenizer — handles exactly the structure the shared
// data uses: arrays (possibly nested one level) of JSON strings. Standard string
// escapes are honored so it stays correct even though the current corpus is
// plain ASCII. Zero dependencies (no serde).
// ---------------------------------------------------------------------------

/// Parse a top-level JSON array of strings: `["a","b",...]`.
fn parse_string_array(src: &[u8]) -> Vec<String> {
    let mut p = JsonParser::new(src);
    p.skip_ws();
    p.expect(b'[');
    let mut out = Vec::new();
    p.skip_ws();
    if p.peek() == Some(b']') {
        p.bump();
        return out;
    }
    loop {
        p.skip_ws();
        out.push(p.parse_string());
        p.skip_ws();
        match p.bump() {
            Some(b',') => continue,
            Some(b']') => break,
            other => panic!("parse_string_array: expected ',' or ']', got {other:?}"),
        }
    }
    out
}

/// Parse a top-level JSON array of arrays of strings: `[["a","b"],["c"],...]`.
fn parse_rows(src: &[u8]) -> Vec<Vec<String>> {
    let mut p = JsonParser::new(src);
    p.skip_ws();
    p.expect(b'[');
    let mut rows = Vec::new();
    p.skip_ws();
    if p.peek() == Some(b']') {
        p.bump();
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
                    other => panic!("parse_rows: expected ',' or ']' in row, got {other:?}"),
                }
            }
        }
        rows.push(row);
        p.skip_ws();
        match p.bump() {
            Some(b',') => continue,
            Some(b']') => break,
            other => panic!("parse_rows: expected ',' or ']', got {other:?}"),
        }
    }
    rows
}

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
        while let Some(c) = self.peek() {
            if c == b' ' || c == b'\n' || c == b'\r' || c == b'\t' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }
    fn expect(&mut self, c: u8) {
        match self.bump() {
            Some(g) if g == c => {}
            other => panic!("expected {:?}, got {other:?}", c as char),
        }
    }
    /// Parse a JSON string literal (the cursor must be at the opening quote).
    fn parse_string(&mut self) -> String {
        self.expect(b'"');
        let mut out = String::new();
        loop {
            let c = self.bump().expect("unterminated string");
            match c {
                b'"' => break,
                b'\\' => {
                    let e = self.bump().expect("unterminated escape");
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let cp = self.parse_hex4();
                            // No surrogate pairs in the corpus; the emitter only
                            // escapes control chars (< 0x20) as \uXXXX.
                            out.push(char::from_u32(cp as u32).unwrap_or('\u{FFFD}'));
                        }
                        other => panic!("bad escape \\{}", other as char),
                    }
                }
                _ => {
                    // Multi-byte UTF-8: collect the continuation bytes verbatim.
                    if c < 0x80 {
                        out.push(c as char);
                    } else {
                        let mut bytes = vec![c];
                        let extra = if c >= 0xF0 {
                            3
                        } else if c >= 0xE0 {
                            2
                        } else {
                            1
                        };
                        for _ in 0..extra {
                            bytes.push(self.bump().expect("truncated utf-8"));
                        }
                        out.push_str(std::str::from_utf8(&bytes).expect("invalid utf-8"));
                    }
                }
            }
        }
        out
    }
    fn parse_hex4(&mut self) -> u16 {
        let mut v: u16 = 0;
        for _ in 0..4 {
            let d = self.bump().expect("truncated \\u escape");
            let n = match d {
                b'0'..=b'9' => d - b'0',
                b'a'..=b'f' => d - b'a' + 10,
                b'A'..=b'F' => d - b'A' + 10,
                _ => panic!("bad hex digit in \\u"),
            };
            v = (v << 4) | n as u16;
        }
        v
    }
}

// ---------------------------------------------------------------------------
// Typed-string field decoding (see bench/README.md — all data fields are typed
// strings so any JSON reader reads them identically across languages).
// ---------------------------------------------------------------------------

/// 16 hex digits of the IEEE-754 bits (big-endian) → f64.
fn f64_from_hex(hex: &str) -> f64 {
    let bits = u64::from_str_radix(hex, 16).expect("bad f64 hex");
    f64::from_bits(bits)
}

/// Digit string "12345" → [1,2,3,4,5] (each 0–9).
fn digits_from_str(s: &str) -> Vec<u8> {
    s.bytes().map(|b| b - b'0').collect()
}

/// Hex string (even length) → bytes.
fn bytes_from_hex(hex: &str) -> Vec<u8> {
    let b = hex.as_bytes();
    let mut out = Vec::with_capacity(b.len() / 2);
    let mut i = 0;
    while i + 1 < b.len() {
        out.push((hex_nibble(b[i]) << 4) | hex_nibble(b[i + 1]));
        i += 2;
    }
    out
}

fn hex_nibble(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        b'A'..=b'F' => c - b'A' + 10,
        _ => panic!("bad hex nibble"),
    }
}

/// big-endian hex magnitude → i128 (for the `fix` blockchain path, ≤15 bytes).
fn i128_from_hex(hex: &str) -> i128 {
    let mut v: i128 = 0;
    for b in bytes_from_hex(hex) {
        v = (v << 8) | b as i128;
    }
    v
}

fn parse_i64(s: &str) -> i64 {
    s.parse::<i64>().expect("bad i64")
}
fn parse_i128(s: &str) -> i128 {
    s.parse::<i128>().expect("bad i128")
}

// ---------------------------------------------------------------------------
// Read all seven workloads from bench/data/*.json (untimed setup).
// ---------------------------------------------------------------------------

fn read_data(data_dir: &Path) -> Data {
    let load = |name: &str| -> Vec<u8> {
        let path = data_dir.join(format!("{name}.json"));
        std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
    };

    let quotes = parse_rows(&load("stock_quotes"))
        .into_iter()
        .map(|r| Quote {
            symbol: r[0].clone(),
            bid: Dec { digits: digits_from_str(&r[1]), exp: r[2].parse().expect("bid exp") },
            ask: Dec { digits: digits_from_str(&r[3]), exp: r[4].parse().expect("ask exp") },
            last: f64_from_hex(&r[5]),
            volume: parse_i128(&r[6]),
            ts: parse_i64(&r[7]),
        })
        .collect();

    let geo = parse_rows(&load("geo_points"))
        .into_iter()
        .map(|r| Geo {
            lat: f64_from_hex(&r[0]),
            lon: f64_from_hex(&r[1]),
            elevation: f64_from_hex(&r[2]),
            name: r[3].clone(),
            ts: parse_i64(&r[4]),
        })
        .collect();

    let tweets = parse_rows(&load("tweets"))
        .into_iter()
        .map(|r| Tweet {
            id: parse_i128(&r[0]), // u64, fits the i128 fixed path
            user: r[1].clone(),
            text: r[2].clone(),
            created_at: parse_i64(&r[3]),
            likes: parse_i128(&r[4]),
            retweets: parse_i128(&r[5]),
        })
        .collect();

    let txs = parse_rows(&load("blockchain_txs"))
        .into_iter()
        .map(|r| {
            // r[4] is "big"|"fix"; r[5] is the big-endian hex magnitude.
            let value = match r[4].as_str() {
                "big" => TxValue::Big(bytes_from_hex(&r[5])),
                "fix" => TxValue::Fix(i128_from_hex(&r[5])),
                other => panic!("bad value kind {other}"),
            };
            Tx {
                height: parse_i128(&r[0]),
                tx_hash: bytes_from_hex(&r[1]),
                from: bytes_from_hex(&r[2]),
                to: bytes_from_hex(&r[3]),
                value,
                gas: parse_i128(&r[6]),
                nonce: parse_i128(&r[7]),
                ts: parse_i64(&r[8]),
            }
        })
        .collect();

    let ints = parse_string_array(&load("int_stream"))
        .iter()
        .map(|s| parse_i128(s))
        .collect();

    let strings = parse_string_array(&load("string_stream"));

    let nested = parse_rows(&load("nested_doc"))
        .into_iter()
        .map(|r| Nested {
            active: r[0] == "1",
            uid: parse_i128(&r[1]),
            name: r[2].clone(),
            scores: [parse_i128(&r[3]), parse_i128(&r[4]), parse_i128(&r[5])],
        })
        .collect();

    Data { quotes, geo, tweets, txs, ints, strings, nested }
}

// ---------------------------------------------------------------------------
// Encoders — one per payload kind. `out` is cleared by the caller each iteration
// (retaining capacity); a single reused `scratch` Writer frames one record at a
// time, also cleared between records (the README's "reused encode scratch" win).
// Mirrors encodeOnce in the Zig/TS references.
// ---------------------------------------------------------------------------

// Pre-encoded constant keys for the nested-doc map (the keys never change; the
// Zig harness re-encodes them per record from an arena, but the keys are
// invariant, so caching them is byte-identical and avoids needless work — the
// same optimization the TS port applies).
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

struct NestedKeys {
    active: Vec<u8>,
    scores: Vec<u8>,
    user: Vec<u8>,
    id: Vec<u8>,
    name: Vec<u8>,
}

fn encode_once(kind: PKind, d: &Data, out: &mut Writer, scratch: &mut Writer, keys: &NestedKeys) {
    match kind {
        PKind::Quotes => {
            for q in &d.quotes {
                scratch.clear();
                scratch.append_string(&q.symbol);
                scratch.append_decimal(false, &q.bid.digits, q.bid.exp);
                scratch.append_decimal(false, &q.ask.digits, q.ask.exp);
                scratch.append_f64(q.last);
                scratch.append_int(q.volume);
                scratch.append_timestamp(q.ts);
                out.append_array(scratch.bytes());
            }
        }
        PKind::Geo => {
            for g in &d.geo {
                scratch.clear();
                scratch.append_f64(g.lat);
                scratch.append_f64(g.lon);
                scratch.append_f64(g.elevation);
                scratch.append_string(&g.name);
                scratch.append_timestamp(g.ts);
                out.append_array(scratch.bytes());
            }
        }
        PKind::Tweets => {
            for t in &d.tweets {
                scratch.clear();
                scratch.append_int(t.id); // u64 id via the fixed integer path (positive)
                scratch.append_string(&t.user);
                scratch.append_string(&t.text);
                scratch.append_timestamp(t.created_at);
                scratch.append_int(t.likes);
                scratch.append_int(t.retweets);
                out.append_array(scratch.bytes());
            }
        }
        PKind::Txs => {
            for x in &d.txs {
                scratch.clear();
                scratch.append_int(x.height);
                scratch.append_bytes(&x.tx_hash);
                scratch.append_bytes(&x.from);
                scratch.append_bytes(&x.to);
                match &x.value {
                    TxValue::Big(mag) => scratch.append_big_int(false, mag),
                    TxValue::Fix(v) => scratch.append_int(*v),
                };
                scratch.append_int(x.gas);
                scratch.append_int(x.nonce);
                scratch.append_timestamp(x.ts);
                out.append_array(scratch.bytes());
            }
        }
        PKind::Ints => {
            for &v in &d.ints {
                out.append_int(v);
            }
        }
        PKind::Strings => {
            for s in &d.strings {
                out.append_string(s);
            }
        }
        PKind::Nested => {
            for n in &d.nested {
                // user sub-map { id, name }
                let mut user = Writer::new();
                user.append_map(&[
                    (keys.id.clone(), enc_int(n.uid)),
                    (keys.name.clone(), enc_str(&n.name)),
                ]);
                // scores array [s0, s1, s2]
                let mut scores_inner = Writer::new();
                scores_inner.append_int(n.scores[0]);
                scores_inner.append_int(n.scores[1]);
                scores_inner.append_int(n.scores[2]);
                let mut scores_arr = Writer::new();
                scores_arr.append_array(scores_inner.bytes());
                // top-level map (append_map sorts by encoded key, so order is free)
                out.append_map(&[
                    (keys.active.clone(), enc_bool(n.active)),
                    (keys.scores.clone(), scores_arr.into_bytes()),
                    (keys.user.clone(), user.into_bytes()),
                ]);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Decode — recursive walk that touches every value, descending into every
// container body (the Reader un-escapes each body in a single pass when it
// contains 0x00). Mirrors `walk` in the Zig/TS references.
// ---------------------------------------------------------------------------

fn walk(buf: &[u8]) {
    let mut r = Reader::new(buf);
    while let Some(el) = r.next().expect("decode error") {
        match el {
            Element::Nil | Element::Undefined => {}
            Element::Bool(b) => sink(b as u64),
            Element::Int(v) => sink((v as i64) as u64),
            Element::BigInt { magnitude, .. } => sink(magnitude.len() as u64),
            Element::F32(f) => sink(f.to_bits() as u64),
            Element::F64(f) => sink(f.to_bits()),
            Element::Decimal(dc) => {
                sink(dc.coeff.len() as u64);
                sink(dc.adj_exp as u64);
            }
            Element::Timestamp(ts) => sink(ts as u64),
            Element::Uuid(u) => sink(u[0] as u64),
            Element::Str(s) => {
                sink(s.len() as u64);
                if let Some(&c) = s.as_bytes().first() {
                    sink(c as u64);
                }
            }
            Element::Bytes(b) => {
                sink(b.len() as u64);
                if let Some(&c) = b.first() {
                    sink(c as u64);
                }
            }
            Element::Array(body) | Element::Map(body) | Element::Set(body) => walk(&body),
        }
    }
}

// ---------------------------------------------------------------------------
// Timing.
// ---------------------------------------------------------------------------

struct Stats {
    ns_per_op: f64,
    bytes: usize,
    records: usize,
}

impl Stats {
    fn mb_per_sec(&self) -> f64 {
        (self.bytes as f64 / self.ns_per_op) * 1000.0 // bytes/ns → MB/s
    }
    fn mrec_per_sec(&self) -> f64 {
        (self.records as f64 / self.ns_per_op) * 1000.0 // rec/ns → Mrec/s
    }
}

const TARGET_TRIAL_NS: u128 = 100_000_000; // ~100 ms
const N_TRIALS: usize = 9;
const N_WARMUP: usize = 5;

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    values[values.len() / 2]
}

fn record_count(kind: PKind, d: &Data) -> usize {
    match kind {
        PKind::Quotes => d.quotes.len(),
        PKind::Geo => d.geo.len(),
        PKind::Tweets => d.tweets.len(),
        PKind::Txs => d.txs.len(),
        PKind::Ints => d.ints.len(),
        PKind::Strings => d.strings.len(),
        PKind::Nested => d.nested.len(),
    }
}

fn build_canonical(kind: PKind, d: &Data, keys: &NestedKeys) -> Vec<u8> {
    let mut out = Writer::new();
    let mut scratch = Writer::new();
    encode_once(kind, d, &mut out, &mut scratch, keys);
    out.into_bytes()
}

fn bench_encode(kind: PKind, d: &Data, canonical_len: usize, keys: &NestedKeys) -> Stats {
    // Pre-size `out` to the canonical length so steady-state runs do not pay
    // realloc growth (matches the reference's retained output buffer).
    let mut out = Writer::with_capacity(canonical_len);
    let mut scratch = Writer::new();

    let run_once = |out: &mut Writer, scratch: &mut Writer| {
        out.clear();
        encode_once(kind, d, out, scratch, keys);
        sink(out.bytes().len() as u64);
    };

    // Warm up (also grows the retained buffers to steady state).
    for _ in 0..N_WARMUP {
        run_once(&mut out, &mut scratch);
    }

    // Calibrate iteration count to ~TARGET_TRIAL_NS.
    let t0 = Instant::now();
    run_once(&mut out, &mut scratch);
    let one = t0.elapsed().as_nanos().max(1);
    let iters = (TARGET_TRIAL_NS / one).max(1) as usize;

    let mut trials = [0.0f64; N_TRIALS];
    for slot in trials.iter_mut() {
        let t = Instant::now();
        for _ in 0..iters {
            run_once(&mut out, &mut scratch);
        }
        *slot = t.elapsed().as_nanos() as f64 / iters as f64;
    }
    Stats { ns_per_op: median(&mut trials), bytes: canonical_len, records: record_count(kind, d) }
}

fn bench_decode(kind: PKind, d: &Data, bytes: &[u8]) -> Stats {
    let run_once = || walk(black_box(bytes));

    for _ in 0..N_WARMUP {
        run_once();
    }

    let t0 = Instant::now();
    run_once();
    let one = t0.elapsed().as_nanos().max(1);
    let iters = (TARGET_TRIAL_NS / one).max(1) as usize;

    let mut trials = [0.0f64; N_TRIALS];
    for slot in trials.iter_mut() {
        let t = Instant::now();
        for _ in 0..iters {
            run_once();
        }
        *slot = t.elapsed().as_nanos() as f64 / iters as f64;
    }
    Stats { ns_per_op: median(&mut trials), bytes: bytes.len(), records: record_count(kind, d) }
}

// ---------------------------------------------------------------------------
// Minimal SHA-256 (FIPS 180-4) — self-contained so `sha256_ok` is a real hash
// match against the manifest (no dependency on a crate).
// ---------------------------------------------------------------------------

struct Sha256 {
    state: [u32; 8],
    len: u64,
    buf: [u8; 64],
    buf_len: usize,
}

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

impl Sha256 {
    fn new() -> Self {
        Sha256 {
            state: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
                0x5be0cd19,
            ],
            len: 0,
            buf: [0u8; 64],
            buf_len: 0,
        }
    }
    fn update(&mut self, mut data: &[u8]) {
        self.len = self.len.wrapping_add(data.len() as u64);
        if self.buf_len > 0 {
            let need = 64 - self.buf_len;
            let take = need.min(data.len());
            self.buf[self.buf_len..self.buf_len + take].copy_from_slice(&data[..take]);
            self.buf_len += take;
            data = &data[take..];
            if self.buf_len == 64 {
                let block = self.buf;
                self.process(&block);
                self.buf_len = 0;
            }
        }
        while data.len() >= 64 {
            let mut block = [0u8; 64];
            block.copy_from_slice(&data[..64]);
            self.process(&block);
            data = &data[64..];
        }
        if !data.is_empty() {
            self.buf[..data.len()].copy_from_slice(data);
            self.buf_len = data.len();
        }
    }
    fn process(&mut self, block: &[u8; 64]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut h = self.state;
        for i in 0..64 {
            let s1 = h[4].rotate_right(6) ^ h[4].rotate_right(11) ^ h[4].rotate_right(25);
            let ch = (h[4] & h[5]) ^ ((!h[4]) & h[6]);
            let t1 = h[7]
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(SHA256_K[i])
                .wrapping_add(w[i]);
            let s0 = h[0].rotate_right(2) ^ h[0].rotate_right(13) ^ h[0].rotate_right(22);
            let maj = (h[0] & h[1]) ^ (h[0] & h[2]) ^ (h[1] & h[2]);
            let t2 = s0.wrapping_add(maj);
            h[7] = h[6];
            h[6] = h[5];
            h[5] = h[4];
            h[4] = h[3].wrapping_add(t1);
            h[3] = h[2];
            h[2] = h[1];
            h[1] = h[0];
            h[0] = t1.wrapping_add(t2);
        }
        for i in 0..8 {
            self.state[i] = self.state[i].wrapping_add(h[i]);
        }
    }
    fn finish(mut self) -> [u8; 32] {
        let bit_len = self.len.wrapping_mul(8);
        // append the 0x80 terminator, then zero-pad to length ≡ 56 (mod 64),
        // then the 64-bit big-endian bit length.
        self.update_no_len(&[0x80u8]);
        while self.buf_len != 56 {
            self.update_no_len(&[0u8]);
        }
        self.update_no_len(&bit_len.to_be_bytes());
        let mut out = [0u8; 32];
        for i in 0..8 {
            out[i * 4..i * 4 + 4].copy_from_slice(&self.state[i].to_be_bytes());
        }
        out
    }
    /// Like `update` but does not advance the message-length counter (used for
    /// the padding bytes during `finish`).
    fn update_no_len(&mut self, data: &[u8]) {
        let saved = self.len;
        self.update(data);
        self.len = saved;
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    let digest = h.finish();
    let mut s = String::with_capacity(64);
    for b in digest {
        s.push(char::from_digit((b >> 4) as u32, 16).unwrap());
        s.push(char::from_digit((b & 0xf) as u32, 16).unwrap());
    }
    s
}

// ---------------------------------------------------------------------------
// Tiny manifest reader (payloads.json) — pulls name/byte_len/sha256 per payload
// with a minimal field scan (no serde).
// ---------------------------------------------------------------------------

struct Expected {
    byte_len: usize,
    sha256: String,
}

fn read_manifest(path: &Path) -> std::collections::HashMap<String, Expected> {
    let text = std::fs::read_to_string(path).expect("read payloads.json");
    let mut map = std::collections::HashMap::new();
    // Walk each payload object (each begins at a "name" field).
    let mut search = text.as_str();
    while let Some(npos) = search.find("\"name\"") {
        let block = &search[npos..];
        let name = json_field_str(block, "name");
        let byte_len = json_field_num(block, "byte_len");
        let sha = json_field_str(block, "sha256");
        if let (Some(name), Some(byte_len), Some(sha)) = (name, byte_len, sha) {
            map.insert(name, Expected { byte_len: byte_len as usize, sha256: sha });
        }
        search = &block[6..];
    }
    map
}

/// Read the string value of `"<key>": "<value>"` starting from `block`.
fn json_field_str(block: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\"");
    let kpos = block.find(&pat)?;
    let after = &block[kpos + pat.len()..];
    let colon = after.find(':')?;
    let rest = &after[colon + 1..];
    let q1 = rest.find('"')?;
    let tail = &rest[q1 + 1..];
    let q2 = tail.find('"')?;
    Some(tail[..q2].to_string())
}

/// Read the numeric value of `"<key>": <number>` starting from `block`.
fn json_field_num(block: &str, key: &str) -> Option<u64> {
    let pat = format!("\"{key}\"");
    let kpos = block.find(&pat)?;
    let after = &block[kpos + pat.len()..];
    let colon = after.find(':')?;
    let rest = after[colon + 1..].trim_start();
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse::<u64>().ok()
}

// ---------------------------------------------------------------------------
// Host label.
// ---------------------------------------------------------------------------

fn host_label() -> String {
    if let Ok(text) = std::fs::read_to_string("/proc/cpuinfo") {
        for line in text.lines() {
            if line.starts_with("model name") {
                if let Some(c) = line.find(':') {
                    return line[c + 1..].trim().to_string();
                }
            }
        }
    }
    "unknown".to_string()
}

// ---------------------------------------------------------------------------
// Repo-root resolution: the binary lives in <repo>/rust/target/release/bench;
// the data lives in <repo>/bench/. We resolve relative to CARGO_MANIFEST_DIR
// (the `rust/` crate dir), so the bench works regardless of the cwd.
// ---------------------------------------------------------------------------

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is set at compile time to <repo>/rust.
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    crate_dir.parent().map(|p| p.to_path_buf()).unwrap_or(crate_dir)
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

struct PayloadResult {
    name: String,
    enc_mrec_s: f64,
    enc_mb_s: f64,
    dec_mrec_s: f64,
    dec_mb_s: f64,
    sha256_ok: bool,
}

fn round2(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}

fn main() {
    let root = repo_root();
    let bench_dir = root.join("bench");
    let data_dir = bench_dir.join("data");
    let results_dir = bench_dir.join("results");

    let manifest = read_manifest(&bench_dir.join("payloads.json"));
    let data = read_data(&data_dir);

    let keys = NestedKeys {
        active: enc_str("active"),
        scores: enc_str("scores"),
        user: enc_str("user"),
        id: enc_str("id"),
        name: enc_str("name"),
    };

    println!("struple benchmark (Rust, release, single-threaded)\n");

    let mut results: Vec<PayloadResult> = Vec::new();
    let mut all_ok = true;
    let mut total_bytes = 0usize;

    for meta in PAYLOADS {
        let bytes = build_canonical(meta.kind, &data, &keys);
        total_bytes += bytes.len();

        // Verify byte-identity against the manifest BEFORE measuring.
        let exp = manifest.get(meta.name);
        let sha = sha256_hex(&bytes);
        let sha_ok = match exp {
            Some(e) => sha == e.sha256 && bytes.len() == e.byte_len,
            None => false,
        };

        if !sha_ok {
            all_ok = false;
            eprintln!(
                "\nBYTE MISMATCH for {}:\n  produced byte_len={} sha256={}\n  expected byte_len={} sha256={}\n  This is a contract bug — STOPPING (no throughput reported for this payload).",
                meta.name,
                bytes.len(),
                sha,
                exp.map(|e| e.byte_len).unwrap_or(0),
                exp.map(|e| e.sha256.as_str()).unwrap_or("?"),
            );
            results.push(PayloadResult {
                name: meta.name.into(),
                enc_mrec_s: 0.0,
                enc_mb_s: 0.0,
                dec_mrec_s: 0.0,
                dec_mb_s: 0.0,
                sha256_ok: false,
            });
            continue;
        }

        let enc = bench_encode(meta.kind, &data, bytes.len(), &keys);
        let dec = bench_decode(meta.kind, &data, &bytes);

        let (em, eb, dm, db) =
            (enc.mrec_per_sec(), enc.mb_per_sec(), dec.mrec_per_sec(), dec.mb_per_sec());

        results.push(PayloadResult {
            name: meta.name.into(),
            enc_mrec_s: round2(em),
            enc_mb_s: round2(eb),
            dec_mrec_s: round2(dm),
            dec_mb_s: round2(db),
            sha256_ok: true,
        });

        println!(
            "  {:<16} {:>6} rec   enc {:>7.2} Mrec/s {:>6.0} MB/s   dec {:>7.2} Mrec/s {:>6.0} MB/s   sha ok",
            meta.name, enc.records, em, eb, dm, db,
        );
    }

    let host = host_label();
    write_results(&results_dir, &host, &results);

    println!(
        "\nHost: {} · Total corpus: {:.1} KB · Wrote bench/results/rust.json",
        host,
        total_bytes as f64 / 1024.0,
    );
    // black_box the sink so the optimizer cannot prove the measured work dead.
    let s = unsafe { G_SINK };
    println!("(sink {:x})", black_box(s));

    if !all_ok {
        eprintln!("\nOne or more payloads failed byte-identity — see above.");
        std::process::exit(1);
    }
}

fn write_results(results_dir: &Path, host: &str, results: &[PayloadResult]) {
    std::fs::create_dir_all(results_dir).expect("create results dir");
    let mut s = String::new();
    s.push_str("{\n");
    s.push_str("  \"lang\": \"Rust\",\n");
    s.push_str(&format!("  \"host\": {},\n", json_string(host)));
    s.push_str("  \"payloads\": {\n");
    for (i, r) in results.iter().enumerate() {
        s.push_str(&format!("    {}: {{\n", json_string(&r.name)));
        s.push_str(&format!("      \"enc_mrec_s\": {},\n", fmt_num(r.enc_mrec_s)));
        s.push_str(&format!("      \"enc_mb_s\": {},\n", fmt_num(r.enc_mb_s)));
        s.push_str(&format!("      \"dec_mrec_s\": {},\n", fmt_num(r.dec_mrec_s)));
        s.push_str(&format!("      \"dec_mb_s\": {},\n", fmt_num(r.dec_mb_s)));
        s.push_str(&format!("      \"sha256_ok\": {}\n", r.sha256_ok));
        s.push_str("    }");
        s.push_str(if i + 1 == results.len() { "\n" } else { ",\n" });
    }
    s.push_str("  }\n}\n");
    std::fs::write(results_dir.join("rust.json"), s).expect("write rust.json");
}

/// Format a rounded-to-2dp number the way JSON.stringify renders it (drop a
/// trailing ".0", keep up to two decimals).
fn fmt_num(x: f64) -> String {
    if x == x.trunc() {
        format!("{}", x as i64)
    } else {
        let s = format!("{x:.2}");
        let s = s.trim_end_matches('0');
        let s = s.trim_end_matches('.');
        s.to_string()
    }
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
