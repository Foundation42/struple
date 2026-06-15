//! JSON <-> struple, mirroring the Zig reference. Self-contained (no serde).
//!
//!   from_json: JSON text  -> struple encoding (one element for the root value)
//!   to_json:   struple bytes -> canonical JSON text
//!
//! Integer JSON numbers are parsed as `i128` (covering arbitrary-precision values
//! a JS f64 round-trip would corrupt, up to i128's range); fractional/exponent
//! numbers become f64. Objects encode to canonical (key-sorted) maps.

use crate::codec::{Element, Error, Reader, Writer};

/// A parsed JSON value (also used by the conformance tests to read the corpus).
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i128),
    Float(f64),
    Str(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

/// Parse JSON text and return its struple encoding.
pub fn from_json(text: &str) -> Result<Vec<u8>, String> {
    let mut w = Writer::new();
    encode_json(&mut w, &parse(text)?);
    Ok(w.into_bytes())
}

/// Render a struple encoding's first element as canonical JSON text.
pub fn to_json(bytes: &[u8]) -> Result<String, Error> {
    let mut r = Reader::new(bytes);
    match r.next()? {
        None => Ok("null".to_string()),
        Some(e) => {
            let mut s = String::new();
            render(&mut s, &e)?;
            Ok(s)
        }
    }
}

fn encode_json(w: &mut Writer, v: &Json) {
    match v {
        Json::Null => {
            w.append_nil();
        }
        Json::Bool(b) => {
            w.append_bool(*b);
        }
        Json::Int(i) => {
            w.append_int(*i);
        }
        Json::Float(f) => {
            w.append_f64(*f);
        }
        Json::Str(s) => {
            w.append_string(s);
        }
        Json::Array(items) => {
            let mut child = Writer::new();
            for it in items {
                encode_json(&mut child, it);
            }
            w.append_array(child.bytes());
        }
        Json::Object(entries) => {
            let e: Vec<(Vec<u8>, Vec<u8>)> = entries
                .iter()
                .map(|(k, val)| {
                    let mut kw = Writer::new();
                    kw.append_string(k);
                    let mut vw = Writer::new();
                    encode_json(&mut vw, val);
                    (kw.into_bytes(), vw.into_bytes())
                })
                .collect();
            w.append_map(&e);
        }
    }
}

fn render(out: &mut String, e: &Element) -> Result<(), Error> {
    match e {
        Element::Nil | Element::Undefined => out.push_str("null"),
        Element::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Element::Int(i) => out.push_str(&i.to_string()),
        Element::BigInt { negative, magnitude } => {
            if *negative {
                out.push('-');
            }
            out.push_str(&magnitude_to_decimal(magnitude));
        }
        Element::F32(f) => render_float(out, *f as f64),
        Element::F64(f) => render_float(out, *f),
        Element::Timestamp(t) => out.push_str(&t.to_string()),
        Element::Str(s) => render_string(out, s),
        Element::Bytes(b) => render_string(out, &base64(b)),
        Element::Array(body) | Element::Set(body) => render_array(out, body)?,
        Element::Map(body) => render_map(out, body)?,
    }
    Ok(())
}

fn render_float(out: &mut String, f: f64) {
    if f.is_finite() {
        out.push_str(&format!("{f}"));
    } else {
        out.push_str("null");
    }
}

fn render_array(out: &mut String, body: &[u8]) -> Result<(), Error> {
    let mut r = Reader::new(body);
    out.push('[');
    let mut first = true;
    while let Some(e) = r.next()? {
        if !first {
            out.push(',');
        }
        first = false;
        render(out, &e)?;
    }
    out.push(']');
    Ok(())
}

fn render_map(out: &mut String, body: &[u8]) -> Result<(), Error> {
    let mut r = Reader::new(body);
    out.push('{');
    let mut first = true;
    while let Some(k) = r.next()? {
        let v = r.next()?.ok_or(Error::Truncated)?;
        if !first {
            out.push(',');
        }
        first = false;
        match &k {
            Element::Str(s) => render_string(out, s),
            other => {
                let mut tmp = String::new();
                render(&mut tmp, other)?;
                render_string(out, &tmp);
            }
        }
        out.push(':');
        render(out, &v)?;
    }
    out.push('}');
    Ok(())
}

fn render_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn magnitude_to_decimal(mag: &[u8]) -> String {
    if mag.is_empty() {
        return "0".to_string();
    }
    let mut work = mag.to_vec();
    let mut digits = Vec::new();
    let mut start = 0;
    while start < work.len() {
        let mut rem: u16 = 0;
        for b in work.iter_mut().skip(start) {
            let cur = (rem << 8) | *b as u16;
            *b = (cur / 10) as u8;
            rem = cur % 10;
        }
        digits.push(b'0' + rem as u8);
        while start < work.len() && work[start] == 0 {
            start += 1;
        }
    }
    digits.reverse();
    String::from_utf8(digits).unwrap()
}

fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(T[(n >> 18 & 63) as usize] as char);
        out.push(T[(n >> 12 & 63) as usize] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6 & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
    }
    out
}

// ---------------------------------------------------------------------------
// A small JSON parser (no dependencies)
// ---------------------------------------------------------------------------

/// Parse JSON text into a `Json` value.
pub fn parse(s: &str) -> Result<Json, String> {
    let mut p = Parser { b: s.as_bytes(), i: 0 };
    let v = p.value()?;
    p.ws();
    if p.i != p.b.len() {
        return Err("trailing data after JSON value".into());
    }
    Ok(v)
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        match self.peek().ok_or("unexpected end of input")? {
            b'n' => {
                self.lit("null")?;
                Ok(Json::Null)
            }
            b't' => {
                self.lit("true")?;
                Ok(Json::Bool(true))
            }
            b'f' => {
                self.lit("false")?;
                Ok(Json::Bool(false))
            }
            b'"' => Ok(Json::Str(self.string()?)),
            b'[' => self.array(),
            b'{' => self.object(),
            b'-' | b'0'..=b'9' => self.number(),
            c => Err(format!("unexpected byte {c:#x}")),
        }
    }

    fn lit(&mut self, s: &str) -> Result<(), String> {
        if self.b[self.i..].starts_with(s.as_bytes()) {
            self.i += s.len();
            Ok(())
        } else {
            Err(format!("expected `{s}`"))
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.i += 1; // opening quote
        let mut out: Vec<u8> = Vec::new();
        while let Some(c) = self.peek() {
            self.i += 1;
            match c {
                b'"' => return String::from_utf8(out).map_err(|_| "invalid utf-8".to_string()),
                b'\\' => {
                    let e = self.peek().ok_or("unterminated escape")?;
                    self.i += 1;
                    match e {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'n' => out.push(b'\n'),
                        b't' => out.push(b'\t'),
                        b'r' => out.push(b'\r'),
                        b'b' => out.push(0x08),
                        b'f' => out.push(0x0c),
                        b'u' => {
                            let cp = self.hex4()?;
                            let ch = if (0xd800..=0xdbff).contains(&cp) {
                                if self.b.get(self.i) == Some(&b'\\') && self.b.get(self.i + 1) == Some(&b'u') {
                                    self.i += 2;
                                    let lo = self.hex4()?;
                                    char::from_u32(0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00))
                                        .ok_or("bad surrogate pair")?
                                } else {
                                    return Err("lone surrogate".into());
                                }
                            } else {
                                char::from_u32(cp).ok_or("bad code point")?
                            };
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        _ => return Err("bad escape".into()),
                    }
                }
                _ => out.push(c),
            }
        }
        Err("unterminated string".into())
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let s = self.b.get(self.i..self.i + 4).ok_or("unterminated \\u escape")?;
        self.i += 4;
        let st = std::str::from_utf8(s).map_err(|_| "bad hex".to_string())?;
        u32::from_str_radix(st, 16).map_err(|_| "bad hex".to_string())
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        let mut is_float = false;
        if self.peek() == Some(b'.') {
            is_float = true;
            self.i += 1;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.i += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            is_float = true;
            self.i += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.i += 1;
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.i += 1;
            }
        }
        let tok = std::str::from_utf8(&self.b[start..self.i]).unwrap();
        if is_float {
            tok.parse::<f64>().map(Json::Float).map_err(|_| "bad float".to_string())
        } else {
            tok.parse::<i128>().map(Json::Int).map_err(|_| format!("integer out of i128 range: {tok}"))
        }
    }

    fn array(&mut self) -> Result<Json, String> {
        self.i += 1; // [
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    break;
                }
                _ => return Err("expected `,` or `]`".into()),
            }
        }
        Ok(Json::Array(items))
    }

    fn object(&mut self) -> Result<Json, String> {
        self.i += 1; // {
        let mut entries = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Json::Object(entries));
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return Err("expected object key".into());
            }
            let key = self.string()?;
            self.ws();
            if self.peek() != Some(b':') {
                return Err("expected `:`".into());
            }
            self.i += 1;
            let val = self.value()?;
            entries.push((key, val));
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    break;
                }
                _ => return Err("expected `,` or `}`".into()),
            }
        }
        Ok(Json::Object(entries))
    }
}
