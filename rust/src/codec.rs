//! struple core codec — a faithful port of the Zig reference.
//!
//! Encoded bytes are directly comparable: `compare(&encode(a), &encode(b))` (and
//! plain slice comparison / `sort`) matches the semantic order of the values.
//! The conformance corpus (`conformance/vectors.json`) pins byte identity across
//! languages.

use std::cmp::Ordering;
use std::fmt;

// Type codes. Their order is the cross-type sort order.
pub const TERMINATOR: u8 = 0x00;
pub const NIL: u8 = 0x01;
pub const UNDEF: u8 = 0x02;
pub const BOOL_FALSE: u8 = 0x05;
pub const BOOL_TRUE: u8 = 0x06;
pub const INT_NEG_BIG: u8 = 0x0f;
pub const INT_ZERO: u8 = 0x20;
pub const INT_POS_BIG: u8 = 0x31;
pub const FLOAT32: u8 = 0x34;
pub const FLOAT64: u8 = 0x35;
pub const TIMESTAMP: u8 = 0x40;
pub const UUID: u8 = 0x44;
pub const STRING: u8 = 0x48;
pub const BYTES: u8 = 0x49;
pub const ARRAY: u8 = 0x50;
pub const MAP: u8 = 0x52;
pub const SET: u8 = 0x54;

const SIGN64: u64 = 1 << 63;
const SIGN32: u32 = 1 << 31;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Truncated,
    InvalidType(u8),
    UnsupportedWidth(usize),
    Utf8,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Truncated => write!(f, "struple: truncated input"),
            Error::InvalidType(t) => write!(f, "struple: invalid type code {t:#x}"),
            Error::UnsupportedWidth(n) => write!(f, "struple: unsupported integer width {n}"),
            Error::Utf8 => write!(f, "struple: invalid UTF-8 in string"),
        }
    }
}

impl std::error::Error for Error {}

/// A native value for the high-level `pack`/`unpack` API.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Nil,
    Undefined,
    Bool(bool),
    Int(i128),
    BigInt { negative: bool, magnitude: Vec<u8> },
    F32(f32),
    F64(f64),
    Timestamp(i64),
    Uuid([u8; 16]),
    Str(String),
    Bytes(Vec<u8>),
    Array(Vec<Value>),
    Map(Vec<(Value, Value)>),
    Set(Vec<Value>),
}

/// A decoded element from `Reader`. Container variants carry the un-escaped child
/// stream; feed it to a new `Reader`.
#[derive(Debug, Clone, PartialEq)]
pub enum Element {
    Nil,
    Undefined,
    Bool(bool),
    Int(i128),
    BigInt { negative: bool, magnitude: Vec<u8> },
    F32(f32),
    F64(f64),
    Timestamp(i64),
    Uuid([u8; 16]),
    Str(String),
    Bytes(Vec<u8>),
    Array(Vec<u8>),
    Map(Vec<u8>),
    Set(Vec<u8>),
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

#[derive(Default)]
pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn bytes(&self) -> &[u8] {
        &self.buf
    }
    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }
    pub fn append_nil(&mut self) -> &mut Self {
        self.buf.push(NIL);
        self
    }
    pub fn append_undefined(&mut self) -> &mut Self {
        self.buf.push(UNDEF);
        self
    }
    pub fn append_bool(&mut self, v: bool) -> &mut Self {
        self.buf.push(if v { BOOL_TRUE } else { BOOL_FALSE });
        self
    }
    pub fn append_int(&mut self, v: i128) -> &mut Self {
        append_integer(&mut self.buf, v);
        self
    }
    pub fn append_big_int(&mut self, negative: bool, magnitude: &[u8]) -> &mut Self {
        append_big(&mut self.buf, negative, magnitude);
        self
    }
    pub fn append_f32(&mut self, v: f32) -> &mut Self {
        append_f32(&mut self.buf, v);
        self
    }
    pub fn append_f64(&mut self, v: f64) -> &mut Self {
        append_f64(&mut self.buf, v);
        self
    }
    pub fn append_timestamp(&mut self, micros: i64) -> &mut Self {
        append_timestamp(&mut self.buf, micros);
        self
    }
    pub fn append_uuid(&mut self, u: [u8; 16]) -> &mut Self {
        append_uuid(&mut self.buf, &u);
        self
    }
    pub fn append_string(&mut self, s: &str) -> &mut Self {
        write_framed(&mut self.buf, STRING, s.as_bytes());
        self
    }
    pub fn append_bytes(&mut self, b: &[u8]) -> &mut Self {
        write_framed(&mut self.buf, BYTES, b);
        self
    }
    pub fn append_array(&mut self, child: &[u8]) -> &mut Self {
        write_framed(&mut self.buf, ARRAY, child);
        self
    }
    pub fn append_map(&mut self, entries: &[(Vec<u8>, Vec<u8>)]) -> &mut Self {
        append_map(&mut self.buf, entries);
        self
    }
    pub fn append_set(&mut self, elements: &[Vec<u8>]) -> &mut Self {
        append_set(&mut self.buf, elements);
        self
    }
    pub fn append(&mut self, value: &Value) -> &mut Self {
        append_value(&mut self.buf, value);
        self
    }
}

/// Pack values into a single comparable buffer.
pub fn pack(values: &[Value]) -> Vec<u8> {
    let mut out = Vec::new();
    for v in values {
        append_value(&mut out, v);
    }
    out
}

/// Encode a single value.
pub fn encode(value: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    append_value(&mut out, value);
    out
}

fn append_value(out: &mut Vec<u8>, value: &Value) {
    match value {
        Value::Nil => out.push(NIL),
        Value::Undefined => out.push(UNDEF),
        Value::Bool(b) => out.push(if *b { BOOL_TRUE } else { BOOL_FALSE }),
        Value::Int(i) => append_integer(out, *i),
        Value::BigInt { negative, magnitude } => append_big(out, *negative, magnitude),
        Value::F32(f) => append_f32(out, *f),
        Value::F64(f) => append_f64(out, *f),
        Value::Timestamp(t) => append_timestamp(out, *t),
        Value::Uuid(u) => append_uuid(out, u),
        Value::Str(s) => write_framed(out, STRING, s.as_bytes()),
        Value::Bytes(b) => write_framed(out, BYTES, b),
        Value::Array(items) => {
            let mut child = Vec::new();
            for it in items {
                append_value(&mut child, it);
            }
            write_framed(out, ARRAY, &child);
        }
        Value::Map(entries) => {
            let e: Vec<(Vec<u8>, Vec<u8>)> = entries.iter().map(|(k, v)| (encode(k), encode(v))).collect();
            append_map(out, &e);
        }
        Value::Set(elems) => {
            let e: Vec<Vec<u8>> = elems.iter().map(encode).collect();
            append_set(out, &e);
        }
    }
}

fn append_integer(out: &mut Vec<u8>, value: i128) {
    if value == 0 {
        out.push(INT_ZERO);
        return;
    }
    let negative = value < 0;
    let mag_bytes = u128_to_be(value.unsigned_abs());
    append_magnitude(out, negative, &mag_bytes);
}

fn append_big(out: &mut Vec<u8>, negative: bool, magnitude: &[u8]) {
    let mut m = magnitude;
    while !m.is_empty() && m[0] == 0 {
        m = &m[1..];
    }
    if m.is_empty() {
        out.push(INT_ZERO);
        return;
    }
    append_magnitude(out, negative, m);
}

/// `mag`: normalized big-endian magnitude (non-empty, no leading zeros).
fn append_magnitude(out: &mut Vec<u8>, negative: bool, mag: &[u8]) {
    // The fixed slots span the whole i128 range (1–16 byte magnitudes).
    if fits_fixed(negative, mag) {
        if negative {
            let m = be_to_u128(mag);
            let pos_val = m - 1;
            let n = byte_len(pos_val).max(1);
            out.push(INT_ZERO - n as u8);
            // Excess form: the low n bytes of the wrapping negation give
            // 2^(8n) - m, and avoid the `1 << 128` overflow at n == 16.
            push_be(out, 0u128.wrapping_sub(m), n);
        } else {
            out.push(INT_ZERO + mag.len() as u8);
            out.extend_from_slice(mag);
        }
        return;
    }
    // arbitrary precision beyond i128: [m][n][magnitude], complemented for negatives
    out.push(if negative { INT_NEG_BIG } else { INT_POS_BIG });
    let n = mag.len();
    let m = byte_len(n as u128).max(1);
    let comp = |b: u8| if negative { !b } else { b };
    out.push(comp(m as u8));
    for i in (0..m).rev() {
        out.push(comp(((n >> (8 * i)) & 0xff) as u8));
    }
    for &b in mag {
        out.push(comp(b));
    }
}

fn append_f64(out: &mut Vec<u8>, value: f64) {
    let bits = if value.is_nan() {
        0x7ff8_0000_0000_0000
    } else {
        (if value == 0.0 { 0.0 } else { value }).to_bits()
    };
    let bits = if bits & SIGN64 != 0 { !bits } else { bits ^ SIGN64 };
    out.push(FLOAT64);
    out.extend_from_slice(&bits.to_be_bytes());
}

fn append_f32(out: &mut Vec<u8>, value: f32) {
    let bits = if value.is_nan() {
        0x7fc0_0000
    } else {
        (if value == 0.0 { 0.0 } else { value }).to_bits()
    };
    let bits = if bits & SIGN32 != 0 { !bits } else { bits ^ SIGN32 };
    out.push(FLOAT32);
    out.extend_from_slice(&bits.to_be_bytes());
}

fn append_timestamp(out: &mut Vec<u8>, micros: i64) {
    out.push(TIMESTAMP);
    out.extend_from_slice(&((micros as u64) ^ SIGN64).to_be_bytes());
}

fn append_uuid(out: &mut Vec<u8>, u: &[u8; 16]) {
    out.push(UUID);
    out.extend_from_slice(u);
}

/// Does this value (sign + trimmed big-endian magnitude) fit the i128 range
/// `[-2^127, 2^127-1]`? Below 16 bytes always; at 16 bytes the top byte decides.
fn fits_fixed(negative: bool, mag: &[u8]) -> bool {
    if mag.len() < 16 {
        return true;
    }
    if mag.len() > 16 {
        return false;
    }
    if mag[0] < 0x80 {
        return true; // |value| < 2^127
    }
    // only -2^127 (magnitude exactly 2^127 = 0x80 00..00) still fits
    negative && mag[0] == 0x80 && mag[1..].iter().all(|&b| b == 0)
}

fn append_map(out: &mut Vec<u8>, entries: &[(Vec<u8>, Vec<u8>)]) {
    let mut sorted: Vec<&(Vec<u8>, Vec<u8>)> = entries.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    out.push(MAP);
    for (k, v) in sorted {
        write_escaped(out, k);
        write_escaped(out, v);
    }
    out.push(TERMINATOR);
}

fn append_set(out: &mut Vec<u8>, elements: &[Vec<u8>]) {
    let mut sorted: Vec<&Vec<u8>> = elements.iter().collect();
    sorted.sort();
    out.push(SET);
    let mut prev: Option<&Vec<u8>> = None;
    for e in sorted {
        if let Some(p) = prev {
            if p == e {
                continue;
            }
        }
        write_escaped(out, e);
        prev = Some(e);
    }
    out.push(TERMINATOR);
}

fn write_framed(out: &mut Vec<u8>, type_code: u8, content: &[u8]) {
    out.push(type_code);
    write_escaped(out, content);
    out.push(TERMINATOR);
}

fn write_escaped(out: &mut Vec<u8>, content: &[u8]) {
    for &b in content {
        out.push(b);
        if b == 0x00 {
            out.push(0xff);
        }
    }
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }
    pub fn done(&self) -> bool {
        self.pos >= self.buf.len()
    }

    pub fn next(&mut self) -> Result<Option<Element>, Error> {
        if self.pos >= self.buf.len() {
            return Ok(None);
        }
        let t = self.buf[self.pos];
        self.pos += 1;
        let el = match t {
            NIL => Element::Nil,
            UNDEF => Element::Undefined,
            BOOL_FALSE => Element::Bool(false),
            BOOL_TRUE => Element::Bool(true),
            INT_ZERO => Element::Int(0),
            INT_NEG_BIG | INT_POS_BIG => self.read_big_int(t)?,
            FLOAT32 => Element::F32(self.read_f32()?),
            FLOAT64 => Element::F64(self.read_f64()?),
            TIMESTAMP => Element::Timestamp(self.read_timestamp()?),
            UUID => Element::Uuid(self.take(16)?.try_into().unwrap()),
            STRING => Element::Str(String::from_utf8(unescape(self.take_framed()?)).map_err(|_| Error::Utf8)?),
            BYTES => Element::Bytes(unescape(self.take_framed()?)),
            ARRAY => Element::Array(unescape(self.take_framed()?)),
            MAP => Element::Map(unescape(self.take_framed()?)),
            SET => Element::Set(unescape(self.take_framed()?)),
            0x10..=0x1f | 0x21..=0x30 => self.read_fixed_int(t)?,
            _ => return Err(Error::InvalidType(t)),
        };
        Ok(Some(el))
    }

    /// The next element's type code without consuming it (None at end).
    pub fn peek_type(&self) -> Option<u8> {
        self.buf.get(self.pos).copied()
    }

    /// The remaining unread bytes (a valid struple stream).
    pub fn rest(&self) -> &'a [u8] {
        &self.buf[self.pos..]
    }

    /// The next element's raw bytes (a zero-copy view), advancing the cursor.
    pub fn next_view(&mut self) -> Result<Option<&'a [u8]>, Error> {
        let start = self.pos;
        if self.next()?.is_none() {
            return Ok(None);
        }
        let end = self.pos;
        Ok(Some(&self.buf[start..end]))
    }

    /// Advance past the next element; false at end of stream.
    pub fn skip(&mut self) -> Result<bool, Error> {
        Ok(self.next_view()?.is_some())
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], Error> {
        if self.pos + n > self.buf.len() {
            return Err(Error::Truncated);
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    fn take_framed(&mut self) -> Result<&'a [u8], Error> {
        let start = self.pos;
        let mut i = self.pos;
        while i < self.buf.len() {
            if self.buf[i] == 0x00 {
                if i + 1 < self.buf.len() && self.buf[i + 1] == 0xff {
                    i += 2;
                    continue;
                }
                let s = &self.buf[start..i];
                self.pos = i + 1;
                return Ok(s);
            }
            i += 1;
        }
        Err(Error::Truncated)
    }

    fn read_fixed_int(&mut self, t: u8) -> Result<Element, Error> {
        let positive = t > INT_ZERO;
        let n = if positive { (t - INT_ZERO) as usize } else { (INT_ZERO - t) as usize };
        let payload = self.take(n)?;
        // The widest (16-byte) slots can address values outside i128; a canonical
        // encoder uses the big-int codes for those, so reject them here.
        if n == 16 && ((positive && payload[0] >= 0x80) || (!positive && payload[0] < 0x80)) {
            return Err(Error::InvalidType(t));
        }
        let raw = be_to_u128(payload);
        Ok(Element::Int(if positive {
            raw as i128
        } else if n == 16 {
            raw as i128 // raw - 2^128 via two's-complement reinterpretation
        } else {
            raw as i128 - (1i128 << (8 * n))
        }))
    }

    fn read_big_int(&mut self, t: u8) -> Result<Element, Error> {
        let negative = t == INT_NEG_BIG;
        let comp = |b: u8| if negative { !b } else { b };
        let m = comp(self.take(1)?[0]) as usize;
        let mut n = 0usize;
        for &b in self.take(m)? {
            n = (n << 8) | comp(b) as usize;
        }
        let magnitude: Vec<u8> = self.take(n)?.iter().map(|&b| comp(b)).collect();
        Ok(Element::BigInt { negative, magnitude })
    }

    fn read_f64(&mut self) -> Result<f64, Error> {
        let bits = u64::from_be_bytes(self.take(8)?.try_into().unwrap());
        let bits = if bits & SIGN64 != 0 { bits ^ SIGN64 } else { !bits };
        Ok(f64::from_bits(bits))
    }

    fn read_f32(&mut self) -> Result<f32, Error> {
        let bits = u32::from_be_bytes(self.take(4)?.try_into().unwrap());
        let bits = if bits & SIGN32 != 0 { bits ^ SIGN32 } else { !bits };
        Ok(f32::from_bits(bits))
    }

    fn read_timestamp(&mut self) -> Result<i64, Error> {
        let raw = u64::from_be_bytes(self.take(8)?.try_into().unwrap()) ^ SIGN64;
        Ok(raw as i64)
    }
}

/// Decode a whole stream into native values.
pub fn unpack(bytes: &[u8]) -> Result<Vec<Value>, Error> {
    let mut r = Reader::new(bytes);
    let mut out = Vec::new();
    while let Some(e) = r.next()? {
        out.push(element_to_value(e)?);
    }
    Ok(out)
}

fn element_to_value(e: Element) -> Result<Value, Error> {
    Ok(match e {
        Element::Nil => Value::Nil,
        Element::Undefined => Value::Undefined,
        Element::Bool(b) => Value::Bool(b),
        Element::Int(i) => Value::Int(i),
        Element::BigInt { negative, magnitude } => Value::BigInt { negative, magnitude },
        Element::F32(f) => Value::F32(f),
        Element::F64(f) => Value::F64(f),
        Element::Timestamp(t) => Value::Timestamp(t),
        Element::Uuid(u) => Value::Uuid(u),
        Element::Str(s) => Value::Str(s),
        Element::Bytes(b) => Value::Bytes(b),
        Element::Array(body) => Value::Array(unpack(&body)?),
        Element::Set(body) => Value::Set(unpack(&body)?),
        Element::Map(body) => {
            let mut r = Reader::new(&body);
            let mut pairs = Vec::new();
            while let Some(k) = r.next()? {
                let v = r.next()?.ok_or(Error::Truncated)?;
                pairs.push((element_to_value(k)?, element_to_value(v)?));
            }
            Value::Map(pairs)
        }
    })
}

/// Decode every element and re-encode it. Output equals input for any canonical
/// buffer — a full round-trip validation of the decoder.
pub fn transcode(bytes: &[u8]) -> Result<Vec<u8>, Error> {
    let mut r = Reader::new(bytes);
    let mut out = Vec::new();
    while let Some(e) = r.next()? {
        append_element(&mut out, &e);
    }
    Ok(out)
}

fn append_element(out: &mut Vec<u8>, e: &Element) {
    match e {
        Element::Nil => out.push(NIL),
        Element::Undefined => out.push(UNDEF),
        Element::Bool(b) => out.push(if *b { BOOL_TRUE } else { BOOL_FALSE }),
        Element::Int(i) => append_integer(out, *i),
        Element::BigInt { negative, magnitude } => append_big(out, *negative, magnitude),
        Element::F32(f) => append_f32(out, *f),
        Element::F64(f) => append_f64(out, *f),
        Element::Timestamp(t) => append_timestamp(out, *t),
        Element::Uuid(u) => append_uuid(out, u),
        Element::Str(s) => write_framed(out, STRING, s.as_bytes()),
        Element::Bytes(b) => write_framed(out, BYTES, b),
        Element::Array(body) => write_framed(out, ARRAY, body),
        Element::Map(body) => write_framed(out, MAP, body),
        Element::Set(body) => write_framed(out, SET, body),
    }
}

/// Lexicographic byte comparison; matches semantic order. (Slices are already
/// `Ord` this way — `a.cmp(b)` and `slice::sort` work directly.)
pub fn compare(a: &[u8], b: &[u8]) -> Ordering {
    a.cmp(b)
}

// ---------------------------------------------------------------------------
// Navigation / query
// ---------------------------------------------------------------------------

/// Zero-copy navigation over a struple buffer (a stream of elements). Every
/// result is a sub-slice that is itself a valid struple buffer.
#[derive(Clone, Copy)]
pub struct View<'a> {
    pub bytes: &'a [u8],
}

pub fn view(bytes: &[u8]) -> View<'_> {
    View::new(bytes)
}

impl<'a> View<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        View { bytes }
    }
    pub fn reader(&self) -> Reader<'a> {
        Reader::new(self.bytes)
    }

    pub fn count(&self) -> Result<usize, Error> {
        let mut r = self.reader();
        let mut n = 0;
        while r.skip()? {
            n += 1;
        }
        Ok(n)
    }

    pub fn at(&self, index: usize) -> Result<Option<&'a [u8]>, Error> {
        let mut r = self.reader();
        let mut i = 0;
        while let Some(v) = r.next_view()? {
            if i == index {
                return Ok(Some(v));
            }
            i += 1;
        }
        Ok(None)
    }

    pub fn head(&self) -> Result<Option<&'a [u8]>, Error> {
        self.at(0)
    }

    pub fn tail(&self) -> Result<&'a [u8], Error> {
        let mut r = self.reader();
        r.next_view()?;
        Ok(r.rest())
    }

    pub fn nth_rest(&self, n: usize) -> Result<&'a [u8], Error> {
        let mut r = self.reader();
        for _ in 0..n {
            if !r.skip()? {
                break;
            }
        }
        Ok(r.rest())
    }

    pub fn take(&self, n: usize) -> Result<&'a [u8], Error> {
        let mut r = self.reader();
        for _ in 0..n {
            if !r.skip()? {
                break;
            }
        }
        Ok(&self.bytes[..self.bytes.len() - r.rest().len()])
    }

    pub fn head_type(&self) -> Option<u8> {
        self.bytes.first().copied()
    }

    pub fn is_nil(&self) -> bool {
        self.head_type() == Some(NIL)
    }
    pub fn is_undefined(&self) -> bool {
        self.head_type() == Some(UNDEF)
    }
    pub fn is_bool(&self) -> bool {
        matches!(self.head_type(), Some(BOOL_FALSE) | Some(BOOL_TRUE))
    }
    pub fn is_int(&self) -> bool {
        match self.head_type() {
            Some(t) => t == INT_ZERO || t == INT_NEG_BIG || t == INT_POS_BIG || (0x10..=0x1f).contains(&t) || (0x21..=0x30).contains(&t),
            None => false,
        }
    }
    pub fn is_float(&self) -> bool {
        matches!(self.head_type(), Some(FLOAT32) | Some(FLOAT64))
    }
    pub fn is_number(&self) -> bool {
        self.is_int() || self.is_float()
    }
    pub fn is_timestamp(&self) -> bool {
        self.head_type() == Some(TIMESTAMP)
    }
    pub fn is_uuid(&self) -> bool {
        self.head_type() == Some(UUID)
    }
    pub fn is_string(&self) -> bool {
        self.head_type() == Some(STRING)
    }
    pub fn is_bytes(&self) -> bool {
        self.head_type() == Some(BYTES)
    }
    pub fn is_array(&self) -> bool {
        self.head_type() == Some(ARRAY)
    }
    pub fn is_map(&self) -> bool {
        self.head_type() == Some(MAP)
    }
    pub fn is_set(&self) -> bool {
        self.head_type() == Some(SET)
    }
    pub fn is_container(&self) -> bool {
        matches!(self.head_type(), Some(ARRAY) | Some(MAP) | Some(SET))
    }

    /// The container's inner element stream (un-escaped, owned), or None.
    pub fn contained_items(&self) -> Result<Option<Vec<u8>>, Error> {
        if !self.is_container() {
            return Ok(None);
        }
        let mut r = self.reader();
        Ok(match r.next()? {
            Some(Element::Array(b)) | Some(Element::Map(b)) | Some(Element::Set(b)) => Some(b),
            _ => None,
        })
    }
}

/// Reads key/value pairs from a map's inner stream (from `View::contained_items`).
/// Keys are canonical (sorted), so `get` early-exits.
pub struct MapView<'a> {
    pub inner: &'a [u8],
}

impl<'a> MapView<'a> {
    pub fn new(inner: &'a [u8]) -> Self {
        MapView { inner }
    }
    pub fn count(&self) -> Result<usize, Error> {
        Ok(View::new(self.inner).count()? / 2)
    }
    pub fn entries(&self) -> EntryIter<'a> {
        EntryIter { r: Reader::new(self.inner) }
    }
    /// Look up the value bytes for an encoded key (e.g. `encode(&Value::Str(...))`).
    pub fn get(&self, key: &[u8]) -> Result<Option<&'a [u8]>, Error> {
        let mut it = self.entries();
        while let Some((k, v)) = it.next_entry()? {
            match k.cmp(key) {
                Ordering::Equal => return Ok(Some(v)),
                Ordering::Greater => return Ok(None),
                Ordering::Less => {}
            }
        }
        Ok(None)
    }
}

pub struct EntryIter<'a> {
    r: Reader<'a>,
}

impl<'a> EntryIter<'a> {
    pub fn next_entry(&mut self) -> Result<Option<(&'a [u8], &'a [u8])>, Error> {
        let k = match self.r.next_view()? {
            Some(k) => k,
            None => return Ok(None),
        };
        let v = self.r.next_view()?.ok_or(Error::Truncated)?;
        Ok(Some((k, v)))
    }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn unescape(framed: &[u8]) -> Vec<u8> {
    if !framed.contains(&0x00) {
        return framed.to_vec();
    }
    let mut out = Vec::with_capacity(framed.len());
    let mut i = 0;
    while i < framed.len() {
        out.push(framed[i]);
        if framed[i] == 0x00 {
            i += 1; // skip the 0xff companion
        }
        i += 1;
    }
    out
}

fn u128_to_be(mag: u128) -> Vec<u8> {
    if mag == 0 {
        return Vec::new();
    }
    let bytes = mag.to_be_bytes();
    let first = bytes.iter().position(|&b| b != 0).unwrap();
    bytes[first..].to_vec()
}

fn be_to_u128(bytes: &[u8]) -> u128 {
    let mut v: u128 = 0;
    for &b in bytes {
        v = (v << 8) | b as u128;
    }
    v
}

fn byte_len(x: u128) -> usize {
    if x == 0 {
        0
    } else {
        (128 - x.leading_zeros() as usize + 7) / 8
    }
}

fn push_be(out: &mut Vec<u8>, value: u128, n: usize) {
    for i in (0..n).rev() {
        out.push(((value >> (8 * i)) & 0xff) as u8);
    }
}
